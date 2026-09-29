import Foundation
import SwiftData
import OSLog

/// User-tunable storage settings (Settings › Data & Export › Storage). Stored in UserDefaults; the choices and
/// defaults come from the shared catalog (`AgaraConfig.Storage`).
nonisolated struct StoragePrefs {
    static let capKey = "agara.storage.capMb"
    static let retentionKey = "agara.storage.detailRetentionDays"

    /// Storage limit choices in MB; 0 = no limit.
    static let capOptionsMb: [Int] = AgaraConfig.Storage.capOptionsMb.split(separator: ",").compactMap { Int($0) }
    /// "Keep detailed readings" choices in days; 0 = forever.
    static let retentionOptionsDays: [Int] = AgaraConfig.Storage.detailRetentionOptionsDays.split(separator: ",").compactMap { Int($0) }

    var defaults: UserDefaults = .standard

    var capMb: Int {
        get { defaults.object(forKey: Self.capKey) == nil ? AgaraConfig.Storage.capDefaultMb : defaults.integer(forKey: Self.capKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.capKey) }
    }
    /// nil = no limit.
    var capBytes: Int64? { capMb > 0 ? Int64(capMb) * 1_048_576 : nil }

    var detailRetentionDays: Int {
        get { defaults.integer(forKey: Self.retentionKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.retentionKey) }
    }
}

/// What one maintenance pass did (counts and sizes only — never values).
nonisolated struct MaintenanceReport: Equatable, Sendable {
    var legacyPacketsConverted = 0
    var packetsPruned = false
    var historyPurged = false
    var blocksCompacted = 0
    var rowsCompacted = 0
    var pointsCompacted = 0
    var skipped: [String: Int] = [:]
    var snapshotsWritten = 0
    var skippedBlocksRecovered = 0
    var ladder: [StorageLadder.Rung] = []
    var ladderStop: StorageLadder.StopReason?
    var cancelled = false
    var failures = 0
}

