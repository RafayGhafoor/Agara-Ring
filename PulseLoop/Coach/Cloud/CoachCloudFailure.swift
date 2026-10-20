import Foundation

/// One typed failure of the Agara Cloud coach: the proxy's error body (contract `docs/ring/coach-proxy.md` §9),
/// mapped to exactly one `CoachTurnError.Kind`.
///
/// The server's `code` is authoritative — every code in the table maps to its own case — and its `message` is
/// **user-safe by construction** (generated from the code and the server's catalog copy, never from upstream text),
/// so `message` is preferred over anything the app could invent. `retry_after_seconds` / `reset_at` (body) and
/// `Retry-After` (header) ride along so the bubble can say when it is worth trying again.
nonisolated struct CoachCloudFailure: Error, Equatable, Sendable {
    var kind: CoachTurnError.Kind
    /// The HTTP status the server answered with (0 for a failure detected before any reply).
    var status: Int
    /// The server's code as received; empty when the reply carried none.
    var code: String
    /// The server's user-safe sentence, when it sent one.
    var message: String?
    var retryAfter: TimeInterval?
    var resetAt: Date?

    init(kind: CoachTurnError.Kind, status: Int = 0, code: String = "", message: String? = nil,
         retryAfter: TimeInterval? = nil, resetAt: Date? = nil) {
        self.kind = kind
        self.status = status
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.resetAt = resetAt
    }

    /// Decodes `{"code","message","retry_after_seconds"?,"reset_at"?}`. The body is authoritative; a reply without a
    /// readable body still maps by status so the app never shows an untyped failure.
    static func from(status: Int, body: Data, headers: [String: String] = [:]) -> CoachCloudFailure {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let code = json["code"] as? String ?? ""
        let retryAfter = (json["retry_after_seconds"] as? Double)
            ?? (json["retry_after_seconds"] as? Int).map(TimeInterval.init)
            ?? header(headers, "Retry-After").flatMap { Double($0) }
        return CoachCloudFailure(
            kind: kind(code: code, status: status),
            status: status,
            code: code,
            message: (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            retryAfter: retryAfter,
            resetAt: AppClock.parse((json["reset_at"] as? String) ?? header(headers, "X-Coach-Day-Resets-At")))
    }

    /// §9's table. The code wins over the status (they agree in the contract, but a proxy may rewrite the status);
    /// an unknown code falls back to its status so every reply still lands on a typed case.
    static func kind(code: String, status: Int) -> CoachTurnError.Kind {
        if let known = CoachTurnError.Kind(rawValue: code) { return known }
        switch status {
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .disabled
        case 409: return .busy
        case 413: return .tooLarge
        case 429: return .quotaDay        // a bare 429: the day limit is the one worth naming
        case 502: return .upstream
        case 503: return .breaker
        default: return .upstream
        }
    }

    /// "Resets at 9:41 PM" / "Try again in 30 seconds", for the kinds where waiting helps.
    var waitHint: String? {
        if let resetAt {
            return "Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))."
        }
        guard let retryAfter, retryAfter > 0 else { return nil }
        let seconds = Int(retryAfter.rounded())
        if seconds < 60 { return "Try again in \(seconds) second\(seconds == 1 ? "" : "s")." }
        let minutes = (seconds + 59) / 60
        return "Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    private static func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
