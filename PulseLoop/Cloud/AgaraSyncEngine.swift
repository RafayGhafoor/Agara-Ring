import Foundation
import SwiftData
import OSLog

/// Progress of one sync run, per metric (the one sync-progress model reads it).
nonisolated struct CloudSyncProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable { case preparing, uploading, downloading, finished }
    var stage: Stage = .preparing
    /// Blocks accepted so far per metric, and the totals when the run started.
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    var daysSent = 0
    var sessionsSent = 0

    var totalBlocks: Int { total.values.reduce(0, +) }
    var doneBlocks: Int { done.values.reduce(0, +) }
    var fraction: Double { totalBlocks > 0 ? min(1, Double(doneBlocks) / Double(totalBlocks)) : (stage == .finished ? 1 : 0) }
}

nonisolated struct CloudSyncSummary: Equatable, Sendable {
    var blocksSent = 0
    var blocksAccepted = 0
    var blocksRejected = 0
    var daysSent = 0
    var sessionsSent = 0
    /// EV40 tracker rows acknowledged by the server in this run.
    var trackerSent = 0
    var requests = 0
    var pull = PullReport()
    var pullPages = 0
    var rounds = 0
}

/// Why a run did not start.
nonisolated enum CloudSyncRefusal: Error, Equatable, Sendable {
    case notConfigured
    case noConsent
    case notSignedIn
    case emailNotVerified
    case sampleDataActive
}

nonisolated struct AgaraSyncLimits: Equatable, Sendable {
    var maxBlocks: Int
    var maxDayRows: Int
    var maxBodyBytes: Int
    var pullPageSize = 200
    /// Push → pull → push rounds when a pull produced local changes that must go up again (bounded).
    var maxRounds = 4

    /// The catalog values (`sync_max_blocks_per_request`, `sync_max_day_rows_per_request`, `sync_max_body_bytes`).
    @MainActor static var catalog: AgaraSyncLimits {
        AgaraSyncLimits(maxBlocks: AgaraConfig.Sync.maxBlocksPerRequest, maxDayRows: AgaraConfig.Sync.maxDayRowsPerRequest,
                        maxBodyBytes: AgaraConfig.Sync.maxBodyBytes)
    }
}

/// The sync engine v2 (release-1.1 spec task 3): builds the request from the `block_sync` ledger (blocks whose
/// `synced_hash` is behind — no re-encoding, the stored container is sent verbatim), day rows and tombstones; batches by
/// `sync_max_blocks_per_request` / `sync_max_body_bytes`; POSTs `/api/agara/sync`; applies the per-block results;
/// then pulls `GET /changes?since=<cursor>` and union-merges. Idempotent and resumable: the ledger is written after each
/// batch, the cursor after each page, so a crash or a dropped connection resumes where it stopped and a replay is
/// answered `duplicate`.
///
/// Never runs without consent, a verified account and a configuration; never uploads sample data.
@MainActor
final class AgaraSyncEngine {
    private static let log = Logger(subsystem: "com.agara.ring", category: "agara-sync")

    private let api: AgaraCloudAPI
    private let auth: AgaraAuthClient
    private let store: AgaraSyncStore
    private let state: AgaraCloudState
    private let container: ModelContainer
    private let limits: AgaraSyncLimits
    private let clientId: () -> String
    private let appVersion: String
    private let now: () -> Date
    private let calendar: Calendar
    private let sampleDataActive: () -> Bool
    private let publish: ([RingDecodedEvent]) async -> Void

