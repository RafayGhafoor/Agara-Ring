import Foundation

/// A non-2xx answer from the Agara server: `{"status":…,"code":"…","message":"…"}` (cloud-v2.md §4).
nonisolated struct CloudServerError: Error, Equatable, Sendable {
    var status: Int
    var code: String
    var message: String
    /// `Retry-After` in seconds (429 / 503), when the server sent one.
    var retryAfter: TimeInterval?

    var isRateLimited: Bool { status == 429 }
    var isServerSide: Bool { status >= 500 }
}

/// The HTTP client of the Agara server (`/api/agara/*`). Every call carries the Firebase ID token; a `401` for an expired
/// or unknown token triggers exactly one forced refresh and one retry (the single-flight refresh lives in
/// `AgaraAuthClient`). The codes that must never be retried (`account_deleted`, `recent_login_required`, …) are returned
/// as they are.
nonisolated struct AgaraCloudAPI: Sendable {
    let config: AgaraCloudConfig
    let transport: CloudTransport
    let auth: AgaraAuthClient

    /// 401 codes for which a refresh can help.
    static let refreshableCodes: Set<String> = ["token_expired", "invalid_token", "auth_required"]

    func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await sync(body: try WireCodec.encode(request))
    }

    func sync(body: Data) async throws -> SyncResponse {
        let response = try await call("POST", "api/agara/sync", body: body)
        return try Self.decode(SyncResponse.self, response)
    }

    func changes(since: String, limit: Int = 200) async throws -> ChangesResponse {
        let response = try await call("GET", "api/agara/changes", query: [
            URLQueryItem(name: "since", value: since), URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try Self.decode(ChangesResponse.self, response)
    }

    /// `GET api/agara/config?key=…` — a server-side value the app may apply without a release (item F).
    /// Returns the raw record so `SleepScoreConfig` owns the validation: this layer only carries bytes.
    func config(key: String) async throws -> [String: Any]? {
        let response = try await call("GET", "api/agara/config", query: [URLQueryItem(name: "key", value: key)])
        let list = response.json["config"] as? [[String: Any]]
        return list?.first
    }

    func me() async throws -> MeInfo {
        try Self.decode(MeInfo.self, try await call("GET", "api/agara/me"))
    }

    /// Erases the account server-side (data first, Firebase second). Needs a recent login (`recent_login_required`).
    func deleteMe() async throws -> DeleteMeResult {
        let response = try await call("DELETE", "api/agara/me")
        let json = response.json
        return DeleteMeResult(deleted: (json["deleted"] as? Bool) ?? true, firebaseDeleted: (json["firebase_deleted"] as? Bool) ?? false)
    }

    // MARK: Plumbing

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> CloudResponse {
        guard let base = config.baseURL, config.isConfigured else { throw AgaraAuthError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var token = try await auth.validIdToken()
        var refreshed = false
        while true {
            var request = CloudRequest(method: method, url: components.url!)
            request.headers["Authorization"] = "Bearer " + token
            request.headers["Accept"] = "application/json"
            if let body { request.headers["Content-Type"] = "application/json"; request.body = body }
            request.timeout = body == nil ? 20 : 60
            let response = try await transport.send(request)
            if (200...299).contains(response.status) { return response }
            let error = Self.error(from: response)
            if response.status == 401, !refreshed, Self.refreshableCodes.contains(error.code) {
                refreshed = true
                token = try await auth.refreshAfterUnauthorized(staleToken: token)
                continue
            }
            throw error
        }
    }

    static func error(from response: CloudResponse) -> CloudServerError {
        let json = response.json
        let retry = response.header("Retry-After").flatMap(TimeInterval.init)
        return CloudServerError(
            status: response.status,
            code: (json["code"] as? String) ?? "http_\(response.status)",
            message: (json["message"] as? String) ?? "HTTP \(response.status)",
            retryAfter: retry)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ response: CloudResponse) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: response.body) }
        catch { throw CloudServerError(status: response.status, code: "bad_response", message: "Unreadable server reply", retryAfter: nil) }
    }
}
