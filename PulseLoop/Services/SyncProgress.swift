import Foundation

/// The one sync-progress model (consistency framework, block A; AGENTS.md Rule 10). It turns the history day
/// loop's `SyncDayProgress` events into state every surface reads: the onboarding "Syncing" step (per-day rows
/// with live counts), the header bar (day N of M), and the sync notification while the app is in the
/// background. Mirrors Android's `SyncProgress`.
///
/// Fed from the event bus: `.decodedPacket(.historyDayProgress)` for days, `.syncProgress("done")` for the end,
/// and a disconnect for an interrupted pass. Cheap per event (the bus is shared; a slow collector delays all).
@MainActor
@Observable
final class SyncProgress {
    static let shared = SyncProgress()

    enum DayStatus: Equatable { case pending, syncing, done }

    struct DayRow: Identifiable, Equatable {
        /// Day offset: 0 = today, 1 = yesterday, …
        let day: Int
        let date: Date
        var status: DayStatus
        var counts: SyncDayCounts
        var id: Int { day }
    }

    /// A history pass is running.
    private(set) var isSyncing = false
    private(set) var totalDays = 0
    /// One row per day of the pass, today first.
    private(set) var rows: [DayRow] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Bumped per pass, so a view can tell passes apart.
    private(set) var passID = 0

    var daysDone: Int { rows.filter { $0.status == .done }.count }
    /// The day being read now (nil between days / when idle).
    var currentDay: Int? { rows.first { $0.status == .syncing }?.day }
    var fraction: Double { totalDays > 0 ? Double(daysDone) / Double(totalDays) : 0 }
    var totals: SyncDayCounts { rows.reduce(SyncDayCounts()) { $0 + $1.counts } }
    /// Remaining time from the average day so far (nil until a day finished).
    var eta: TimeInterval? {
        guard isSyncing, let startedAt, daysDone > 0 else { return nil }
        let perDay = now().timeIntervalSince(startedAt) / Double(daysDone)
        return perDay * Double(max(0, totalDays - daysDone))
    }

    var calendar = Calendar.current
    var now: () -> Date = Date.init
    let notifications: AgaraNotifications
    /// A progress notification went out for this pass (so the "synced" one may follow; routine top-ups stay quiet).
    private var notifiedThisPass = false
    private var task: Task<Void, Never>?

    init(notifications: AgaraNotifications? = nil) {
        self.notifications = notifications ?? .shared
        self.notifications.onBackgroundChange { [weak self] background in self?.appBackgroundChanged(background) }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            let stream = await AgaraEventBus.shared.stream()
            for await event in stream { self?.handle(event) }
        }
    }

    // MARK: Events

    func handle(_ event: AgaraEvent) {
        switch event {
        case let .decodedPacket(.historyDayProgress(progress)):
            apply(progress)
        case let .syncProgress(stage) where stage == "done":
            finish()
        case let .deviceStateChanged(state, _) where state != .connected:
            if isSyncing { interrupt() }
        default:
            break
        }
    }

    func apply(_ progress: SyncDayProgress) {
        if progress.counts == nil, progress.day == 0 || !isSyncing {
            beginPass(totalDays: progress.totalDays)
        }
        guard let index = rows.firstIndex(where: { $0.day == progress.day }) else { return }
        if let counts = progress.counts {
            rows[index].counts = counts
            rows[index].status = .done
            postProgressIfBackground()
        } else {
            rows[index].status = .syncing
        }
    }

    private func beginPass(totalDays: Int) {
        let today = calendar.startOfDay(for: now())
        self.totalDays = totalDays
        rows = (0..<max(0, totalDays)).map { day in
            DayRow(day: day, date: calendar.date(byAdding: .day, value: -day, to: today) ?? today,
                   status: .pending, counts: SyncDayCounts())
        }
        startedAt = now()
        finishedAt = nil
        isSyncing = true
        notifiedThisPass = false
        passID += 1
    }

    private func finish() {
        guard isSyncing else { return }
        isSyncing = false
        finishedAt = now()
        for i in rows.indices where rows[i].status != .done { rows[i].status = .done }
        if notifiedThisPass {
            let summary = Self.summary(totals, days: totalDays)
            Task { await notifications.post(.synced(summary)) }
        }
    }

    /// The link dropped mid-pass: keep what came down, stop claiming progress.
    private func interrupt() {
        isSyncing = false
        finishedAt = now()
        for i in rows.indices where rows[i].status == .syncing { rows[i].status = .pending }
        notifications.remove(ids: [AgaraNotification.syncId])
    }

    // MARK: Notifications (background only)

    /// "Day 3 of 8 · 4,210 steps · 812 heart-rate readings".
    var progressSummary: String {
        let day = min(totalDays, daysDone + (isSyncing ? 1 : 0))
        let counts = Self.countsText(totals)
        return counts.isEmpty ? "Day \(day) of \(totalDays)" : "Day \(day) of \(totalDays) · \(counts)"
    }

    private func postProgressIfBackground() {
        guard isSyncing, notifications.isAppInBackground else { return }
        notifiedThisPass = true
        Task { await notifications.post(.syncing(progressSummary)) }
    }

    private func appBackgroundChanged(_ background: Bool) {
        guard isSyncing else { return }
        if background {
            notifiedThisPass = true
            Task { await notifications.post(.syncing(progressSummary)) }
        } else {
            notifications.remove(ids: [AgaraNotification.syncId])
        }
    }

    // MARK: Copy

    static func countsText(_ c: SyncDayCounts) -> String {
        var parts: [String] = []
        if c.steps > 0 { parts.append("\(c.steps.formatted()) steps") }
        if c.heartRate > 0 { parts.append("\(c.heartRate.formatted()) heart-rate readings") }
        if c.sleepNights > 0 { parts.append(c.sleepNights == 1 ? "1 night of sleep" : "\(c.sleepNights) nights of sleep") }
        return parts.prefix(2).joined(separator: " · ")
    }

    static func summary(_ c: SyncDayCounts, days: Int) -> String {
        let counts = countsText(c)
        let span = days == 1 ? "1 day" : "\(days) days"
        return counts.isEmpty ? "\(span) of history are up to date." : "\(span) of history: \(counts)."
    }

    /// "Today", "Yesterday", then the weekday and date.
    func label(for row: DayRow) -> String {
        switch row.day {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return row.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}