    init(api: AgaraCloudAPI, auth: AgaraAuthClient, container: ModelContainer, state: AgaraCloudState,
         limits: AgaraSyncLimits? = nil, clientId: @escaping () -> String = { SensorIdentity.shared.clientId },
         appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.0",
         now: @escaping () -> Date = { AppClock.now }, calendar: Calendar = .current,
         sampleDataActive: @escaping () -> Bool = { SampleDataStore.isActiveNow },
         publish: (([RingDecodedEvent]) async -> Void)? = nil) {
        self.api = api
        self.auth = auth
        self.container = container
        self.store = AgaraSyncStore(modelContainer: container)
        self.state = state
        self.limits = limits ?? .catalog
        self.clientId = clientId
        self.appVersion = appVersion
        self.now = now
        self.calendar = calendar
        self.sampleDataActive = sampleDataActive
        self.publish = publish ?? { events in
            for decoded in events {
                for event in RingEventBridge.events(for: decoded, trustTimestamps: true) { await AgaraEventBus.shared.publish(event) }
            }
        }
    }

    /// The store, for the account screen's counters and the delete-account reset.
    var syncStore: AgaraSyncStore { store }

    /// `metric → unit` for rows created from pulled blocks.
    private static let units: [String: String] = Dictionary(MeasurementKind.allCases.map { ($0.rawValue, $0.unit) }, uniquingKeysWith: { first, _ in first })

    // MARK: Run

    /// One full sync. Throws `CloudSyncRefusal` when it must not run, otherwise the raw transport / server / auth error of
    /// the failed request (the caller maps it to a retry policy). `progress` is called on the main actor.
    func run(progress: @escaping (CloudSyncProgress) -> Void = { _ in }) async throws -> CloudSyncSummary {
        guard api.config.isConfigured else { throw CloudSyncRefusal.notConfigured }
        guard state.hasConsent else { throw CloudSyncRefusal.noConsent }
        guard let session = await auth.session else { throw CloudSyncRefusal.notSignedIn }
        guard !sampleDataActive() else { throw CloudSyncRefusal.sampleDataActive }
        // An unverified account may sync only while the server says so (`sync_allowed`: the 72 h grace of decision D10).
        if !session.emailVerified {
            let me = try await api.me()
            guard me.syncAllowed else { throw CloudSyncRefusal.emailNotVerified }
        }

        state.lastAttempt = now()
        // A ledger describes one account's server copy. A different account (or a re-created one) starts from scratch.
        let digest = AgaraCloudState.ownerDigest(session.uid)
        if let owner = state.ledgerOwner, owner != digest {
            state.resetServerView()
            await store.resetSyncedFlags()
        }
        state.ledgerOwner = digest

        var summary = CloudSyncSummary()
        var snapshot = CloudSyncProgress()
        snapshot.total = await store.unsyncedCounts(rejected: state.rejected)
        progress(snapshot)

        for round in 1...max(1, limits.maxRounds) {
            summary.rounds = round
            snapshot.stage = .uploading
            progress(snapshot)
            try await pushTracker(&summary)
            try await pushSessions(&summary)
            try await pushDays(&summary)
            try await pushBlocks(&summary, &snapshot, progress: progress)
            snapshot.stage = .downloading
            progress(snapshot)
            let report = try await pull(&summary)
            if !report.needsUpload { break }
        }
        state.lastSync = now()
        snapshot.stage = .finished
        progress(snapshot)
        Self.log.info("sync done: \(summary.blocksAccepted) blocks up, \(summary.pull.storedNew + summary.pull.mergedLocally + summary.pull.rowsInserted) changes down")
        return summary
    }

    // MARK: Push

    private func envelope(blocks: [String], days: [WireDay], sessions: [String] = [], tracker: [String] = []) -> Data {
        WireBlockBuilder.envelope(clientId: clientId(), platform: "ios", version: appVersion, sentAt: BlockStore.ms(now()),
                                  blocks: blocks, days: days.map(WireBlockBuilder.json), sessions: sessions, tracker: tracker)
    }

