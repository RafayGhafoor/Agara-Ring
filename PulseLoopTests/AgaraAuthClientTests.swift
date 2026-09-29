import XCTest
@testable import PulseLoop

/// Firebase Auth over REST (release 1.1, task 1) against the in-process fake: sign up / in, verification polling,
/// password reset, single-flight token refresh, 401 → one refresh → one retry, sign out, delete, error mapping, and the
/// `X-Ios-Bundle-Identifier` header on every call.
@MainActor
final class AgaraAuthClientTests: XCTestCase {
    private var backend: FakeCloudBackend!
    private var store: AgaraMemoryAuthStore!
    private var auth: AgaraAuthClient!
    private let email = "reader@example.com"

    override func setUp() async throws {
        backend = FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        store = AgaraMemoryAuthStore()
        auth = AgaraAuthClient(config: backend.config, transport: backend, store: store, bundleId: "com.agara.ring")
    }

    // MARK: Sign up / sign in

    func testSignUpCreatesAnUnverifiedSessionAndStoresIt() async throws {
        let session = try await auth.signUp(email: email, password: "password1")
        XCTAssertEqual(session.email, email)
        XCTAssertFalse(session.emailVerified)
        XCTAssertEqual(store.load(), session)
        XCTAssertGreaterThan(session.expiresAt, Date())
        XCTAssertFalse(session.idToken.isEmpty); XCTAssertFalse(session.refreshToken.isEmpty)
    }

