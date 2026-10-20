import Foundation

/// A user-facing failure for a coach turn, shown as a red-bordered error bubble
/// in chat. Provider-agnostic: every `ResponsesClient` (OpenAI, Gemini,
/// OpenRouter) throws `ResponsesError`, which maps to a short `code` (e.g.
/// "HTTP 401", "Network", "No output") plus a human-readable `reason`.
///
/// An Agara Cloud turn additionally carries a typed ``Kind``: the proxy's error
/// codes (`docs/ring/coach-proxy.md` §9) map to exactly one each, so a caller can
/// branch on the failure (retry, "resets at …", sign in) instead of matching on
/// strings. Turns from the other providers leave it `nil`.
nonisolated struct CoachTurnError: Equatable, Codable {
    /// Which failure this is. `nil` for the non-cloud providers.
    let kind: Kind?
    /// Short, scannable code shown in the bubble header (e.g. "HTTP 429").
    let code: String
    /// The full reason text shown beneath the header.
    let reason: String

    init(code: String, reason: String, kind: Kind? = nil) {
        self.kind = kind
        self.code = code
        self.reason = reason
    }

    /// One Cloud coach failure. The raw values ARE the server's codes, so a code off the wire maps by lookup and a
    /// stored bubble reads the same in a support log.
    nonisolated enum Kind: String, Codable, Sendable {
        case badRequest = "coach_bad_request"
        case version = "coach_version"
        case unauthorized = "coach_unauthorized"
        case emailNotVerified = "email_not_verified"
        case disabled = "coach_disabled"
        case busy = "coach_busy"
        case turnExpired = "coach_turn_expired"
        case tooLarge = "coach_too_large"
        case quotaMinute = "coach_quota_minute"
        case quotaDay = "coach_quota_day"
        case quotaMonth = "coach_quota_month"
        case costCap = "coach_cost_cap"
        case ipLimit = "coach_ip_limit"
        case breaker = "coach_breaker"
        case upstream = "coach_upstream"
        case badAnswer = "coach_bad_answer"

        /// The short label the bubble shows next to "Coach error".
        var label: String {
            switch self {
            case .badRequest: return "Bad request"
            case .version: return "Update the app"
            case .unauthorized: return "Sign in again"
            case .emailNotVerified: return "Verify e-mail"
            case .disabled: return "Coach unavailable"
            case .busy: return "Coach busy"
            case .turnExpired: return "Answer expired"
            case .tooLarge: return "Too large"
            case .quotaMinute: return "Just a moment"
            case .quotaDay: return "Daily limit"
            case .quotaMonth: return "Monthly limit"
            case .costCap: return "Daily limit"
            case .ipLimit: return "Rate limited"
            case .breaker: return "Coach is resting"
            case .upstream: return "Provider error"
            case .badAnswer: return "Bad answer"
            }
        }

        /// What happened and what the user can do, in the server's words when it sent none (contract §9: the
        /// server's own `message` is user-safe and is preferred over this).
        var guidance: String {
            switch self {
            case .badRequest:
                return "The coach couldn't read that request. Try rephrasing it."
            case .version:
                return "This version of the app can't talk to the coach any more. Update Agara from the App Store."
            case .unauthorized:
                return "Your Agara Cloud session has expired. Sign in again to keep using the coach."
            case .emailNotVerified:
                return "Verify your e-mail address to use the cloud coach. Open Settings › Agara Cloud to resend the link."
            case .disabled:
                return "The coach is unavailable right now. The on-device coach still works."
            case .busy:
                return "The coach is still answering your previous question. Try again in a moment."
            case .turnExpired:
                return "That answer took too long and expired. Ask again to restart the turn."
            case .tooLarge:
                return "That request was too large to send. Ask a shorter question."
            case .quotaMinute:
                return "You've sent several questions in a row. Try again in a moment."
            case .quotaDay:
                return "You've used today's coach messages."
            case .quotaMonth:
                return "You've used this month's coach messages."
            case .costCap:
                return "Today's coach budget for your account is used up."
            case .ipLimit:
                return "Too many coach requests from this network. Try again later."
            case .breaker:
                return "The coach is taking a break. Try again later."
            case .upstream:
                return "The coach couldn't reach the AI provider. Try again."
            case .badAnswer:
                return "The coach's answer didn't come through properly. Try again."
            }
        }
    }

    /// Plain-text form stored in `CoachMessage.body` (history/search fallback).
    var plainText: String { "Coach error · \(code)\n\(reason)" }

    /// JSON form stored in `CoachMessage.cardsJSON` so the error bubble can render
    /// the structured code/reason. Reuses the existing field — no schema change.
    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(fromJSON json: String?) -> CoachTurnError? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachTurnError.self, from: data)
    }

    /// Tolerant decode: bubbles stored before `kind` existed (and any future field) still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
        code = try container.decode(String.self, forKey: .code)
        reason = try container.decode(String.self, forKey: .reason)
    }

    /// Maps a thrown error into a displayable code + reason. Handles the app's
    /// `ResponsesError`, Agara Cloud and transport cases explicitly and falls back
    /// to `localizedDescription`.
    init(_ error: Error) {
        if let e = error as? ResponsesError {
            switch e {
            case .missingAPIKey:
                self.init(code: "No API key", reason: "No API key is configured for the selected provider. Add one in Settings → AI Coach.")
            case .transport(let underlying):
                self.init(code: "Network", reason: underlying.localizedDescription)
            case .http(let status, let body):
                self.init(code: "HTTP \(status)", reason: CoachTurnError.cleanReason(from: body, status: status))
            case .decoding(let msg):
                self.init(code: "Response error", reason: msg)
            case .emptyOutput:
                self.init(code: "No output", reason: "The model returned an empty response. Try again, or pick a different model.")
            }
        } else if let e = error as? CoachCloudFailure {
            self.init(e)
        } else if let e = error as? CloudTransportError {
            let reason = switch e {
            case .offline: "No internet connection. Reconnect and try again."
            case .timedOut: "The coach took too long to answer. Try again."
            case .other: "The connection to the coach failed. Try again."
            }
            self.init(code: "Network", reason: reason, kind: .upstream)
        } else {
            self.init(code: "Error", reason: error.localizedDescription)
        }
    }

    /// A Cloud failure as the bubble shows it. The server's `message` is user-safe by construction (contract §9) and
    /// wins; when the kind is one the user can act on, the reset/retry hint is appended.
    init(_ failure: CoachCloudFailure) {
        var reason = failure.message ?? failure.kind.guidance
        if let hint = failure.waitHint {
            reason += reason.hasSuffix(".") ? " " : ". "
            reason += hint
        }
        self.init(code: failure.kind.label, reason: reason, kind: failure.kind)
    }

    /// Extracts a readable message from a provider error body, which is usually
    /// JSON like `{"error":{"message":"..."}}` (OpenAI/OpenRouter) or
    /// `{"error":{"message":"...","status":"..."}}` (Gemini). Falls back to the
    /// raw body (trimmed) when it isn't that shape.
    private static func cleanReason(from body: String, status: Int) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // {"error": {"message": "..."}} or {"error": "..."}
            if let errObj = root["error"] as? [String: Any], let msg = errObj["message"] as? String, !msg.isEmpty {
                return msg
            }
            if let errStr = root["error"] as? String, !errStr.isEmpty {
                return errStr
            }
            if let msg = root["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        if trimmed.isEmpty {
            return "The provider returned HTTP \(status) with no details."
        }
        return String(trimmed.prefix(400))
    }
}