/// The maintenance job (§5 "Compaction worker", storage-compression.md §4 ladder). Synchronous and context-agnostic: the
/// production caller runs it on a background `ModelContext` (`StorageMaintenanceActor`); tests run it on an in-memory
/// context. It never touches days ≤ ring_history_window_days (the hot window is `storage_hot_days`, larger), never
/// blocks ring sync (it only ever runs in its own context, one series-day per transaction), and stops as soon as asked.
nonisolated enum StorageMaintenance {
    static let log = Logger(subsystem: "com.agara.ring", category: "storage")

    /// Compaction is gated by the `storage_compaction` flag; the hot window must exceed the ring's history window.
    static var compactionEnabled: Bool {
        AgaraConfig.Storage.hotDays > AgaraConfig.Ring.historyWindowDays
    }

    struct CompactionSummary: Equatable {
        var blocks = 0
        var rows = 0
        var points = 0
        var skipped: [BlockStore.SkipReason: Int] = [:]
        var failures = 0
        var cancelled = false
    }

    /// Seal every series-day older than `storage_hot_days`, oldest first. One `(metric, source, sensor, day)` per
    /// transaction; the rows that remain are the resume cursor (a crashed or cancelled run continues where it stopped, and
    /// a re-run over finished work changes nothing). `progress(done, total)` counts source rows.
    static func compactAll(now: Date, context: ModelContext, isCancelled: () -> Bool = { false },
                           failpoint: BlockStore.Failpoint? = nil,
                           progress: ((Int, Int) -> Void)? = nil) -> CompactionSummary {
        var summary = CompactionSummary()
        let cutoff = BlockStore.dayStart(BlockStore.sealBoundary(now: now))
        let total = (try? context.fetchCount(FetchDescriptor<Measurement>(predicate: #Predicate { $0.timestamp < cutoff }))) ?? 0
        var processed = 0
        var cursor = Date.distantPast
        var seen = Set<BlockStore.Key>()
        while true {
            let after = cursor
            var d = FetchDescriptor<Measurement>(predicate: #Predicate { $0.timestamp > after && $0.timestamp < cutoff },
                                                 sortBy: [SortDescriptor(\.timestamp)])
            d.fetchLimit = 1500
            let chunk = (try? context.fetch(d)) ?? []
            guard let last = chunk.last else { break }
            cursor = last.timestamp
            var keys: [BlockStore.Key] = []
            for row in chunk {
                let key = BlockStore.Key(metric: row.kindRaw, sourceRaw: row.sourceRaw, sensorId: row.sensorId,
                                         day: BlockStore.utcDay(ms: BlockStore.ms(row.timestamp)))
                if seen.insert(key).inserted { keys.append(key) }
            }
            processed += chunk.count
            for key in keys {
                if isCancelled() { summary.cancelled = true; return summary }
                do {
                    switch try BlockStore.compact(key, now: now, context: context, failpoint: failpoint) {
                    case let .compacted(rows, points):
                        summary.blocks += 1; summary.rows += rows; summary.points += points
                    case let .skipped(reason):
                        summary.skipped[reason, default: 0] += 1
                    }
                } catch {
                    summary.failures += 1
                    log.error("compaction failed for one series-day: \(String(describing: error), privacy: .public)")
                }
            }
            progress?(min(processed, total), total)
        }
        return summary
    }

    // MARK: Raw packets and audit tables

    static func pruneAuditTables(now: Date, days: Int = AgaraConfig.Storage.auditRetentionDays, context: ModelContext) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        try? context.delete(model: DerivedUpdateRow.self, where: #Predicate { $0.timestamp < cutoff })
        try? context.delete(model: WearableLog.self, where: #Predicate { $0.timestamp < cutoff })
    }

    /// Keep the newest `maxRows` packets. The Nth-newest row's timestamp is the cut, so there is one indexed fetch and
    /// one batch delete — no row is materialised just to be deleted. `maxRows <= 0` clears the table. Does not save.
    static func pruneRawPackets(maxRows: Int, context: ModelContext) {
        if maxRows <= 0 { try? context.delete(model: RawPacketRecord.self); return }
        var descriptor = FetchDescriptor<RawPacketRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchOffset = maxRows
        descriptor.fetchLimit = 1
        guard let cut = (try? context.fetch(descriptor))?.first?.timestamp else { return }
        try? context.delete(model: RawPacketRecord.self, where: #Predicate { $0.timestamp <= cut })
    }

    /// The rolling window: packets older than `hours` go — except the pinned identity frames (`a1` handshake, `e0` sleep
    /// transfer), which stay `storage_pinned_frames_days` because the sleep repair replays them — then the row cap. Does not save.
    static func pruneRawPacketWindow(now: Date, hours: Int = AgaraConfig.Storage.rawPacketsWindowHours,
                                     maxRows: Int = AgaraConfig.Storage.rawPacketsMaxRows, context: ModelContext) {
        guard hours > 0, maxRows > 0 else { try? context.delete(model: RawPacketRecord.self); return }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        let pinCutoff = now.addingTimeInterval(-Double(AgaraConfig.Storage.pinnedFramesDays) * 86_400)
        try? context.delete(model: RawPacketRecord.self, where: #Predicate {
            $0.timestamp < cutoff && !(($0.commandId == 0xA1 || $0.commandId == 0xE0) && $0.timestamp >= pinCutoff)
        })
        pruneRawPackets(maxRows: maxRows, context: context)
    }

    /// Convert traces captured by the old hex-text model into `RawPacketRecord`s, then delete them (the model is kept
    /// declared for one release so an upgraded store opens). Returns rows converted. Does not save.
    @discardableResult
    static func convertLegacyRawPackets(context: ModelContext, limit: Int = 5000) -> Int {
        var d = FetchDescriptor<RawPacketRow>(sortBy: [SortDescriptor(\.timestamp)])
        d.fetchLimit = limit
        let legacy = (try? context.fetch(d)) ?? []
        for row in legacy {
            context.insert(RawPacketRecord(timestamp: row.timestamp, direction: row.direction, commandId: row.commandId,
                                           hexPayload: row.hexPayload, decodedKind: row.decodedKind, decodedJSON: row.decodedJSON,
                                           confidence: row.confidence))
            context.delete(row)
        }
        return legacy.count
    }

    // MARK: Persistent history (SwiftData change tracking)

    /// SwiftData records every save in persistent history and nothing here reads it — measured at 43 % of the iOS store, and
    /// unbounded. Drop everything older than `storage_ios_history_retention_hours`. Runs on every maintenance pass.
    @discardableResult
    static func purgePersistentHistory(now: Date, context: ModelContext,
                                       retentionHours: Int = AgaraConfig.Storage.iosHistoryRetentionHours) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.timestamp < cutoff })
        do { try context.deleteHistory(descriptor); return true } catch {
            log.error("history purge failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: The pass

    struct Options {
        /// Run the cap ladder (Optimize now, or over the limit). The routine daily pass compacts and prunes without it.
        var runLadder = true
        /// The `storage_compaction` flag (read on the main actor by the caller; this file is context-only).
        var compact = true
        var capBytes: Int64? = StoragePrefs().capBytes
        var targetPercent = AgaraConfig.Storage.capTargetPercent
    }

    /// One full pass in the order that costs the least first: prune, convert, compact (lossless), snapshot, ladder.
    static func run(now: Date, context: ModelContext, options: Options = Options(),
                    measure: (() -> Int64)? = nil, isCancelled: () -> Bool = { false },
                    progress: ((Double, String) -> Void)? = nil) -> MaintenanceReport {
        var report = MaintenanceReport()
        progress?(0.02, "Cleaning up")
        report.legacyPacketsConverted = convertLegacyRawPackets(context: context)
        pruneRawPacketWindow(now: now, context: context)
        report.packetsPruned = true
        pruneAuditTables(now: now, context: context)
        try? context.save()
        report.historyPurged = purgePersistentHistory(now: now, context: context)
        if isCancelled() { report.cancelled = true; return report }

        if options.compact && compactionEnabled {
            report.skippedBlocksRecovered = BlockStore.redecodeSkipped(context: context, now: now)
            let summary = compactAll(now: now, context: context, isCancelled: isCancelled) { done, total in
                progress?(0.05 + 0.75 * (total > 0 ? Double(done) / Double(total) : 1), "Compacting older readings")
            }
            report.blocksCompacted = summary.blocks
            report.rowsCompacted = summary.rows
            report.pointsCompacted = summary.points
            report.skipped = Dictionary(uniqueKeysWithValues: summary.skipped.map { ($0.key.rawValue, $0.value) })
            report.failures = summary.failures
            report.cancelled = summary.cancelled
            if report.cancelled { return report }
            progress?(0.85, "Updating sync records")
            report.snapshotsWritten = (try? BlockStore.snapshotOpenDays(now: now, context: context)) ?? 0
        }
        if options.runLadder, let measure {
            progress?(0.92, "Checking your storage limit")
            var state = StorageLadder.State(rawWindowHours: AgaraConfig.Storage.rawPacketsWindowHours,
                                            auditDays: AgaraConfig.Storage.auditRetentionDays)
            let outcome = StorageLadder.run(used: measure, capBytes: options.capBytes, targetPercent: options.targetPercent,
                                            state: &state) { rung in
                apply(rung, now: now, context: context)
            }
            report.ladder = outcome.applied
            report.ladderStop = outcome.stop
        }
        progress?(1, "Done")
        return report
    }

    /// Execute one ladder rung. Every rung is lossless for readings, sleep, workouts and user content.
    static func apply(_ rung: StorageLadder.Rung, now: Date, context: ModelContext) {
        switch rung {
        case .shrinkRawPackets:
            // Keep the pinned identity frames (a1 / e0) for `storage_pinned_frames_days`; everything else goes.
            let pinCutoff = now.addingTimeInterval(-Double(AgaraConfig.Storage.pinnedFramesDays) * 86_400)
            try? context.delete(model: RawPacketRecord.self, where: #Predicate {
                !(($0.commandId == 0xA1 || $0.commandId == 0xE0) && $0.timestamp >= pinCutoff)
            })
        case .trimAudit:
            let cutoff = now.addingTimeInterval(-86_400)
            try? context.delete(model: DerivedUpdateRow.self, where: #Predicate { $0.timestamp < cutoff })
            try? context.delete(model: WearableLog.self, where: #Predicate { $0.timestamp < cutoff })
        case .clearCaches:
            StorageCaches.trim(context: context)
        case .downsampleDense:
            break   // needs an aggregate-block key the format does not define yet — see StorageLadder
        }
        try? context.save()
    }
}

/// The disposable caches (food-product lookups). Least recently used go first.
nonisolated enum StorageCaches {
    /// Drop the older half of the food-product cache (LRU by `lastUsedAt`). Returns rows removed.
    @discardableResult
    static func trim(context: ModelContext, keep: Int = 50) -> Int {
        var d = FetchDescriptor<CachedFoodProduct>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        d.fetchOffset = keep
        let stale = (try? context.fetch(d)) ?? []
        for row in stale { context.delete(row) }
        return stale.count
    }
}
