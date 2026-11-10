import Foundation
import SwiftData
import Observation
import OSLog
import UIKit
import BackgroundTasks

/// Agara Cloud as the app sees it (release 1.1): one observable owner of the account, the consent, the sync engine, the
/// retry ladder and the schedule. The Settings › Agara Cloud screens read it; the app calls `kick` on foreground.
///
/// The app is fully usable without an account — nothing here runs until the user has consented and signed in with a
/// verified e-mail address, and `phase` says which step they are on.
@MainActor
@Observable
final class AgaraCloud {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// The production instance. Under `-fakeCloud YES` (DEBUG only) it talks to the in-process fake backend instead of the network.
    static let shared: AgaraCloud = {
        #if DEBUG
        if DebugLaunch.bool("fakeCloud") { return AgaraCloud(backend: FakeCloudBackend.launchInstance()) }
        #endif
        return AgaraCloud()
    }()

    // MARK: State the screens read

    enum Phase: Equatable {
        /// No Firebase key / server URL in this build: the screen says so and nothing touches the network.
        case notConfigured
        /// The explicit consent screen comes first (before any sign-up, and so before any upload).
        case needsConsent
        case signedOut
        /// Signed in, waiting for the e-mail link.
        case needsVerification
        case ready
    }

    /// Why the last sync did not complete.
    enum Failure: Equatable {
        case offline
        case rateLimited
        case serverUnavailable
        case emailNotVerified
        case accountDeleted
        case sessionExpired
        case updateRequired
        case sampleData
        case other(String)
    }

    enum Status: Equatable {
        case idle
        case syncing
        case failed(Failure)
    }

    private(set) var phase: Phase = .notConfigured
    private(set) var status: Status = .idle
    private(set) var email: String?
    private(set) var lastSync: Date?
    /// When the unverified-account grace ends (from `GET /me`), if known.
    private(set) var graceEndsAt: Date?
    /// `sync_allowed` from `GET /me` (unverified accounts sync only inside the grace window); nil until known.
    private(set) var syncAllowed: Bool?
    /// The verification e-mail cannot be re-sent before this.
    private(set) var resendAvailableAt: Date?
    /// A sign-in / sign-up / verification / delete request is in flight.
    private(set) var busy = false
    /// The last auth error, as a sentence for the screen.
    private(set) var authMessage: String?
    /// Blocks in the ledger that the server has, and in total.
    private(set) var syncedBlocks = 0
    private(set) var totalBlocks = 0
    /// The next automatic retry, if the ladder scheduled one.
    private(set) var nextRetryAt: Date?

    var isConfigured: Bool { config.isConfigured }
    var isSignedIn: Bool { email != nil }
    var hasConsent: Bool { state.hasConsent }

    // MARK: Dependencies

    private let config: AgaraCloudConfig
    private let transport: CloudTransport
    private let sessionStore: AgaraAuthSessionStore
    let auth: AgaraAuthClient
    let state: AgaraCloudState
    private let api: AgaraCloudAPI
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let progressSink: (CloudSyncProgress) -> Void
    private let resendCooldown: TimeInterval
    /// The `agara_cloud` flag: automatic syncing (foreground, timer) only runs while it is on.
    private let isEnabled: @MainActor () -> Bool
    private var container: ModelContainer?
    private var engine: AgaraSyncEngine?
    private var engineLimits: AgaraSyncLimits
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var ringSyncTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var resetTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.agara.ring", category: "agara-cloud")

