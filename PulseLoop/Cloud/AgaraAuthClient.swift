import Foundation

// Firebase Auth over its REST API (Identity Toolkit + Secure Token) — no Firebase SDK (release-1.1 spec: smaller
// binary, no extra privacy surface, no telemetry). The HTTP layer is pluggable (`CloudTransport`) and the session
// lives behind `AgaraAuthSessionStore` (the Keychain in the app, memory in tests). Tokens and e-mail addresses are
// never logged.

// MARK: - Session

/// What the app holds for a signed-in account. The ID token lives one hour; the refresh token until revoked.
nonisolated struct AgaraAuthSession: Codable, Equatable, Sendable {
    var uid: String
    var email: String
    var idToken: String
    var refreshToken: String
    var expiresAt: Date
    var emailVerified: Bool
}

nonisolated protocol AgaraAuthSessionStore: Sendable {
    func load() -> AgaraAuthSession?
    func save(_ session: AgaraAuthSession)
    func clear()
}


/// DEBUG ONLY: seed a session from launch arguments so a UI test or screenshot run can be signed in without typing into
/// the form. XCUITest's `typeText` proved unable to fill this screen's secure field (2026-10-20: three runs went out with
/// an empty password), and a live screenshot of a real coach answer is worth more than a typing workaround.
///
///   -cloudTestSession "<json>"   the AgaraAuthSession JSON, minified, produced by scripts/coach_live_session.py
///
/// Never compiled into a release build, and it does not bypass anything server-side: the token is a real Firebase ID
/// token and the server verifies it like any other.
nonisolated struct AgaraLaunchArgumentSessionStore: AgaraAuthSessionStore {
    private let inner: AgaraAuthSessionStore
    private let injected: AgaraAuthSession?

    init(inner: AgaraAuthSessionStore) {
        self.inner = inner
        #if DEBUG
        if let raw = DebugLaunch.string("cloudTestSession"), let data = raw.data(using: .utf8),
           let session = try? JSONDecoder().decode(AgaraAuthSession.self, from: data) {
            injected = session
            inner.save(session)
        } else {
            injected = nil
        }
        #else
        injected = nil
        #endif
    }

    func load() -> AgaraAuthSession? { injected ?? inner.load() }
    func save(_ session: AgaraAuthSession) { inner.save(session) }
    func clear() { inner.clear() }
}

/// The Keychain (`AfterFirstUnlockThisDeviceOnly`, see `KeychainItem`): one item holding the session as JSON, so a
/// save is atomic and a wipe is one delete. The service name is install-bound.
nonisolated struct AgaraKeychainAuthStore: AgaraAuthSessionStore {
    var service = "com.agara.cloud.v2"   // install-bound
    private let account = "session"

    func load() -> AgaraAuthSession? {
        guard let data = (try? KeychainItem.read(service: service, account: account)) ?? nil else { return nil }
        return try? JSONDecoder().decode(AgaraAuthSession.self, from: data)
    }

    func save(_ session: AgaraAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? KeychainItem.write(data, service: service, account: account)
    }

    func clear() { try? KeychainItem.delete(service: service, account: account) }
}

/// Memory store for tests and the debug fake backend.
nonisolated final class AgaraMemoryAuthStore: AgaraAuthSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AgaraAuthSession?
    init(_ session: AgaraAuthSession? = nil) { self.session = session }
    func load() -> AgaraAuthSession? { lock.lock(); defer { lock.unlock() }; return session }
    func save(_ session: AgaraAuthSession) { lock.lock(); self.session = session; lock.unlock() }
    func clear() { lock.lock(); session = nil; lock.unlock() }
}

// MARK: - Errors