    /// Upload the EV40 tracker rows whose ticks the server has not confirmed (cloud-v2 §2.1). The row carries no
    /// timestamp — the server stamps the change — so this is a plain "send the mask, believe the answer" loop.
    ///
    /// A row is acknowledged only on `accepted`/`duplicate` (both mean the server holds that mask); a `rejected`
    /// row is logged and left unsent-marked for a later pass, and a request that throws marks nothing, so no tick
    /// is ever lost. The loop stops when a pass acknowledges nothing, so the same refused rows cannot spin.
    private func pushTracker(_ summary: inout CloudSyncSummary) async throws {
        let context = container.mainContext
        while true {
            let pending = AgaraCloudTracker.pending(context: context)
            guard !pending.isEmpty else { return }
            let sent = pending.map { (day: $0, mask: Ev40Disciplines.normalised($0.mask)) }
            let response = try await api.sync(
                body: envelope(blocks: [], days: [], tracker: AgaraCloudTracker.payload(pending))
            )
            summary.requests += 1
            let byDate = Dictionary(response.tracker.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
            var acknowledged: [(day: Ev40Day, mask: Int, serverUpdatedAt: Date?)] = []
            for row in sent {
                guard let result = byDate[row.day.dateKey] else { continue }
                switch result.status {
                case "accepted", "duplicate":
                    let stamp = result.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                    acknowledged.append((row.day, row.mask, stamp))
                case "rejected":
                    Self.log.error("server refused tracker row: \(result.reason ?? "unknown")")
                default:
                    break
                }
            }
            AgaraCloudTracker.mark(synced: acknowledged, context: context)
            summary.trackerSent += acknowledged.count
            if acknowledged.isEmpty { return }
            if acknowledged.contains(where: { $0.day.hasUnsentChange }) { continue }   // re-ticked while in flight
        }
    }

    /// Upload recorded workout sessions (cloud-v2 §2.1). They go **before** the days: the server computes each day's
    /// workout rollup from the sessions it holds, so a day sent first would be rolled up a pass late.
    ///
    /// A session is acknowledged, not merely attempted: both `accepted` and `duplicate` mark it sent, while a
    /// `rejected` one stays pending (its data may be right after the next local edit) and a request that throws marks
    /// nothing, so nothing is lost.
    private func pushSessions(_ summary: inout CloudSyncSummary) async throws {
        let context = container.mainContext
        while true {
            let pending = AgaraCloudSessions.pending(context: context, limit: 200)
            guard !pending.isEmpty else { return }
            let response = try await api.sync(
                body: envelope(blocks: [], days: [], sessions: AgaraCloudSessions.payload(pending))
            )
            summary.requests += 1
            let rejected = Set(response.sessions.filter { $0.status == "rejected" }.map { $0.sessionKey })
            let acknowledged = pending.filter { !rejected.contains($0.id.uuidString) }
            for reason in response.sessions where reason.status == "rejected" {
                Self.log.error("server refused session: \(reason.reason ?? "unknown")")
            }
            AgaraCloudSessions.mark(synced: acknowledged, at: now(), context: context)
            summary.sessionsSent += acknowledged.count
            if acknowledged.isEmpty { return }   // nothing moved: do not spin on the same rejected rows
        }
    }

    private func pushDays(_ summary: inout CloudSyncSummary) async throws {
        let rows = AgaraCloudDays.dayRows(context: container.mainContext, calendar: calendar)
        var hashes = state.dayHashes
        let changed = rows.filter { hashes[$0.date] != AgaraCloudDays.fingerprint($0) }
        guard !changed.isEmpty else { return }
        var index = 0
        while index < changed.count {
            let chunk = Array(changed[index..<min(changed.count, index + limits.maxDayRows)])
            let response = try await api.sync(body: envelope(blocks: [], days: chunk))
            summary.requests += 1
            let refused = Set(response.days.filter { $0.status == "rejected" }.map(\.date))
            for day in chunk {
                // A refused day is remembered too (same bytes are not retried); it changes when the data does.
                hashes[day.date] = AgaraCloudDays.fingerprint(day)
                if refused.contains(day.date) { Self.log.error("server refused day row") }
            }
            state.dayHashes = hashes
            summary.daysSent += chunk.count
            index += chunk.count
        }
    }

    private func pushBlocks(_ summary: inout CloudSyncSummary, _ snapshot: inout CloudSyncProgress,
                            progress: (CloudSyncProgress) -> Void) async throws {
        var bodyBudget = limits.maxBodyBytes
        while true {
            let batch = await store.pending(rejected: state.rejected, limit: limits.maxBlocks, maxBytes: bodyBudget)
            if batch.isEmpty { return }
            var sent = batch
            var request = envelope(blocks: sent.map(\.json), days: [])
            // The estimate is rough; if the real body is over the cap, halve the batch and try again.
            while sent.count > 1, request.count > limits.maxBodyBytes {
                sent = Array(sent.prefix(max(1, sent.count / 2)))
                request = envelope(blocks: sent.map(\.json), days: [])
            }
            do {
                let response = try await api.sync(body: request)
                summary.requests += 1
                summary.blocksSent += sent.count
                let refused = await store.apply(results: response.blocks, sent: sent, now: now())
                if !refused.isEmpty {
                    var all = state.rejected
                    for (key, hash) in refused { all[key] = hash }
                    state.rejected = all
                }
                summary.blocksRejected += refused.count
                let accepted = response.blocks.filter { ["accepted", "duplicate", "merged"].contains($0.status) }
                summary.blocksAccepted += accepted.count
                for result in accepted {
                    if let metric = ParsedBlockKey.parse(result.blockKey)?.metric { snapshot.done[metric, default: 0] += 1 }
                }
                progress(snapshot)
                // Nothing moved (the server answered none of them): stop instead of asking for the same blocks forever.
                if accepted.isEmpty && refused.isEmpty { return }
            } catch let error as CloudServerError where error.status == 413 && sent.count == 1 {
                // One block alone is too large for the server: remember it as refused and carry on with the rest.
                var all = state.rejected
                all[sent[0].wire.blockKey] = sent[0].wire.contentHash
                state.rejected = all
                summary.blocksRejected += 1
            } catch let error as CloudServerError where error.status == 413 {
                bodyBudget = max(1, bodyBudget / 2)
            }
        }
    }

    // MARK: Pull

    /// Pull every page after the stored cursor. The cursor advances only after a page has been applied and saved, so a
    /// crash re-reads at most one page (applying it again is idempotent).
    private func pull(_ summary: inout CloudSyncSummary) async throws -> PullReport {
        var total = PullReport()
        while true {
            let page = try await api.changes(since: state.cursor, limit: limits.pullPageSize)
            summary.pullPages += 1
            let report = await store.applyPulled(page.blocks, units: Self.units, now: now())
            total.add(report)
            await applyPulledDays(page.days)
            let tracker = AgaraCloudTracker.applyPulled(page.tracker, context: container.mainContext)
            if tracker.needsUpload { total.needsUpload = true }
            state.cursor = page.cursor.isEmpty ? state.cursor : page.cursor
            if report.changedLocalData || tracker.changed { AgaraDataChange.shared.notify() }
            if !page.more { break }
        }
        summary.pull.add(total)
        return total
    }

    private func applyPulledDays(_ days: [WireDay]) async {
        guard !days.isEmpty else { return }
        let local = AgaraCloudDays.localState(context: container.mainContext, calendar: calendar)
        let events = AgaraCloudDays.events(days: days, localSteps: local.steps, localSleepDays: local.sleepDays, calendar: calendar)
        if !events.isEmpty { await publish(events) }
        // The server's copy is what these fingerprints describe, so an unchanged local day is not sent back.
        var hashes = state.dayHashes
        for day in days where hashes[day.date] == nil { hashes[day.date] = AgaraCloudDays.fingerprint(day) }
        state.dayHashes = hashes
    }
}