    init(config: AgaraCloudConfig? = nil,
         transport: CloudTransport = URLSessionCloudTransport(),
         sessionStore: AgaraAuthSessionStore = AgaraKeychainAuthStore(),
         state: AgaraCloudState = AgaraCloudState(),
         now: @escaping () -> Date = { AppClock.now },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         resendCooldown: TimeInterval = TimeInterval(AgaraConfig.Cloud.resendCooldownSeconds),
         isEnabled: @escaping @MainActor () -> Bool = { AgaraFeatureStore.isOn(.agaraCloud) },
         limits: AgaraSyncLimits? = nil,
         progress: ((CloudSyncProgress) -> Void)? = nil) {
        let config = config ?? .current
        self.config = config
        self.transport = transport
        // One store for both readers: `refresh()` (which decides isSignedIn/phase, and so the coach gate) and the auth
        // client. Wrapping only the client's copy made an injected session invisible to `refresh()`.
        let store = AgaraLaunchArgumentSessionStore(inner: sessionStore)
        self.sessionStore = store
        self.state = state
        self.now = now
        self.sleep = sleep
        self.resendCooldown = resendCooldown
        self.isEnabled = isEnabled
        self.engineLimits = limits ?? .catalog
        self.progressSink = progress ?? { SyncProgress.shared.updateCloud($0) }
        let auth = AgaraAuthClient(config: config, transport: transport, store: store, now: { AppClock.now })
        self.auth = auth
        self.api = AgaraCloudAPI(config: config, transport: transport, auth: auth)
        refresh()
    }

    /// Test / debug wiring around a fake backend (its own config, transport and session store).
    convenience init(backend: CloudTransport & AgaraCloudBackendInfo) {
        self.init(config: backend.config, transport: backend, sessionStore: backend.sessionStore, state: backend.state, isEnabled: { true })
    }

    /// Hand over the app's store (like `StorageCenter.attach`). Starts the periodic schedule.
    func attach(container: ModelContainer, schedule: Bool = true) {
        self.container = container
        engine = nil
        refresh()
        if schedule { startSchedule(); startRingSyncTrigger() }
    }

    // MARK: Phase

    /// Recompute `phase` (and the mirrored account fields) from the config, the consent and the stored session.
    func refresh() {
        let session = sessionStore.load()
        email = session?.email
        lastSync = state.lastSync
        if !config.isConfigured { phase = .notConfigured }
        else if !state.hasConsent { phase = .needsConsent }
        else if let session { phase = session.emailVerified ? .ready : .needsVerification }
        else { phase = .signedOut }
        if phase == .needsVerification, state.unverifiedSince == nil { state.unverifiedSince = now() }
        scheduleBackgroundRefresh()
    }

    // MARK: Consent

    func acceptConsent() {
        state.giveConsent(at: now())
        refresh()
    }

    /// Withdraw consent (also stops syncing). The account, if any, is untouched.
    func withdrawConsent() {
        cancelWork()
        state.revokeConsent()
        refresh()
    }

    // MARK: Account

    func signUp(email: String, password: String) async {
        await authAction {
            try await auth.signUp(email: email.trimmed, password: password)
            try? await auth.sendVerificationEmail()
            resendAvailableAt = now().addingTimeInterval(resendCooldown)
        }
        if isSignedIn { kick(reason: .signedIn) }
    }

    func signIn(email: String, password: String) async {
        await authAction { try await auth.signIn(email: email.trimmed, password: password) }
        if isSignedIn { kick(reason: .signedIn) }
    }

    func sendPasswordReset(email: String) async -> Bool {
        var ok = false
        await authAction { try await auth.sendPasswordReset(email: email.trimmed); ok = true }
        return ok
    }

    /// Re-send the verification e-mail (with a cooldown so the button cannot be hammered).
    func resendVerification() async {
        if let at = resendAvailableAt, now() < at { return }
        await authAction {
            try await auth.sendVerificationEmail()
            resendAvailableAt = now().addingTimeInterval(resendCooldown)
        }
    }

    /// Ask Firebase whether the address is verified now ("I've verified", the auto-poll and the foreground check).
    /// Moves to `ready` and starts the first sync when it is.
    @discardableResult
    func checkVerification() async -> Bool {
        guard isSignedIn else { return false }
        do {
            let verified = try await auth.checkEmailVerified()
            authMessage = nil
            refresh()
            if verified { state.unverifiedSince = nil; kick(reason: .signedIn) }
            return verified
        } catch let error as AgaraAuthError {
            authMessage = error == .network ? nil : error.message
            if error == .sessionExpired { refresh() }
            return false
        } catch { return false }
    }

    /// Poll `checkVerification` every `verifyPollSeconds` while the verify screen is visible (cancel the task to stop).
    func pollVerification() async {
        while !Task.isCancelled, phase == .needsVerification {
            try? await sleep(TimeInterval(max(1, config.verifyPollSeconds)))
            if Task.isCancelled { return }
            if await checkVerification() { return }
        }
    }

