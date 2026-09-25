import Foundation
import os

/// Minimal PocketBase client for the Agara cloud sync (login + per-user health records).
///
/// Dev base URL is plain HTTP — the lab build carries an ATS exception (see Info.plist). A
/// production build must point `baseURL` at a TLS endpoint and drop the exception.
/// The signed-in session, as the client sees it. A protocol so tests can drive the client with an
/// in-memory store instead of the real Keychain (mirrors Android's `AgaraCloudSession`).
@MainActor
protocol AgaraCloudSession {
    var token: String? { get }
    var userID: String? { get }
    var email: String? { get }
    var isSignedIn: Bool { get }
    func saveSession(token: String, userID: String, email: String)
    func rememberIdentity(userID: String, email: String)
    func clear()
}

/// Where the session's three strings live. A protocol so the migration can be tested without the Keychain.
nonisolated protocol AgaraSecretStore {
    func string(for account: String) -> String?
    func set(_ value: String, for account: String)
    func remove(_ account: String)
}

/// The real Keychain (`AfterFirstUnlockThisDeviceOnly`, see `KeychainItem`) under one service.
nonisolated struct AgaraKeychainSecretStore: AgaraSecretStore {
    var service = "com.agara.cloud"
    func string(for account: String) -> String? {
        (try? KeychainItem.readString(service: service, account: account)) ?? nil
    }
    func set(_ value: String, for account: String) {
        try? KeychainItem.writeString(value, service: service, account: account)
    }
    func remove(_ account: String) {
        try? KeychainItem.delete(service: service, account: account)
    }
}

/// Keychain-backed session (Android keeps it in EncryptedSharedPreferences). Builds before 2026-09-26 kept
/// the token, user id and email in `UserDefaults` — a plain plist that rides in device backups; the first
/// session created after the update moves them into the Keychain and deletes the old keys.
@MainActor
final class AgaraKeychainSession: AgaraCloudSession {
    private let secrets: AgaraSecretStore
    /// The pre-Keychain `UserDefaults` keys (only read to migrate them away).
    enum LegacyKey {
        static let token = "agara.authToken"
        static let userID = "agara.userID"
        static let email = "agara.email"
        static let all = [token, userID, email]
    }
    private enum Account {
        static let token = "auth_token"
        static let userID = "user_id"
        static let email = "email"
    }

    init(secrets: AgaraSecretStore = AgaraKeychainSecretStore(), legacyDefaults: UserDefaults = .standard) {
        self.secrets = secrets
        Self.migrate(from: legacyDefaults, to: secrets)
    }

    /// Copy any legacy value the Keychain doesn't already hold, then delete every legacy key.
    static func migrate(from defaults: UserDefaults, to secrets: AgaraSecretStore) {
        let pairs = [(LegacyKey.token, Account.token), (LegacyKey.userID, Account.userID), (LegacyKey.email, Account.email)]
        for (legacy, account) in pairs {
            guard let value = defaults.string(forKey: legacy) else { continue }
            if secrets.string(for: account) == nil, !value.isEmpty { secrets.set(value, for: account) }
            defaults.removeObject(forKey: legacy)
        }
    }

    var token: String? { secrets.string(for: Account.token) }
    var userID: String? { secrets.string(for: Account.userID) }
    var email: String? { secrets.string(for: Account.email) }
    var isSignedIn: Bool { token != nil }

    func saveSession(token: String, userID: String, email: String) {
        secrets.set(token, for: Account.token)
        secrets.set(userID, for: Account.userID)
        secrets.set(email, for: Account.email)
    }

    func rememberIdentity(userID: String, email: String) {
        secrets.set(userID, for: Account.userID)
        secrets.set(email, for: Account.email)
    }

    func clear() {
        for account in [Account.token, Account.userID, Account.email] { secrets.remove(account) }
    }
}

@MainActor
final class AgaraCloudClient {
    static let shared = AgaraCloudClient()

