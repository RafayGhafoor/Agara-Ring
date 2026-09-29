import SwiftData
import XCTest
@testable import PulseLoop

/// Records the delays the center asked to sleep, and lets a test hook into each sleep.
final class Sleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var onSleep: (@Sendable (Int) -> Void)?
    var delays: [TimeInterval] { lock.withLock { recorded } }
    func sleep(_ seconds: TimeInterval) async throws {
        let count = lock.withLock { () -> Int in recorded.append(seconds); return recorded.count }
        onSleep?(count)
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// The account, consent, retry ladder and delete flows of `AgaraCloud` (release 1.1, tasks 2-4) against the fake backend.
@MainActor
final class AgaraCloudCenterTests: XCTestCase {
    private var backend: FakeCloudBackend!
    private var sleeper: Sleeper!
    private var clock: TestClock!
    private var container: ModelContainer!
    private var center: AgaraCloud!
    private let email = "user@example.com"
    private let password = "password1"

    override func setUp() async throws {
        backend = FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        sleeper = Sleeper()
        clock = TestClock(CloudDevice.now)
        container = try ModelContainerFactory.make(inMemory: true)
        center = makeCenter()
        center.attach(container: container, schedule: false)
    }

    private func makeCenter(config: AgaraCloudConfig? = nil) -> AgaraCloud {
        AgaraCloud(config: config ?? backend.config, transport: backend, sessionStore: backend.sessionStore, state: backend.state,
                   now: { [clock] in clock!.now }, sleep: sleeper.sleep, resendCooldown: 60, isEnabled: { true }, progress: { _ in })
    }

    /// Some sealed data so a sync has something to send.
    private func addData(days: Int = 2) throws {
        let context = container.mainContext
        for i in 0..<days {
            let day = BlockStore.today(now: CloudDevice.now) - 12 - Int64(i)
            for j in 0..<30 {
                context.insert(PulseLoop.Measurement(kind: .heartRate, value: Double(60 + j), unit: "bpm",
                                                     timestamp: BlockStore.date(ms: day * AGB.dayMs + 3_600_000 + Int64(j) * 60_000), source: .live,
                                                     sensorId: "a3a04cab4846d63c"))
            }
        }
        try context.save()
        _ = StorageMaintenance.compactAll(now: CloudDevice.now, context: context)
    }

    private func signInReady() async throws {
        backend.createUser(email: email, password: password, verified: true)
        center.acceptConsent()
        await center.signIn(email: email, password: password)
        XCTAssertEqual(center.phase, .ready)
        await center.waitForIdle()
    }

    private var ledgers: [BlockSync] { (try? container.mainContext.fetch(FetchDescriptor<BlockSync>())) ?? [] }

    /// Wait (bounded) for the retry ladder to run out.
    private func settle(_ delays: Int) async throws {
        for _ in 0..<80 where sleeper.delays.count < delays || center.nextRetryAt != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        await center.waitForIdle()
    }

    // MARK: Phases and consent

    func testPhasesWalkFromUnconfiguredToConsentToSignedOut() {
        var config = backend.config
        config.firebaseApiKey = ""
        XCTAssertEqual(makeCenter(config: config).phase, .notConfigured)
        var noURL = backend.config
        noURL.baseURL = nil
        XCTAssertEqual(makeCenter(config: noURL).phase, .notConfigured)

        XCTAssertEqual(center.phase, .needsConsent, "consent comes before any account")
        XCTAssertFalse(center.hasConsent)
        center.acceptConsent()
        XCTAssertEqual(center.phase, .signedOut)
        XCTAssertNotNil(backend.state.consentDate)
        XCTAssertEqual(backend.requests.count, 0, "consent alone never touches the network")
    }

    func testNotConfiguredNeverCallsTheNetworkEvenIfAskedTo() async {
        var config = backend.config
        config.firebaseApiKey = ""
        let unconfigured = makeCenter(config: config)
        unconfigured.attach(container: container, schedule: false)
        unconfigured.acceptConsent()
        await unconfigured.signIn(email: email, password: password)
        await unconfigured.syncNow()
        unconfigured.kick(reason: .manual)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(unconfigured.authMessage, AgaraAuthError.notConfigured.message)
    }

    func testWithdrawingConsentStopsSyncing() async throws {
        try await signInReady()
        center.withdrawConsent()
        XCTAssertEqual(center.phase, .needsConsent)
        let before = backend.syncRequestCount
        center.kick(reason: .manual)
        await center.syncNow()
        XCTAssertEqual(backend.syncRequestCount, before)
    }

    // MARK: Sign up and verification

    func testSignUpSendsTheVerificationEmailAndWaitsForTheLink() async throws {
        center.acceptConsent()
        await center.signUp(email: "  \(email) ", password: password)
        await center.waitForIdle()
        XCTAssertEqual(center.phase, .needsVerification)
        XCTAssertEqual(center.email, email, "the address is trimmed")
        XCTAssertEqual(backend.emailsSent.last?.kind, "VERIFY_EMAIL")
        XCTAssertEqual(backend.emailsSent.filter { $0.kind == "VERIFY_EMAIL" }.count, 1)
        XCTAssertEqual(center.resendAvailableAt, clock.now.addingTimeInterval(60))
        XCTAssertEqual(backend.syncRequestCount, 0, "an unverified account never syncs")
    }

    func testSignUpErrorsAreShownNotThrown() async {
        backend.createUser(email: email, password: password, verified: true)
        center.acceptConsent()
        await center.signUp(email: email, password: password)
        XCTAssertEqual(center.phase, .signedOut)
        XCTAssertEqual(center.authMessage, AgaraAuthError.emailExists.message)
        await center.signIn(email: email, password: "wrong-password")
        XCTAssertEqual(center.authMessage, AgaraAuthError.invalidCredentials.message)
        backend.offline = true
        await center.signIn(email: email, password: password)
        XCTAssertEqual(center.authMessage, AgaraAuthError.network.message)
    }

    func testResendHasACooldown() async throws {
        center.acceptConsent()
        await center.signUp(email: email, password: password)
        await center.resendVerification()
        XCTAssertEqual(backend.emailsSent.filter { $0.kind == "VERIFY_EMAIL" }.count, 1, "blocked inside the cooldown")
        clock.advance(61)
        await center.resendVerification()
        XCTAssertEqual(backend.emailsSent.filter { $0.kind == "VERIFY_EMAIL" }.count, 2)
        XCTAssertEqual(center.resendAvailableAt, clock.now.addingTimeInterval(60))
    }

    func testIHaveVerifiedMovesToReadyAndStartsTheFirstSync() async throws {
        try addData()
        center.acceptConsent()
        await center.signUp(email: email, password: password)
        await center.waitForIdle()
        let notYet = await center.checkVerification()
        XCTAssertFalse(notYet)
        XCTAssertEqual(center.phase, .needsVerification)

        backend.markVerified(email: email)
        let verified = await center.checkVerification()
        XCTAssertTrue(verified)
        XCTAssertEqual(center.phase, .ready)
        await center.waitForIdle()
        XCTAssertEqual(center.status, .idle)
        XCTAssertNotNil(center.lastSync)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2, "consent → sign-up → verify → synced")
        XCTAssertEqual(center.syncedBlocks, 2); XCTAssertEqual(center.totalBlocks, 2)
    }

    func testAutoPollNoticesTheClickEveryVerifyPollSeconds() async throws {
        center.acceptConsent()
        await center.signUp(email: email, password: password)
        sleeper.onSleep = { [backend, email] count in if count == 3 { backend!.markVerified(email: email) } }
        await center.pollVerification()
        XCTAssertEqual(center.phase, .ready)
        XCTAssertEqual(sleeper.delays, [1, 1, 1].map { _ in TimeInterval(backend.config.verifyPollSeconds) })
        await center.waitForIdle()
    }

    func testGraceWindowFromTheServerIsExposed() async throws {
        center.acceptConsent()
        await center.signUp(email: email, password: password)
        await center.refreshMe()
        // The fake reports no grace_ends_at; the field stays nil and the screen shows no banner.
        XCTAssertNil(center.graceEndsAt)
        XCTAssertEqual(backend.count(pathSuffix: "/me"), 1, "unverified users may call GET /me")
    }

    // MARK: Sync, states and the retry ladder

    func testSyncNowUploadsAndRecordsTheTime() async throws {
        try addData(days: 3)
        try await signInReady()
        XCTAssertEqual(center.status, .idle)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 3)
        XCTAssertEqual(center.lastSync, backend.state.lastSync)
        XCTAssertTrue(ledgers.allSatisfy { $0.isSynced })
    }

    func testOfflineFollowsTheRetryLadderThenStopsAndSyncNowStartsOver() async throws {
        try addData()
        try await signInReady()
        backend.offline = true
        try addData(days: 4)          // new blocks to send
        await center.syncNow()
        try await settle(4)
        XCTAssertEqual(sleeper.delays, [30, 120, 600, 1800], "the catalog ladder")
        XCTAssertEqual(center.status, .failed(.offline))
        XCTAssertNil(center.nextRetryAt, "after the last step the ladder stops")

        backend.offline = false
        await center.syncNow()
        XCTAssertEqual(center.status, .idle)
        XCTAssertEqual(center.ladderDelay(forAttempt: 0), 30)
        XCTAssertEqual(center.ladderDelay(forAttempt: 99), 1800)
        XCTAssertTrue(ledgers.allSatisfy { $0.isSynced })
    }

    func testRateLimitHonoursRetryAfterWhenLongerThanTheLadder() async throws {
        try addData()
        try await signInReady()
        try addData(days: 3)
        backend.inject(.init(pathContains: "/sync", status: 429, code: "rate_limited", retryAfter: 900))
        await center.syncNow()
        XCTAssertEqual(center.status, .failed(.rateLimited))
        try await settle(1)
        XCTAssertEqual(sleeper.delays.first, 900)
        XCTAssertEqual(center.status, .idle, "the retry after the wait succeeds")
    }

    func testServerErrorsAreServerUnavailableAndRetried() async throws {
        try await signInReady()
        try addData()
        backend.inject(.init(pathContains: "/sync", status: 503, code: "auth_unavailable"))
        await center.syncNow()
        XCTAssertEqual(center.status, .failed(.serverUnavailable))
        try await settle(1)
        XCTAssertEqual(center.status, .idle)
        XCTAssertEqual(sleeper.delays.first, 30)
    }

    func testAStaleVerifiedClaimIsRepairedByCheckingWithFirebaseAndRetrying() async throws {
        backend.createUser(email: email, password: password, verified: false)
        center.acceptConsent()
        await center.signIn(email: email, password: password)
        XCTAssertEqual(center.phase, .needsVerification)
        backend.markVerified(email: email)                     // clicked; the app has not looked yet…
        var session = try XCTUnwrap(backend.sessionStore.load())
        session.emailVerified = true                            // …but its cached flag (and token claim) are stale
        backend.sessionStore.save(session)
        center.refresh()
        XCTAssertEqual(center.phase, .ready)
        try addData()
        await center.syncNow()
        XCTAssertEqual(center.status, .idle, "403 → lookup → forced refresh → retried once")
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2)
    }

    func testEmailNotVerifiedFromTheServerSendsTheUserBackToTheVerifyScreen() async throws {
        backend.createUser(email: email, password: password, verified: false)
        center.acceptConsent()
        await center.signIn(email: email, password: password)
        var session = try XCTUnwrap(backend.sessionStore.load())
        session.emailVerified = true                 // the app believes it; Firebase and the token say otherwise
        backend.sessionStore.save(session)
        center.refresh()
        XCTAssertEqual(center.phase, .ready)
        try addData()
        await center.syncNow()
        XCTAssertEqual(center.status, .failed(.emailNotVerified))
        XCTAssertEqual(center.phase, .needsVerification)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 0)
        XCTAssertTrue(ledgers.allSatisfy { !$0.isSynced }, "nothing was lost or marked synced")
    }

    func testAccountDeletedElsewhereSignsOutAndKeepsLocalData() async throws {
        try addData()
        try await signInReady()
        let rowsBefore = ledgers.count
        // The account is erased from another place (console, another device).
        _ = try await center.auth.validIdToken()
        let api = AgaraCloudAPI(config: backend.config, transport: backend, auth: center.auth)
        _ = try await api.deleteMe()
        try addData(days: 3)
        await center.syncNow()
        XCTAssertEqual(center.status, .failed(.accountDeleted))
        XCTAssertEqual(center.phase, .signedOut)
        XCTAssertNotNil(center.authMessage)
        XCTAssertGreaterThanOrEqual(ledgers.count, rowsBefore, "local data is untouched")
        XCTAssertNil(backend.sessionStore.load())
    }

    func testAPersistent401SignsOut() async throws {
        try await signInReady()
        try addData()
        backend.inject(.init(pathContains: "/sync", status: 401, code: "invalid_token", remaining: 5))
        await center.syncNow()
        XCTAssertEqual(center.status, .failed(.sessionExpired))
        XCTAssertEqual(center.phase, .signedOut)
    }

    func testClassifyMapsEveryFailureKind() {
        func f(_ e: Error) -> AgaraCloud.Failure { AgaraCloud.classify(e).0 }
        XCTAssertEqual(f(CloudTransportError.offline), .offline)
        XCTAssertEqual(f(CloudTransportError.timedOut), .serverUnavailable)
        XCTAssertEqual(f(CloudServerError(status: 429, code: "rate_limited", message: "", retryAfter: 12)), .rateLimited)
        XCTAssertEqual(AgaraCloud.classify(CloudServerError(status: 429, code: "rate_limited", message: "", retryAfter: 12)).1, 12)
        XCTAssertEqual(f(CloudServerError(status: 503, code: "auth_unavailable", message: "", retryAfter: nil)), .serverUnavailable)
        XCTAssertEqual(f(CloudServerError(status: 500, code: "server_error", message: "", retryAfter: nil)), .serverUnavailable)
        XCTAssertEqual(f(CloudServerError(status: 403, code: "email_not_verified", message: "", retryAfter: nil)), .emailNotVerified)
        XCTAssertEqual(f(CloudServerError(status: 401, code: "account_deleted", message: "", retryAfter: nil)), .accountDeleted)
        XCTAssertEqual(f(CloudServerError(status: 401, code: "invalid_token", message: "", retryAfter: nil)), .sessionExpired)
        XCTAssertEqual(f(CloudServerError(status: 400, code: "unsupported_envelope", message: "", retryAfter: nil)), .updateRequired)
        XCTAssertEqual(f(CloudSyncRefusal.sampleDataActive), .sampleData)
        XCTAssertEqual(f(AgaraAuthError.network), .offline)
        XCTAssertEqual(f(AgaraAuthError.sessionExpired), .sessionExpired)
        for kind: AgaraCloud.Failure in [.offline, .rateLimited, .serverUnavailable, .emailNotVerified, .accountDeleted, .sessionExpired, .updateRequired, .sampleData] {
            XCTAssertFalse(AgaraCloudCopy.failure(kind).isEmpty)
        }
    }

    func testForegroundKicksRespectTheInterval() async throws {
        try addData()
        try await signInReady()
        let sent = backend.syncRequestCount
        center.kick(reason: .foreground)              // just synced: inside syncIntervalMinutes
        await center.waitForIdle()
        XCTAssertEqual(backend.syncRequestCount, sent)
        backend.state.lastAttempt = CloudDevice.now.addingTimeInterval(-7200)
        try addData(days: 3)
        center.kick(reason: .foreground)
        await center.waitForIdle()
        XCTAssertGreaterThan(backend.syncRequestCount, sent)
    }

    // MARK: The 72 h grace of unverified accounts (decision D10)

    func testAnUnverifiedAccountSyncsInsideTheGraceWindowAndIsBlockedAfterIt() async throws {
        let time = TestClock(Date())
        backend.clock = { time.now }
        backend.graceSeconds = 72 * 3600
        try addData()
        center.acceptConsent()
        await center.signUp(email: email, password: password)
        await center.waitForIdle()
        XCTAssertEqual(center.phase, .needsVerification)
        XCTAssertEqual(center.status, .idle, "synced while unverified: /me said sync_allowed")
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2)
        await center.refreshMe()
        XCTAssertEqual(center.syncAllowed, true)
        XCTAssertNotNil(center.graceEndsAt, "the banner counts down to the end of the grace window")

        time.advance(73 * 3600)
        try addData(days: 4)
        await center.syncNow()
        XCTAssertEqual(center.status, .failed(.emailNotVerified), "blocked once /me says sync_allowed is false")
        XCTAssertEqual(center.syncAllowed, false)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2)
    }

    // MARK: Sign out, delete account, delete all my data

    func testSignOutKeepsConsentAndLocalData() async throws {
        try addData()
        try await signInReady()
        center.signOut()
        XCTAssertEqual(center.phase, .signedOut)
        XCTAssertNil(backend.sessionStore.load())
        XCTAssertTrue(backend.state.hasConsent)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(ledgers.isEmpty)
        XCTAssertTrue(ledgers.allSatisfy { !$0.isSynced }, "block_sync.synced_* is reset on sign-out")
        XCTAssertEqual(backend.state.cursor, "")
        XCTAssertNil(backend.state.ledgerOwner)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2, "signing out does not delete the cloud copy")
    }

    func testDeleteAccountErasesCloudDataFirstThenTokensAndTheLedger() async throws {
        try addData()
        try await signInReady()
        XCTAssertTrue(ledgers.allSatisfy { $0.isSynced })
        let outcome = await center.deleteAccount()
        XCTAssertEqual(outcome, .deleted)
        XCTAssertTrue(backend.serverBlocks(email: email).isEmpty, "cloud data is gone")
        XCTAssertNil(backend.sessionStore.load())
        XCTAssertEqual(backend.state.cursor, "")
        XCTAssertFalse(backend.state.hasConsent, "consent is withdrawn with the account")
        XCTAssertEqual(center.phase, .needsConsent)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(ledgers.isEmpty, "local data stays")
        XCTAssertTrue(ledgers.allSatisfy { $0.syncedHash == nil && $0.syncedRevision == nil }, "the ledger's synced_* columns are wiped")
        // Order: DELETE /me before anything else destructive.
        let deleteIndex = backend.requestLog.firstIndex { $0.method == "DELETE" }
        XCTAssertNotNil(deleteIndex)
    }

    func testDeleteAccountFallsBackToFirebaseWhenTheServerCouldNotDeleteTheUser() async throws {
        try await signInReady()
        backend.serverDeletesFirebaseUser = false
        let outcome = await center.deleteAccount()
        XCTAssertEqual(outcome, .deleted)
        XCTAssertTrue(backend.user(email: email)!.firebaseDeleted, "accounts:delete fallback ran")
        XCTAssertGreaterThanOrEqual(backend.count(pathSuffix: "accounts:delete"), 1)
    }

    func testDeleteAccountAsksForARecentLoginThenSucceeds() async throws {
        try await signInReady()
        backend.ageLogins(by: 1000)
        let first = await center.deleteAccount()
        XCTAssertEqual(first, .needsRecentLogin)
        XCTAssertNotNil(backend.sessionStore.load(), "nothing was wiped")
        let wrong = await center.reauthenticate(password: "wrong-password")
        XCTAssertFalse(wrong)
        let ok = await center.reauthenticate(password: password)
        XCTAssertTrue(ok)
        let second = await center.deleteAccount()
        XCTAssertEqual(second, .deleted)
    }

    func testDeleteAccountOfflineChangesNothing() async throws {
        try addData()
        try await signInReady()
        backend.offline = true
        let outcome = await center.deleteAccount()
        if case .failed = outcome {} else { XCTFail("expected a failure, got \(outcome)") }
        XCTAssertNotNil(backend.sessionStore.load())
        XCTAssertTrue(backend.state.hasConsent)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2)
    }

    func testWipeLocalAccountIsWhatDeleteAllMyDataDoes() async throws {
        try addData()
        try await signInReady()
        center.wipeLocalAccount()
        XCTAssertFalse(center.isSignedIn)
        XCTAssertNil(backend.sessionStore.load(), "tokens cleared")
        XCTAssertFalse(backend.state.hasConsent)
        XCTAssertEqual(backend.state.cursor, "")
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2, "the cloud copy is a separate action (Delete account)")
        XCTAssertEqual(center.phase, .needsConsent)
    }

    func testDeleteAllMyDataAlsoSignsTheCloudOut() async throws {
        try await signInReady()
        let context = ModelContext(container)
        XCTAssertTrue(AgaraCloud.shared.isSignedIn == false, "the shared instance is separate from this test's")
        AppDataWipe.eraseEverything(context: context)
        XCTAssertFalse(AgaraCloud.shared.isSignedIn)
        XCTAssertTrue(ConfirmAction.deleteAllData(cloudSignedIn: true) {}.message.contains(AgaraCloudCopy.deleteAllDataCloudNote))
        XCTAssertFalse(ConfirmAction.deleteAllData(cloudSignedIn: false) {}.message.contains(AgaraCloudCopy.deleteAllDataCloudNote))
        XCTAssertEqual(ConfirmAction.deleteCloudAccount {}.severity, .destructive)
    }
}

extension AgaraCloud {
    /// `signOut()` schedules its auth-client cleanup asynchronously; tests wait for it.
    func signOutAndWait() async {
        signOut()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