    /// `GET /me` for the grace banner. Best effort; failures are silent.
    func refreshMe() async {
        guard let info = try? await api.me() else { return }
        graceEndsAt = info.graceEndsAt
        syncAllowed = info.syncAllowed
    }

    func signOut() {
        cancelWork()
        Task { await auth.signOut() }
        sessionStore.clear()
        // The ledger and cursor describe this account's server copy; they go with the sign-in. Consent stays.
        state.resetServerView()
        resetLedger()
        status = .idle
        authMessage = nil
        graceEndsAt = nil; syncAllowed = nil
        refresh()
    }

    /// Mark every block unsynced again (a different account may sign in next). Awaited by the next sync.
    private func resetLedger() {
        guard let container else { return }
        let previous = resetTask
        resetTask = Task {
            await previous?.value
            await AgaraSyncStore(modelContainer: container).resetSyncedFlags()
        }
    }

    /// Erase what this device holds about the cloud account: tokens, the pull cursor, the ledger's `synced_*` columns,
    /// consent. Local health data is untouched. Used by "Delete all my data" (through `AppDataWipe`) and account deletion.
    func wipeLocalAccount() {
        cancelWork()
        sessionStore.clear()
        state.resetAll()
        email = nil; lastSync = nil; graceEndsAt = nil; syncAllowed = nil; status = .idle; authMessage = nil
        syncedBlocks = 0; totalBlocks = 0
        resetLedger()
        refresh()
    }

    enum DeleteOutcome: Equatable {
        case deleted
        /// The server wants a fresh login: ask for the password, `reauthenticate`, then call again.
        case needsRecentLogin
        case failed(String)
    }

    /// Delete account (cloud-v2.md §2.5): `DELETE /api/agara/me` first (data first, Firebase second), then the Firebase
    /// `accounts:delete` fallback when the server could not remove the Firebase user, then the local tokens and ledger.
    /// Local health data stays on the phone.
    func deleteAccount() async -> DeleteOutcome {
        guard isSignedIn else { return .failed(AgaraAuthError.notSignedIn.message) }
        busy = true
        defer { busy = false }
        cancelWork()
        do {
            let result = try await api.deleteMe()
            if result.deleted, !result.firebaseDeleted { try? await auth.deleteFirebaseAccount() }
        } catch let error as CloudServerError {
            switch error.code {
            case "recent_login_required": return .needsRecentLogin
            case "account_deleted": break   // already erased server-side: finish locally
            default: return .failed(Self.describe(error))
            }
        } catch let error as AgaraAuthError {
            if error == .recentLoginRequired { return .needsRecentLogin }
            return .failed(error.message)
        } catch let error as CloudTransportError {
            return .failed(error == .offline ? AgaraAuthError.network.message : AgaraCloudCopy.requestTimedOut)
        } catch {
            return .failed(error.localizedDescription)
        }
        await auth.signOut()
        wipeLocalAccount()
        return .deleted
    }

    /// Sign in again with the password (the server's "recent login" rule), then the caller retries the action.
    func reauthenticate(password: String) async -> Bool {
        do { try await auth.reauthenticate(password: password); authMessage = nil; return true }
        catch let error as AgaraAuthError { authMessage = error.message; return false }
        catch { return false }
    }

    // MARK: Sync

    enum Reason { case manual, foreground, timer, signedIn, retry, ringSync }

    /// Start a sync unless one is running or the state forbids it. Fire and forget.
    func kick(reason: Reason) {
        guard isEnabled(), canSync, container != nil, syncTask == nil else { return }
        // Foreground entry syncs only when the last successful sync is older than the open gap (Sync now ignores it);
        // the timer waits a full interval since the last attempt.
        if reason == .foreground,
           !AgaraCloudSchedule.shouldSyncOnOpen(lastSync: state.lastSync, now: now(), minGapMinutes: config.syncOpenMinGapMinutes) { return }
        if reason == .timer, let last = state.lastAttempt,
           now().timeIntervalSince(last) < Double(syncIntervalMinutes()) * 60, status != .failed(.offline) { return }
        syncTask = Task { [weak self] in await self?.runSync(reason: reason) }
    }

