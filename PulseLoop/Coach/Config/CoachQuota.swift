import Foundation
import Observation

/// What the Coach UI needs from the cloud coach client — and nothing else. The client that speaks to
/// `{cloud_v2_base_url}{coach_path}` reads three things off every response (`docs/ring/coach-proxy.md` §9):
/// `X-Coach-Remaining-Day`, `X-Coach-Day-Resets-At`, and whether a turn is already open for this account.
///
/// The tab is written against this protocol only, so wiring the client in is mechanical: conform it here and hand it
/// to `CoachQuotaStore.attach(_:)`. Until it exists the store holds the last values it was given, which is also what
/// the UI test drives (`-coachQuotaRemaining`).
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
@MainActor
@Observable
final class CoachQuotaStore: CoachCloudStatusReading {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = CoachQuotaStore()

    /// The cloud client, once it exists (Agent B's transport work). Nil in a build without it, and in the shipped app
    /// while the on-device coach is the active provider — the pill then stays hidden.
    private weak var client: (any CoachCloudStatusReading)?

    /// The last values this store was handed, used whenever no client is attached.
    private(set) var lastRemainingTurnsToday: Int?
    private(set) var lastDayResetsAt: Date?
    private(set) var locallyBusy = false

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

    /// Hand the cloud client over once it exists; the store then reads the client and ignores its own copies.
    func attach(_ client: any CoachCloudStatusReading) { self.client = client }

    /// Record one response's quota headers — what the client calls after each round.
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
