import Foundation
import os

/// Minimal PocketBase client for the Agara cloud sync (login + per-user health records).
///
/// Dev base URL is plain HTTP — the lab build carries an ATS exception (see Info.plist). A
/// production build must point `baseURL` at a TLS endpoint and drop the exception.
@MainActor
final class AgaraCloudClient {
    static let shared = AgaraCloudClient()

    /// PocketBase instance on the Agara server (hayden). Collections: `health_days` (one row per
    /// user+date) and `measurements` (one row per user+client_key), both owner-scoped by rules.
    private let baseURL = URL(string: "http://213.136.82.93:8090")!
    private let session = URLSession(configuration: .ephemeral)
    private let defaults = UserDefaults.standard
    private static let log = Logger(subsystem: "com.pulseloop.lab", category: "agara-cloud")

    private enum Key {
        static let token = "agara.authToken"
        static let userID = "agara.userID"
        static let email = "agara.email"
    }

    var authToken: String? { defaults.string(forKey: Key.token) }
    var userID: String? { defaults.string(forKey: Key.userID) }
    var email: String? { defaults.string(forKey: Key.email) }
    var isSignedIn: Bool { authToken != nil }

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
        defaults.set(id, forKey: Key.userID)
        defaults.set(email, forKey: Key.email)
        try await signIn(email: email, password: password)   // get a session token
    }

    private func authenticate(path: String, body: [String: Any], email: String) async throws {
        let json = try await request(path, method: "POST", body: body, authed: false)
        guard let token = json["token"] as? String,
              let record = json["record"] as? [String: Any],
              let id = record["id"] as? String
        else { throw CloudError.message("Login succeeded but the session was malformed") }
        defaults.set(token, forKey: Key.token)
        defaults.set(id, forKey: Key.userID)
        defaults.set(email, forKey: Key.email)
    }

    func signOut() {
        for key in [Key.token, Key.userID, Key.email] { defaults.removeObject(forKey: key) }
    }

    // MARK: Records

    func list(_ collection: String, filter: String? = nil, perPage: Int = 500) async throws -> [[String: Any]] {
        var query: [URLQueryItem] = [.init(name: "perPage", value: String(perPage))]
        if let filter { query.append(.init(name: "filter", value: filter)) }
        let json = try await request("api/collections/\(collection)/records", method: "GET", query: query)
        return (json["items"] as? [[String: Any]]) ?? []
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
        if authed, let token = authToken {
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
            let message = json["message"] as? String ?? "HTTP \(http.statusCode)"
            throw CloudError.message(message)
        }
        return json
    }
}