    /// "Sync now": run and wait for the result (resets the retry ladder).
    func syncNow() async {
        guard canSync, container != nil else { return }
        if let task = syncTask { await task.value; return }
        retryTask?.cancel(); retryTask = nil; nextRetryAt = nil
        retryAttempt = 0
        await runSync(reason: .manual)
    }

    /// Signed in with consent: verified accounts always, unverified ones while the server allows it (the engine asks `/me`).
    private var canSync: Bool { phase == .ready || phase == .needsVerification }

    func waitForIdle() async { await syncTask?.value }

    private func makeEngine() -> AgaraSyncEngine? {
        if let engine { return engine }
        guard let container else { return nil }
        #if DEBUG
        FakeCloudSeed.apply(container: container)   // UI tests: after the launch-time demo seed has run
        #endif
        let created = AgaraSyncEngine(api: api, auth: auth, container: container, state: state, limits: engineLimits, now: now)
        // A model or share-card address accepted on a previous run applies before this one, so a cold start does not run
        // on the compiled default for a whole session (item F3; plan ev40-share-card-v2).
        created.installCachedModel()
        created.installCachedShareCard()
        engine = created
        return created
    }

    private func runSync(reason: Reason, retriedAfterVerify: Bool = false) async {
        guard let engine = makeEngine() else { syncTask = nil; return }
        await resetTask?.value
        status = .syncing
        defer { syncTask = nil }
        do {
            let summary = try await engine.run { [weak self] progress in
                self?.progressSink(progress)
            }
            status = .idle
            retryAttempt = 0; retryTask?.cancel(); retryTask = nil; nextRetryAt = nil
            lastSync = state.lastSync
            await updateCounts(engine)
            Self.log.info("cloud sync ok: \(summary.blocksAccepted) up")
        } catch {
            await handle(error, reason: reason, engine: engine, retriedAfterVerify: retriedAfterVerify)
        }
        SyncProgress.shared.endCloud()
        scheduleBackgroundRefresh()
    }

    private func updateCounts(_ engine: AgaraSyncEngine) async {
        let counts = await engine.syncStore.ledgerCounts()
        syncedBlocks = counts.synced
        totalBlocks = counts.total
    }

    private func handle(_ error: Error, reason: Reason, engine: AgaraSyncEngine, retriedAfterVerify: Bool) async {
        if error is CancellationError { status = .idle; return }
        let (failure, retryAfter) = Self.classify(error)
        Self.log.error("cloud sync failed: \(String(describing: failure), privacy: .public)")
        switch failure {
        case .emailNotVerified:
            // The server disagrees with the local flag (a stale token claim): check with Firebase once, then retry once.
            if !retriedAfterVerify, let verified = try? await auth.checkEmailVerified(), verified {
                try? await auth.forceRefresh()   // the token's own `email_verified` claim is what the server reads
                await runSync(reason: reason, retriedAfterVerify: true)
                return
            }
            status = .failed(failure)
            refresh()
            await refreshMe()
        case .accountDeleted:
            status = .idle
            await auth.signOut()
            state.resetServerView()
            refresh()
            authMessage = AgaraCloudCopy.accountDeletedElsewhere
            status = .failed(.accountDeleted)
        case .sessionExpired:
            await auth.signOut()
            refresh()
            status = .failed(failure)
        case .offline, .rateLimited, .serverUnavailable, .other:
            status = .failed(failure)
            scheduleRetry(after: retryAfter)
        case .updateRequired, .sampleData:
            status = .failed(failure)
        }
    }