    func testSignInReadsEmailVerifiedFromLookup() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        let session = try await auth.signIn(email: email, password: "password1")
        XCTAssertTrue(session.emailVerified)
        XCTAssertEqual(backend.count(pathSuffix: "accounts:lookup"), 1)
    }

    func testErrorMapping() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        await assertThrows(.emailExists) { _ = try await self.auth.signUp(email: self.email, password: "password1") }
        await assertThrows(.invalidEmail) { _ = try await self.auth.signUp(email: "nope", password: "password1") }
        await assertThrows(.invalidCredentials) { _ = try await self.auth.signIn(email: self.email, password: "wrong-password") }
        await assertThrows(.invalidCredentials) { _ = try await self.auth.signIn(email: "ghost@example.com", password: "password1") }
    }

    func testThePasswordPolicyIsCheckedBeforeTheNetworkAndMappedFromFirebase() async throws {
        for bad in ["", "1234567", String(repeating: "x", count: 129)] {
            await assertThrows(.weakPassword) { _ = try await self.auth.signUp(email: "new@example.com", password: bad) }
        }
        XCTAssertTrue(backend.requests.isEmpty, "a too-short or too-long password never leaves the phone")
        _ = try await auth.signUp(email: "edge8@example.com", password: "12345678")
        _ = try await auth.signUp(email: "edge128@example.com", password: String(repeating: "x", count: 128))
        for message in ["PASSWORD_DOES_NOT_MEET_REQUIREMENTS", "PASSWORD_DOES_NOT_MEET_REQUIREMENTS : Missing password requirements: [Password must contain at least 8 characters]"] {
            let body = try JSONSerialization.data(withJSONObject: ["error": ["code": 400, "message": message]])
            XCTAssertEqual(AgaraAuthClient.map(CloudResponse(status: 400, body: body)), .weakPassword)
        }
        XCTAssertEqual(AgaraAuthError.weakPassword.message, "Use a password of 8 to 128 characters.")
        // The fake enforces the same policy server-side (a client that skipped the local check would get it).
        let direct = CloudRequest(method: "POST", url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=k")!,
                                  body: try JSONSerialization.data(withJSONObject: ["email": "s@example.com", "password": "short"]))
        let reply = try await backend.send(direct)
        XCTAssertEqual(reply.status, 400)
        XCTAssertEqual(AgaraAuthClient.map(reply), .weakPassword)
    }

    func testEnumerationProtectionNeverRevealsWhichAddressesExist() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        backend.maskExistingEmail = true       // sign-up of an existing address answers 200 with no tokens
        await assertThrows(.emailExists) { _ = try await self.auth.signUp(email: self.email, password: "password9") }
        XCTAssertNil(store.load(), "no session from a masked reply")
        var messages = Set<String>()
        for (address, pw) in [("ghost@example.com", "password1"), (email, "not-the-password")] {
            do { _ = try await auth.signIn(email: address, password: pw); XCTFail("should throw") }
            catch let error as AgaraAuthError { XCTAssertEqual(error, .invalidCredentials); messages.insert(error.message) }
        }
        XCTAssertEqual(messages.count, 1, "unknown address and wrong password read the same")
        for text in [AgaraAuthError.emailExists.message, AgaraAuthError.invalidCredentials.message] {
            XCTAssertFalse(text.lowercased().contains("already exists"), "no statement about whether an address is registered")
            XCTAssertFalse(text.lowercased().contains("no account"))
            XCTAssertFalse(text.lowercased().contains("wrong password"))
        }
    }

    func testTooManyAttemptsAndNetworkAreMapped() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        // Firebase's own message for throttling.
        let throttled = CloudResponse(status: 400, body: Data(#"{"error":{"code":400,"message":"TOO_MANY_ATTEMPTS_TRY_LATER : Access to this account has been temporarily disabled"}}"#.utf8))
        XCTAssertEqual(AgaraAuthClient.map(throttled), .tooManyAttempts)
        XCTAssertEqual(AgaraAuthClient.map(CloudResponse(status: 400, body: Data(#"{"error":{"message":"WEAK_PASSWORD : short"}}"#.utf8))), .weakPassword)
        XCTAssertEqual(AgaraAuthClient.map(CloudResponse(status: 400, body: Data(#"{"error":{"message":"CREDENTIAL_TOO_OLD_LOGIN_AGAIN"}}"#.utf8))), .recentLoginRequired)
        XCTAssertEqual(AgaraAuthClient.map(CloudResponse(status: 429, body: Data())), .tooManyAttempts)
        backend.offline = true
        await assertThrows(.network) { _ = try await self.auth.signIn(email: self.email, password: "password1") }
    }

    func testEveryMessageIsPlainLanguageWithoutSecrets() {
        let all: [AgaraAuthError] = [.emailExists, .invalidCredentials, .tooManyAttempts, .weakPassword, .invalidEmail, .userDisabled,
                                     .sessionExpired, .recentLoginRequired, .notSignedIn, .notConfigured, .network, .server("TOKEN_SECRET_abc")]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertFalse(error.message.contains("abc"), "server detail must not leak into the UI copy")
        }
    }

    func testNotConfiguredNeverTouchesTheNetwork() async throws {
        var config = backend.config
        config.firebaseApiKey = ""
        let client = AgaraAuthClient(config: config, transport: backend, store: AgaraMemoryAuthStore())
        await assertThrowsOn(client, .notConfigured)
        XCTAssertTrue(backend.requests.isEmpty)
    }

    private func assertThrowsOn(_ client: AgaraAuthClient, _ expected: AgaraAuthError) async {
        do { _ = try await client.signIn(email: email, password: "password1"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AgaraAuthError, expected) }
    }

    // MARK: Verification

    func testVerificationEmailIsSentAndPollingSeesTheClick() async throws {
        try await auth.signUp(email: email, password: "password1")
        try await auth.sendVerificationEmail()
        XCTAssertEqual(backend.emailsSent.last?.kind, "VERIFY_EMAIL")
        XCTAssertEqual(backend.emailsSent.last?.to, email)

        let notYet = try await auth.checkEmailVerified()
        XCTAssertFalse(notYet)
        XCTAssertFalse(store.load()!.emailVerified)

        let refreshesBefore = backend.refreshCount
        backend.markVerified(email: email)
        let now = try await auth.checkEmailVerified()
        XCTAssertTrue(now)
        XCTAssertTrue(store.load()!.emailVerified)
        XCTAssertEqual(backend.refreshCount, refreshesBefore + 1, "the token is force-refreshed so its email_verified claim is current")
    }

    func testPasswordResetSendsForAnAddress() async throws {
        try await auth.sendPasswordReset(email: email)
        XCTAssertEqual(backend.emailsSent.last?.kind, "PASSWORD_RESET")
    }

    // MARK: Refresh

    func testAnExpiredTokenIsRefreshedBeforeUse() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        let clock = TestClock()
        let shifting = AgaraAuthClient(config: backend.config, transport: backend, store: store, now: { clock.now }, bundleId: "com.agara.ring")
        _ = try await shifting.signIn(email: email, password: "password1")
        let first = store.load()!.idToken
        clock.advance(3540)     // inside the 60 s margin of a 3600 s token
        let second = try await shifting.validIdToken()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(backend.refreshCount, 1)
        let third = try await shifting.validIdToken()
        XCTAssertEqual(second, third, "a fresh token is reused")
        XCTAssertEqual(backend.refreshCount, 1)
    }

    func testConcurrentCallersShareOneRefreshRequest() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        let clock = TestClock()
        let shifting = AgaraAuthClient(config: backend.config, transport: backend, store: store, now: { clock.now }, bundleId: "com.agara.ring")
        _ = try await shifting.signIn(email: email, password: "password1")
        clock.advance(4000)
        backend.latency = 0.05
        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<8 { group.addTask { try await shifting.validIdToken() } }
            var out: [String] = []
            for try await token in group { out.append(token) }
            return out
        }
        XCTAssertEqual(Set(tokens).count, 1, "every caller got the same refreshed token")
        XCTAssertEqual(backend.refreshCount, 1, "single-flight: one securetoken request for eight callers")
    }

    func testUnauthorizedRefreshesOnceAndRetriesOnce() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        _ = try await auth.signIn(email: email, password: "password1")
        let api = AgaraCloudAPI(config: backend.config, transport: backend, auth: auth)
        backend.expireAllTokens()
        let me = try await api.me()
        XCTAssertEqual(me.email, email)
        XCTAssertEqual(backend.refreshCount, 1)
        XCTAssertEqual(backend.count(pathSuffix: "/me"), 2, "the 401 and exactly one retry")
    }

    func testASecond401AfterTheRefreshIsSurfacedNotLooped() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        _ = try await auth.signIn(email: email, password: "password1")
        let api = AgaraCloudAPI(config: backend.config, transport: backend, auth: auth)
        backend.inject(.init(pathContains: "/me", status: 401, code: "invalid_token", remaining: 5))
        do { _ = try await api.me(); XCTFail("should throw") }
        catch let error as CloudServerError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(backend.refreshCount, 1)
            XCTAssertEqual(backend.count(pathSuffix: "/me"), 2)
        }
    }

    func testARejectedRefreshTokenSignsTheSessionOut() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        let clock = TestClock()
        let shifting = AgaraAuthClient(config: backend.config, transport: backend, store: store, now: { clock.now }, bundleId: "com.agara.ring")
        _ = try await shifting.signIn(email: email, password: "password1")
        var session = store.load()!
        session.refreshToken = "revoked"
        store.save(session)
        clock.advance(4000)
        do { _ = try await shifting.validIdToken(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AgaraAuthError, .sessionExpired) }
        XCTAssertNil(store.load(), "the dead session is dropped")
    }

    // MARK: Sign out / delete

    func testSignOutClearsTheSession() async throws {
        try await auth.signUp(email: email, password: "password1")
        await auth.signOut()
        XCTAssertNil(store.load())
        do { _ = try await auth.validIdToken(); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AgaraAuthError, .notSignedIn) }
    }

    func testDeleteFirebaseAccountRemovesTheUserAndTheSession() async throws {
        try await auth.signUp(email: email, password: "password1")
        try await auth.deleteFirebaseAccount()
        XCTAssertNil(store.load())
        XCTAssertTrue(backend.user(email: email)!.firebaseDeleted)
    }

    func testReauthenticateUsesTheStoredEmail() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        _ = try await auth.signIn(email: email, password: "password1")
        let before = store.load()!.idToken
        _ = try await auth.reauthenticate(password: "password1")
        XCTAssertNotEqual(before, store.load()!.idToken)
        do { _ = try await auth.reauthenticate(password: "bad-password"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AgaraAuthError, .invalidCredentials) }
    }

    // MARK: Hygiene

    func testEveryFirebaseRequestCarriesTheBundleIdentifierHeader() async throws {
        backend.createUser(email: "b@example.com", password: "password1", verified: true)
        _ = try await auth.signIn(email: "b@example.com", password: "password1")     // signInWithPassword + lookup
        try await auth.sendVerificationEmail()                                          // sendOobCode
        try await auth.sendPasswordReset(email: "b@example.com")                       // sendOobCode
        _ = try await auth.checkEmailVerified()                                         // lookup
        backend.expireAllTokens()
        let clock = TestClock(Date().addingTimeInterval(4000))
        let shifting = AgaraAuthClient(config: backend.config, transport: backend, store: store, now: { clock.now }, bundleId: "com.agara.ring")
        _ = try await shifting.validIdToken()                                           // securetoken refresh
        clock.advance(1)
        try await shifting.deleteFirebaseAccount()                                      // accounts:delete
        let firebase = backend.requests.filter { ($0.url.host ?? "").contains("googleapis") }
        XCTAssertGreaterThanOrEqual(firebase.count, 7)
        for request in firebase {
            XCTAssertEqual(request.headers["X-Ios-Bundle-Identifier"], "com.agara.ring", "\(request.url.path)")
        }
        XCTAssertTrue(firebase.contains { ($0.url.host ?? "").contains("securetoken") }, "the refresh call is covered too")
    }

    func testTheAppTargetSendsItsRealBundleIdentifierByDefault() {
        let headers = AgaraAuthClient.firebaseHeaders(contentType: "application/json", bundleId: Bundle.main.bundleIdentifier)
        XCTAssertEqual(headers["X-Ios-Bundle-Identifier"], Bundle.main.bundleIdentifier)
        XCTAssertNil(AgaraAuthClient.firebaseHeaders(contentType: "x", bundleId: nil)["X-Ios-Bundle-Identifier"])
    }

    func testTheApiKeyTravelsOnlyInTheQueryAndTokensOnlyInAuthorization() async throws {
        backend.createUser(email: email, password: "password1", verified: true)
        _ = try await auth.signIn(email: email, password: "password1")
        let api = AgaraCloudAPI(config: backend.config, transport: backend, auth: auth)
        _ = try await api.me()
        for request in backend.requests {
            for (name, value) in request.headers {
                XCTAssertFalse(value.contains(backend.config.firebaseApiKey), "API key in header \(name)")
                if name != "Authorization" { XCTAssertFalse(value.contains("idtoken."), "token in header \(name)") }
            }
            if let body = request.body, request.url.host?.contains("googleapis") == true, request.url.path.hasSuffix("signInWithPassword") {
                XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(backend.config.firebaseApiKey))
            }
        }
        XCTAssertTrue(backend.requests.filter { ($0.url.host ?? "").contains("googleapis") }.allSatisfy { $0.url.query?.contains("key=") == true })
    }

    // MARK: Helper

    private func assertThrows(_ expected: AgaraAuthError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AgaraAuthError, expected, file: file, line: line) }
    }
}