nonisolated enum AgaraAuthError: Error, Equatable, Sendable {
    case emailExists
    case invalidCredentials
    case tooManyAttempts
    case weakPassword
    case invalidEmail
    case userDisabled
    /// The refresh token was rejected (revoked, account deleted or disabled): the user must sign in again.
    case sessionExpired
    /// Firebase wants a fresh sign-in for this action (`CREDENTIAL_TOO_OLD_LOGIN_AGAIN`).
    case recentLoginRequired
    case notSignedIn
    case notConfigured
    case network
    case server(String)

    /// Plain-language message for the UI (all cloud copy lives in `AgaraCloudCopy`).
    var message: String { AgaraCloudCopy.authError(self) }
}

extension AgaraAuthError: LocalizedError {
    var errorDescription: String? { message }
}

// MARK: - Client

/// Sign-up, sign-in, verification, reset, refresh and delete. An actor, so token refresh is **single-flight**: any
/// number of concurrent callers waiting on an expired token share one refresh request.
actor AgaraAuthClient {
    private let config: AgaraCloudConfig
    private let transport: CloudTransport
    private let store: AgaraAuthSessionStore
    private let now: @Sendable () -> Date
    /// Sent as `X-Ios-Bundle-Identifier` on every Firebase call: Google enforces the "iOS apps" restriction of the API key with it.
    private let bundleId: String?
    private var refreshTask: Task<AgaraAuthSession, Error>?
    /// Refresh this long before the token actually expires.
    static let expiryMargin: TimeInterval = 60

    init(config: AgaraCloudConfig, transport: CloudTransport, store: AgaraAuthSessionStore,
         now: @escaping @Sendable () -> Date = { Date() },
         bundleId: String? = Bundle.main.bundleIdentifier) {
        self.bundleId = bundleId
        self.config = config
        self.transport = transport
        self.store = store
        self.now = now
    }

    /// The stored session, if any (a cheap Keychain read).
    var session: AgaraAuthSession? { store.load() }
    var isSignedIn: Bool { store.load() != nil }

    // MARK: Account lifecycle

    /// `accounts:signUp` — creates the account and signs in. The account is unverified until the e-mail link is used.
    @discardableResult
    func signUp(email: String, password: String) async throws -> AgaraAuthSession {
        // The Firebase project enforces 8...128 characters; refuse locally so a bad password never leaves the phone.
        guard Self.passwordLengthOK(password) else { throw AgaraAuthError.weakPassword }
        let json = try await identity("accounts:signUp",
                                      ["email": email, "password": password, "returnSecureToken": true])
        // With email-enumeration protection Firebase may answer an existing address with a success-like reply that carries no
        // tokens: treat it exactly like EMAIL_EXISTS (and word both without saying which addresses exist).
        guard json["idToken"] is String else { throw AgaraAuthError.emailExists }
        return try adopt(json, fallbackEmail: email, verified: false)
    }

    /// The project's password policy: 8 to 128 characters, nothing else.
    static func passwordLengthOK(_ password: String) -> Bool { (8...128).contains(password.count) }

    /// `accounts:signInWithPassword`, then `accounts:lookup` for `emailVerified` (the sign-in reply does not carry it).
    @discardableResult
    func signIn(email: String, password: String) async throws -> AgaraAuthSession {
        let json = try await identity("accounts:signInWithPassword",
                                      ["email": email, "password": password, "returnSecureToken": true])
        var session = try adopt(json, fallbackEmail: email, verified: false)
        if let verified = try? await lookupVerified(idToken: session.idToken) {
            session.emailVerified = verified
            store.save(session)
        }
        return session
    }

    /// Sign in again with the stored e-mail (the server's "recent login" rule for export and delete).
    @discardableResult
    func reauthenticate(password: String) async throws -> AgaraAuthSession {
        guard let current = store.load() else { throw AgaraAuthError.notSignedIn }
        return try await signIn(email: current.email, password: password)
    }

    /// `accounts:sendOobCode` (`VERIFY_EMAIL`) for the signed-in user.
    func sendVerificationEmail() async throws {
        let token = try await validIdToken()
        _ = try await identity("accounts:sendOobCode", ["requestType": "VERIFY_EMAIL", "idToken": token])
    }

    /// `accounts:sendOobCode` (`PASSWORD_RESET`). Firebase answers the same for unknown addresses (enumeration protection).
    func sendPasswordReset(email: String) async throws {
        _ = try await identity("accounts:sendOobCode", ["requestType": "PASSWORD_RESET", "email": email])
    }

    /// Ask Firebase whether the address is verified now. When it just became verified, force-refresh the ID token so
    /// its `email_verified` claim is true (the server reads the claim; an hour-old token would keep saying false).
    @discardableResult
    func checkEmailVerified() async throws -> Bool {
        guard let current = store.load() else { throw AgaraAuthError.notSignedIn }
        let token = try await validIdToken()
        let verified = try await lookupVerified(idToken: token)
        if verified, !current.emailVerified {
            _ = try await refresh(staleToken: nil)   // the token's own claim must say verified too
            if var updated = store.load() { updated.emailVerified = true; store.save(updated) }
        } else if !verified, current.emailVerified {
            if var updated = store.load() { updated.emailVerified = false; store.save(updated) }
        }
        return verified
    }

    /// Forget the account on this device (no network).
    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        store.clear()
    }

    /// `accounts:delete` — the fallback of the account-deletion flow when the server could not delete the Firebase user.
    func deleteFirebaseAccount() async throws {
        let token = try await validIdToken()
        _ = try await identity("accounts:delete", ["idToken": token])
        store.clear()
    }

    // MARK: Tokens

    /// A token good for at least the expiry margin; refreshes (single-flight) when needed.
    func validIdToken() async throws -> String {
        guard let session = store.load() else { throw AgaraAuthError.notSignedIn }
        if session.expiresAt.timeIntervalSince(now()) > Self.expiryMargin { return session.idToken }
        return try await refresh(staleToken: session.idToken).idToken
    }

    /// Replace the ID token now (its claims may be out of date, e.g. `email_verified` after the link was used).
    func forceRefresh() async throws {
        _ = try await refresh(staleToken: nil)
    }

    /// The server said `401` for `staleToken`: refresh once. If another caller already replaced the token, that one is used
    /// and no second request goes out (single-flight).
    func refreshAfterUnauthorized(staleToken: String) async throws -> String {
        try await refresh(staleToken: staleToken).idToken
    }

    private func refresh(staleToken: String?) async throws -> AgaraAuthSession {
        guard let current = store.load() else { throw AgaraAuthError.notSignedIn }
        if let staleToken, current.idToken != staleToken { return current }   // somebody already refreshed
        if let refreshTask { return try await refreshTask.value }
        let bundleId = self.bundleId
        let task = Task { [config, transport, store, now] () throws -> AgaraAuthSession in
            let body = "grant_type=refresh_token&refresh_token=" + Self.formEncode(current.refreshToken)
            let url = Self.url(config.secureTokenBase, path: "v1/token", key: config.firebaseApiKey)
            let response: CloudResponse
            do {
                response = try await transport.send(CloudRequest(
                    method: "POST", url: url,
                    headers: Self.firebaseHeaders(contentType: "application/x-www-form-urlencoded", bundleId: bundleId), body: Data(body.utf8)))
            } catch { throw AgaraAuthError.network }
            guard (200...299).contains(response.status) else {
                let error = Self.map(response)
                if error == .sessionExpired || error == .userDisabled { store.clear() }
                throw error
            }
            let json = response.json
            guard let idToken = json["id_token"] as? String, let refreshToken = json["refresh_token"] as? String
            else { throw AgaraAuthError.server("malformed refresh reply") }
            let ttl = Double((json["expires_in"] as? String) ?? "") ?? (json["expires_in"] as? Double) ?? 3600
            var updated = current
            updated.idToken = idToken
            updated.refreshToken = refreshToken
            updated.expiresAt = now().addingTimeInterval(ttl)
            if let uid = json["user_id"] as? String, !uid.isEmpty { updated.uid = uid }
            store.save(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: Plumbing

    private func lookupVerified(idToken: String) async throws -> Bool {
        let json = try await identity("accounts:lookup", ["idToken": idToken])
        guard let user = (json["users"] as? [[String: Any]])?.first else { throw AgaraAuthError.sessionExpired }
        return (user["emailVerified"] as? Bool) ?? false
    }

    private func adopt(_ json: [String: Any], fallbackEmail: String, verified: Bool) throws -> AgaraAuthSession {
        guard let idToken = json["idToken"] as? String, let refreshToken = json["refreshToken"] as? String,
              let uid = json["localId"] as? String
        else { throw AgaraAuthError.server("malformed auth reply") }
        let ttl = Double((json["expiresIn"] as? String) ?? "") ?? (json["expiresIn"] as? Double) ?? 3600
        let session = AgaraAuthSession(
            uid: uid, email: (json["email"] as? String) ?? fallbackEmail, idToken: idToken, refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(ttl), emailVerified: verified)
        store.save(session)
        return session
    }

    /// One Identity Toolkit call (JSON in, JSON out).
    private func identity(_ method: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard config.isConfigured else { throw AgaraAuthError.notConfigured }
        let url = Self.url(config.identityToolkitBase, path: "v1/\(method)", key: config.firebaseApiKey)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw AgaraAuthError.server("encode") }
        let response: CloudResponse
        do {
            response = try await transport.send(CloudRequest(
                method: "POST", url: url, headers: Self.firebaseHeaders(contentType: "application/json", bundleId: bundleId), body: data))
        } catch is CancellationError { throw CancellationError() } catch { throw AgaraAuthError.network }
        guard (200...299).contains(response.status) else { throw Self.map(response) }
        return response.json
    }

    /// Headers for a Firebase REST call. The API key rides in the query string (Google's contract) and is never logged.
    static func firebaseHeaders(contentType: String, bundleId: String?) -> [String: String] {
        var headers = ["Content-Type": contentType]
        if let bundleId, !bundleId.isEmpty { headers["X-Ios-Bundle-Identifier"] = bundleId }
        return headers
    }

    private static func url(_ base: URL, path: String, key: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url!
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Firebase's `{"error":{"code":400,"message":"EMAIL_EXISTS"}}` (the message may carry a `" : detail"` suffix).
    static func map(_ response: CloudResponse) -> AgaraAuthError {
        let raw = ((response.json["error"] as? [String: Any])?["message"] as? String) ?? ""
        let code = raw.components(separatedBy: " : ").first?.trimmingCharacters(in: .whitespaces) ?? raw
        if raw.contains("PASSWORD_DOES_NOT_MEET_REQUIREMENTS") { return .weakPassword }
        switch code {
        case "EMAIL_EXISTS": return .emailExists
        case "INVALID_LOGIN_CREDENTIALS", "INVALID_PASSWORD", "EMAIL_NOT_FOUND", "INVALID_CREDENTIAL": return .invalidCredentials
        case "TOO_MANY_ATTEMPTS_TRY_LATER": return .tooManyAttempts
        case "WEAK_PASSWORD": return .weakPassword
        case "INVALID_EMAIL", "MISSING_EMAIL": return .invalidEmail
        case "USER_DISABLED": return .userDisabled
        case "TOKEN_EXPIRED", "USER_NOT_FOUND", "INVALID_REFRESH_TOKEN", "INVALID_ID_TOKEN", "MISSING_REFRESH_TOKEN": return .sessionExpired
        case "CREDENTIAL_TOO_OLD_LOGIN_AGAIN": return .recentLoginRequired
        default:
            if response.status == 429 { return .tooManyAttempts }
            return .server(code.isEmpty ? "HTTP \(response.status)" : code)
        }
    }
}