    /// The retry ladder (`cloud_sync_retry_backoff_seconds`): each consecutive failure waits the next step (the server's
    /// `Retry-After` wins when longer); after the last step the ladder stops and the periodic schedule takes over.
    private func scheduleRetry(after serverHint: TimeInterval?) {
        retryTask?.cancel()
        let ladder = config.retryBackoffSeconds
        guard retryAttempt < ladder.count else { nextRetryAt = nil; return }
        let delay = max(TimeInterval(ladder[retryAttempt]), serverHint ?? 0)
        retryAttempt += 1
        nextRetryAt = now().addingTimeInterval(delay)
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.nextRetryAt = nil
            self.retryTask = nil
            if self.canSync, self.syncTask == nil {
                self.syncTask = Task { [weak self] in await self?.runSync(reason: .retry) }
            }
        }
    }

    /// Delay the retry ladder would use for the n-th consecutive failure (for tests and the UI).
    func ladderDelay(forAttempt attempt: Int) -> TimeInterval {
        let ladder = config.retryBackoffSeconds
        return TimeInterval(ladder[min(max(0, attempt), ladder.count - 1)])
    }

    // MARK: Classification

    /// Map a failed run to what the user sees and how long to wait before the automatic retry.
    static func classify(_ error: Error) -> (Failure, TimeInterval?) {
        switch error {
        case let refusal as CloudSyncRefusal:
            switch refusal {
            case .sampleDataActive: return (.sampleData, nil)
            case .emailNotVerified: return (.emailNotVerified, nil)
            default: return (.other("not ready"), nil)
            }
        case let transport as CloudTransportError:
            return (transport == .offline ? .offline : .serverUnavailable, nil)
        case let server as CloudServerError:
            switch (server.status, server.code) {
            case (401, "account_deleted"): return (.accountDeleted, nil)
            case (401, _): return (.sessionExpired, nil)
            case (403, "email_not_verified"): return (.emailNotVerified, nil)
            case (403, _): return (.other(describe(server)), nil)
            case (429, _): return (.rateLimited, server.retryAfter)
            case (400, "unsupported_envelope"): return (.updateRequired, nil)
            case (500...599, _): return (.serverUnavailable, server.retryAfter)
            default: return (.other(describe(server)), nil)
            }
        case let auth as AgaraAuthError:
            switch auth {
            case .network: return (.offline, nil)
            case .sessionExpired, .notSignedIn, .userDisabled: return (.sessionExpired, nil)
            case .notConfigured: return (.other(auth.message), nil)
            default: return (.serverUnavailable, nil)
            }
        default:
            return (.serverUnavailable, nil)
        }
    }

    private static func describe(_ error: CloudServerError) -> String {
        switch error.code {
        case "recent_login_required": return AgaraAuthError.recentLoginRequired.message
        case "rate_limited": return AgaraCloudCopy.serverRateLimited
        default: return error.isServerSide ? AgaraCloudCopy.serverUnavailable : AgaraCloudCopy.serverRefused(error.code)
        }
    }

    // MARK: Schedule

    /// Opportunistic sync while the app is in the foreground: one attempt per `syncIntervalMinutes` (no background task:
    /// iOS decides when to wake an app, and the coach already holds the app's BGTask identifiers).
    private func startSchedule() {
        scheduleTask?.cancel()
        let interval = TimeInterval(max(1, syncIntervalMinutes()) * 60)
        scheduleTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self else { return }
                if UIApplication.shared.applicationState == .active { self.kick(reason: .timer) }
            }
        }
    }

    private func cancelWork() {
        syncTask?.cancel(); syncTask = nil
        retryTask?.cancel(); retryTask = nil
        nextRetryAt = nil
        retryAttempt = 0
    }


    // MARK: Background refresh (release 1.1)

    /// The ONE place the sync interval is read (foreground timer, background refresh): today the catalog default
    /// (`cloud_sync_interval_minutes`, 120); a future user setting overrides it here.
    func syncIntervalMinutes() -> Int { config.syncIntervalMinutes }

    /// `BGAppRefreshTask` identifier; also listed in Info.plist `BGTaskSchedulerPermittedIdentifiers` (with the `fetch`
    /// background mode). iOS runs it opportunistically (typically a few times a day) - Android's WorkManager is periodic.
    nonisolated static let backgroundTaskIdentifier = "com.agara.ring.cloudsync"
    /// Submitting a request for an identifier that was not registered traps, and registration is skipped under XCTest.
    private static var backgroundRegistered = false

    /// Call once at launch (before the app finishes launching), like the coach's tasks.
    static func registerBackgroundTask() {
        backgroundRegistered = true
        let handler: @Sendable (BGTask) -> Void = { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in AgaraCloud.shared.runBackgroundRefresh(refresh) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil, launchHandler: handler)
    }

    private var scheduleInput: AgaraCloudSchedule.Input {
        let blocked: Bool
        switch status {
        case .failed(.emailNotVerified), .failed(.updateRequired): blocked = true
        default: blocked = false
        }
        return AgaraCloudSchedule.Input(
            consent: config.isConfigured && state.hasConsent, signedIn: isSignedIn, verified: phase == .ready,
            graceEndsAt: graceEndsAt, blocked: blocked, now: now(), lastSync: state.lastSync,
            intervalMinutes: syncIntervalMinutes(), retryNextAt: nextRetryAt)
    }

    /// Submit (or cancel) the app-refresh request per `AgaraCloudSchedule.decide`. Called after every sync, on backgrounding
    /// and whenever the account state changes.
    func scheduleBackgroundRefresh() {
        guard Self.backgroundRegistered else { return }
        guard isEnabled() else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier); return }
        switch AgaraCloudSchedule.decide(scheduleInput) {
        case .cancel:
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        case let .schedule(delay):
            let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
            request.earliestBeginDate = now().addingTimeInterval(TimeInterval(delay))
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    /// The background wake: one sync, re-scheduled first so a crash or expiry never ends the chain. Never runs without
    /// consent and a verified (or in-grace) account; sample data is refused by the engine.
    private func runBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        guard isEnabled(), canSync, container != nil, AgaraCloudSchedule.decide(scheduleInput) != .cancel else {
            task.setTaskCompleted(success: true)
            return
        }
        let work = Task { @MainActor [weak self] in
            await self?.runBackgroundPass()
            let ok = self.map { if case .failed = $0.status { return false } else { return true } } ?? false
            task.setTaskCompleted(success: ok)
        }
        // On expiry, cancel the sync (it ends as CancellationError -> idle) and let the task above complete the BGTask.
        task.expirationHandler = { work.cancel() }
    }

    /// One pass that honours cancellation of the calling task (the BG expiration handler).
    private func runBackgroundPass() async {
        if syncTask == nil {
            syncTask = Task { [weak self] in await self?.runSync(reason: .timer) }
        }
        guard let running = syncTask else { return }
        await withTaskCancellationHandler {
            await running.value
        } onCancel: {
            running.cancel()
        }
    }

    /// A ring sync just finished: send the new data now. Wrapped in a background task so it can finish when the app was
    /// only woken by the ring link. Skipped while a retry is pending (the ladder owns the timing) or a sync is running.
    func syncAfterRingSync() {
        guard isEnabled(), canSync, container != nil, syncTask == nil else { return }
        if let at = nextRetryAt, now() < at { return }
        let guardTask = BackgroundTaskGuard(name: "cloud.afterRingSync")
        syncTask = Task { [weak self] in
            await self?.runSync(reason: .ringSync)
            guardTask.end()
        }
        guardTask.onExpire = { [weak self] in self?.syncTask?.cancel() }
    }

    private func startRingSyncTrigger() {
        ringSyncTask?.cancel()
        ringSyncTask = Task { [weak self] in
            let stream = await AgaraEventBus.shared.stream()
            for await event in stream {
                guard case let .syncProgress(stage) = event, stage == "done" else { continue }
                self?.syncAfterRingSync()
            }
        }
    }

    // MARK: Auth plumbing

    private func authAction(_ body: () async throws -> Void) async {
        busy = true
        authMessage = nil
        defer { busy = false; refresh() }
        do { try await body() }
        catch let error as AgaraAuthError { authMessage = error.message }
        catch is CancellationError {}
        catch { authMessage = AgaraAuthError.network.message }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// What the debug fake backend exposes so `AgaraCloud(backend:)` can wire itself.
protocol AgaraCloudBackendInfo {
    var config: AgaraCloudConfig { get }
    var sessionStore: AgaraAuthSessionStore { get }
    var state: AgaraCloudState { get }
}

/// `UIApplication.beginBackgroundTask` around one piece of work; ends exactly once.
@MainActor
final class BackgroundTaskGuard {
    private var id: UIBackgroundTaskIdentifier = .invalid
    var onExpire: (() -> Void)?

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.onExpire?(); self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
