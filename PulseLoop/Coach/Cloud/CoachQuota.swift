import Foundation
import Observation

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
        headers.first { $0.key.caseInsensitiveOrder(name) }?.value
    }
}

private extension String {
    /// `caseInsensitiveCompare(_:) == .orderedSame`, spelled so the call site reads as one question.
    func caseInsensitiveOrder(_ other: String) -> Bool { caseInsensitiveCompare(other) == .orderedSame }
}

/// What the Coach UI needs from the cloud coach client — and nothing else. The client that speaks to
/// `{cloud_v2_base_url}{coach_path}` reads three things off every response (`docs/ring/coach-proxy.md` §9):
/// `X-Coach-Remaining-Day`, `X-Coach-Day-Resets-At`, and whether a turn is already open for this account.
///
/// The tab is written against this protocol only, so wiring the client in is mechanical: conform it and hand it to
/// `CoachQuotaStore.attach(_:)`. Until then the store holds the last values it was given, which is also what the UI
/// test drives (`-coachQuotaRemaining`).
@MainActor
protocol CoachCloudStatusReading: AnyObject {
    /// Cloud questions left today, from `X-Coach-Remaining-Day`; nil before the first response of the day.
    var remainingTurnsToday: Int? { get }
    /// When today's quota resets, from `X-Coach-Day-Resets-At`; nil when the server did not send it.
    var dayResetsAt: Date? { get }
    /// A turn is in flight for this account (`409 coach_busy` while it runs).
    var isTurnInFlight: Bool { get }
}

/// The one place the Coach tab reads cloud quota and busy-ness from. Observable, so the header's "24 left today" pill
/// and the out-of-quota card follow the headers of the last response without any other plumbing.
///
/// A `ResponsesClient` is built per turn and thrown away, so the headers cannot live on the client: the client calls
/// `update(_:)` after each round and the UI reads this store.
@MainActor
@Observable
final class CoachQuotaStore: CoachCloudStatusReading {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = CoachQuotaStore()

    /// The cloud client, once it exists, if it reports its own busy/remaining state. Nil otherwise.
    private weak var client: (any CoachCloudStatusReading)?

    /// The last values this store was handed, used whenever no client is attached.
    private(set) var lastRemainingTurnsToday: Int?
    private(set) var lastDayResetsAt: Date?
    private(set) var locallyBusy = false
    /// The last full quota value (day, minute, month, reset) — what the pill and the tests read.
    private(set) var quota: CoachQuota?

    init(remainingTurnsToday: Int? = nil, dayResetsAt: Date? = nil, busy: Bool = false) {
        self.lastRemainingTurnsToday = remainingTurnsToday
        self.lastDayResetsAt = dayResetsAt
        self.locallyBusy = busy
        #if DEBUG
        // Test tooling (`-coachQuotaRemaining 24 -coachQuotaResetsAt <ISO> -coachBusy YES`): the quota only arrives with
        // a cloud response, so the UI test needs a way to stand in for one. Debug builds only, like every launch hook.
        if DebugLaunch.isSet("coachQuotaRemaining") {
            self.lastRemainingTurnsToday = DebugLaunch.integer("coachQuotaRemaining")
        }
        if let iso = DebugLaunch.string("coachQuotaResetsAt"), let date = ISO8601DateFormatter().date(from: iso) {
            self.lastDayResetsAt = date
        }
        if DebugLaunch.bool("coachBusy") { self.locallyBusy = true }
        #endif
    }

    var remainingTurnsToday: Int? { client?.remainingTurnsToday ?? lastRemainingTurnsToday }
    var dayResetsAt: Date? { client?.dayResetsAt ?? lastDayResetsAt }
    var isTurnInFlight: Bool { client?.isTurnInFlight ?? locallyBusy }

    /// True while the pill has something to say (the first response of the day has arrived, or a test set a value).
    var hasQuota: Bool { remainingTurnsToday != nil }

    /// Hand the cloud client over; the store then reads the client and ignores its own copies.
    func attach(_ client: any CoachCloudStatusReading) { self.client = client }

    /// Record one response's quota headers — what the proxy client calls after each round.
    func update(_ quota: CoachQuota) {
        self.quota = quota
        record(remainingTurnsToday: quota.remainingDay, dayResetsAt: quota.dayResetsAt)
    }

    /// Record the two values the UI needs when only those are known.
    func record(remainingTurnsToday: Int?, dayResetsAt: Date?) {
        lastRemainingTurnsToday = remainingTurnsToday
        lastDayResetsAt = dayResetsAt
    }

    /// Mark a turn as running (the composer disables and, after a `409`, the tab shows the busy card).
    func setTurnInFlight(_ busy: Bool) { locallyBusy = busy }

    /// Forget the quota (sign-out, account change, "Delete all my data").
    func reset() {
        lastRemainingTurnsToday = nil
        lastDayResetsAt = nil
        locallyBusy = false
        quota = nil
    }

    // MARK: - Presentation

    /// "24 left today" — the header pill's text (nil when nothing has been reported yet).
    var pillText: String? {
        remainingTurnsToday.map(CoachCopy.quotaPill(remaining:))
    }

    /// The pill's VoiceOver label, naming the reset when known.
    var pillSpokenText: String? {
        remainingTurnsToday.map { CoachCopy.quotaPillSpoken(remaining: $0, resets: resetsText) }
    }

    /// "21 Oct at 00:00" in the user's locale, or nil when the server has not said.
    var resetsText: String? {
        dayResetsAt.map(Self.resetFormatter.string(from:))
    }

    /// Out of quota: the state card's sentence. Withdrawing to the on-device coach is always the offer, so the copy
    /// says so even when the reset time is unknown.
    var quotaBody: String {
        if let resetsText { return CoachCopy.quotaResets(at: resetsText) }
        return CoachCopy.quotaUnknownReset
    }

    /// Date and time, minutes included: the day boundary is midnight, and "00:00" is what the user is waiting for.
    static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