    /// PocketBase instance on the Agara server (hayden). Collections: `health_days` (one row per
    /// user+date) and `measurements` (one row per user+client_key), both owner-scoped by rules.
    /// The endpoint actually in use: the catalog default, unless `-cloudBaseUrl <url>` points this
    /// build at another PocketBase (the local test instance in the runbook) — the iOS twin of
    /// Android's `--es cloudBaseUrl`.
    let baseURL: URL
    private let session: URLSession
    private let store: AgaraCloudSession
    private static let log = Logger(subsystem: "com.pulseloop.lab", category: "agara-cloud")

    init(
        store: AgaraCloudSession? = nil,
        baseURL: URL? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.store = store ?? AgaraKeychainSession()
        let override = DebugLaunch.string("cloudBaseUrl").flatMap(URL.init(string:))
        self.baseURL = baseURL ?? override ?? URL(string: AgaraConfig.Cloud.baseUrl)!
        self.session = session
    }

    var userID: String? { store.userID }
    var email: String? { store.email }
    var isSignedIn: Bool { store.isSignedIn }

    enum CloudError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(text) = self { return text }
            return "Unknown cloud error"
        }
    }

    // MARK: Auth

    func signIn(email: String, password: String) async throws {
        try await authenticate(path: "api/collections/users/auth-with-password",
                               body: ["identity": email, "password": password], email: email)
    }

    func register(email: String, password: String) async throws {
        let json = try await request(
            "api/collections/users/records", method: "POST",
            body: ["email": email, "password": password, "passwordConfirm": password]
        )
        guard let id = json["id"] as? String else { throw CloudError.message("Sign-up did not return a record") }
        store.rememberIdentity(userID: id, email: email)
        try await signIn(email: email, password: password)   // get a session token
    }

    private func authenticate(path: String, body: [String: Any], email: String) async throws {
        let json = try await request(path, method: "POST", body: body, authed: false)
        guard let token = json["token"] as? String,
              let record = json["record"] as? [String: Any],
              let id = record["id"] as? String
        else { throw CloudError.message("Login succeeded but the session was malformed") }
        store.saveSession(token: token, userID: id, email: email)
    }

    func signOut() {
        store.clear()
    }

    // MARK: Records

    /// Read a whole collection `filter`ed to one user, **paging through it**.
    ///
    /// PocketBase caps `perPage` (500 by default), so a single request silently truncates: with
    /// ~6 000 readings in a 62-day account a push would see only the first 500 keys, treat the rest
    /// as new and then fail on the server's unique index, while a pull would restore 500 readings and
    /// look like it worked. Pagination is part of the contract, not an optimisation.
    func list(_ collection: String, filter: String? = nil, perPage: Int = 500) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        var page = 1
        while true {
            var query: [URLQueryItem] = [
                .init(name: "perPage", value: String(perPage)),
                .init(name: "page", value: String(page)),
            ]
            if let filter { query.append(.init(name: "filter", value: filter)) }
            let json = try await request("api/collections/\(collection)/records", method: "GET", query: query)
            let items = (json["items"] as? [[String: Any]]) ?? []
            collected.append(contentsOf: items)
            let totalPages = (json["totalPages"] as? NSNumber)?.intValue ?? 1
            if page >= totalPages || items.isEmpty { break }
            page += 1
        }
        return collected
    }

    @discardableResult
    func create(_ collection: String, body: [String: Any]) async throws -> [String: Any] {
        try await request("api/collections/\(collection)/records", method: "POST", body: body)
    }

    @discardableResult
    func update(_ collection: String, recordID: String, body: [String: Any]) async throws -> [String: Any] {
        try await request("api/collections/\(collection)/records/\(recordID)", method: "PATCH", body: body)
    }

    // MARK: Transport

    private func request(
        _ path: String,
        method: String,
        body: [String: Any]? = nil,
        query: [URLQueryItem] = [],
        authed: Bool = true
    ) async throws -> [String: Any] {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if authed, let token = store.token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("No response from server") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(http.statusCode) else {
            var message = json["message"] as? String ?? "HTTP \(http.statusCode)"
            // PocketBase puts the per-field reasons under `data` — surface the first one (e.g. the
            // password-min-length rule) instead of the generic "Failed to create record.".
            if let dataErrors = json["data"] as? [String: Any],
               let first = dataErrors.values.compactMap({ ($0 as? [String: Any])?["message"] as? String }).first
            {
                message = first
            }
            throw CloudError.message(message)
        }
        return json
    }
}