import Foundation

/// Turns left, read from the Cloud coach's quota headers (contract `docs/ring/coach-proxy.md` §9). This is the data
/// behind the coach's "24 left today" pill: the server counts a turn when it **closes**, so the headers on any reply
/// are the current truth.
nonisolated struct CoachQuota: Equatable, Sendable {
    /// `X-Coach-Remaining-Day` — the header every reply carries, and the only required one.
    var remainingDay: Int
    /// `X-Coach-Remaining-Minute` — present when the reply was within the per-minute limit's accounting.
    var remainingMinute: Int?
    /// `X-Coach-Remaining-Month`.
    var remainingMonth: Int?
    /// `X-Coach-Day-Resets-At` — when the day's turns come back.
    var dayResetsAt: Date?

    /// nil when the reply carried no `X-Coach-Remaining-Day` (a proxy error page, an older server), so the UI keeps
    /// showing the last quota it knew rather than a fabricated zero.
    init?(headers: [String: String]) {
        guard let day = Self.int(headers, "X-Coach-Remaining-Day") else { return nil }
        self.remainingDay = day
        self.remainingMinute = Self.int(headers, "X-Coach-Remaining-Minute")
        self.remainingMonth = Self.int(headers, "X-Coach-Remaining-Month")
        self.dayResetsAt = AppClock.parse(Self.value(headers, "X-Coach-Day-Resets-At"))
    }

    init?(response: CloudResponse) { self.init(headers: response.headers) }

    private static func int(_ headers: [String: String], _ name: String) -> Int? {
        value(headers, name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// HTTP header names are case-insensitive; `CloudResponse` keeps them as `String(describing:)`.
    private static func value(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The latest quota, in one place. A `ResponsesClient` is built per turn and thrown away, so the headers cannot live
/// on the client; the chat surface reads this store instead.
@MainActor
@Observable
final class CoachQuotaStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = CoachQuotaStore()

    /// nil until a Cloud turn has answered.
    private(set) var quota: CoachQuota?

    func update(_ quota: CoachQuota) { self.quota = quota }
}
