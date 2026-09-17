import Foundation
import os

/// Minimal PocketBase client for the Agara cloud sync (login + per-user health records).
///
/// Dev base URL is plain HTTP — the lab build carries an ATS exception (see Info.plist). A
/// production build must point `baseURL` at a TLS endpoint and drop the exception.
/// The signed-in session, as the client sees it. A protocol so tests can drive the client with an
/// in-memory store instead of the real `UserDefaults` (mirrors Android's `AgaraCloudSession`).
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

/// `UserDefaults`-backed session (iOS keeps the token in the app's defaults; Android encrypts it).
@MainActor
final class AgaraUserDefaultsSession: AgaraCloudSession {
    private let defaults: UserDefaults
    private enum Key {
        static let token = "agara.authToken"
        static let userID = "agara.userID"
        static let email = "agara.email"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var token: String? { defaults.string(forKey: Key.token) }
    var userID: String? { defaults.string(forKey: Key.userID) }
    var email: String? { defaults.string(forKey: Key.email) }
    var isSignedIn: Bool { token != nil }

    func saveSession(token: String, userID: String, email: String) {
        defaults.set(token, forKey: Key.token)
        defaults.set(userID, forKey: Key.userID)
        defaults.set(email, forKey: Key.email)
    }

    func rememberIdentity(userID: String, email: String) {
        defaults.set(userID, forKey: Key.userID)
        defaults.set(email, forKey: Key.email)
    }

    func clear() {
        for key in [Key.token, Key.userID, Key.email] { defaults.removeObject(forKey: key) }
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
        self.store = store ?? AgaraUserDefaultsSession()
        let override = UserDefaults.standard.string(forKey: "cloudBaseUrl").flatMap(URL.init(string:))
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