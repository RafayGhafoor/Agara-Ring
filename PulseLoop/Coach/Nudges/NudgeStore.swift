import Foundation
import SwiftData

/// The user's nudge preferences. A value type so the policy stays a pure function; `NudgeSettingsRecord`
/// persists it as one row.
struct NudgeSettings: Equatable, Sendable, Codable {

    enum QuietMode: String, Codable, Sendable {
        case fixed
        case followSleep
    }

    /// Routine pushes allowed per day (1-3, default from the catalog).
    var dailyLimit: Int = AgaraConfig.Nudges.policyDailyLimit
    /// Celebrations (B4, E2, F1) get one push beyond the routine limit.
    var celebrationExtra: Bool = AgaraConfig.Nudges.policyCelebrationExtra == "on"
    var disabledTopics: Set<NudgeCategory> = []
    var quietMode: QuietMode = .fixed
    /// Minutes after local midnight. Defaults from the catalog; the user can change both bounds.
    var quietStart: Int = CoachSignals.minuteOfDay(AgaraConfig.Nudges.policyQuietStart) ?? 22 * 60
    var quietEnd: Int = CoachSignals.minuteOfDay(AgaraConfig.Nudges.policyQuietEnd) ?? 8 * 60
    /// `Calendar` weekday number, 1 = Sunday. Default from the catalog.
    var weeklyReviewWeekday: Int = NudgeSettings.weekday(AgaraConfig.Nudges.f2Weekday) ?? 1
    var weeklyReviewMinute: Int = CoachSignals.minuteOfDay(AgaraConfig.Nudges.f2Time) ?? 18 * 60
    var stepReminders: Bool = true

    static let standard = NudgeSettings()

    func topicEnabled(_ category: NudgeCategory) -> Bool {
        !disabledTopics.contains(category)
    }

    /// Quiet hours start: the fixed time, or the user's own median bedtime when following sleep.
    func quietStartMinute(signals: CoachSignals) -> Int {
        switch quietMode {
        case .fixed: return quietStart
        case .followSleep: return signals.baseline.nightsRecorded > 0 ? ((signals.baseline.bedMinute % 1440) + 1440) % 1440 : quietStart
        }
    }

    func quietEndMinute(signals: CoachSignals) -> Int {
        switch quietMode {
        case .fixed: return quietEnd
        case .followSleep: return signals.baseline.nightsRecorded > 0 ? ((signals.baseline.wakeMinute % 1440) + 1440) % 1440 : quietEnd
        }
    }

    /// True when `minuteOfDay` falls inside quiet hours, including a window that wraps midnight.
    func isQuiet(minuteOfDay: Int, signals: CoachSignals) -> Bool {
        let start = quietStartMinute(signals: signals)
        let end = quietEndMinute(signals: signals)
        if start == end { return false }
        if start < end { return minuteOfDay >= start && minuteOfDay < end }
        return minuteOfDay >= start || minuteOfDay < end
    }

    static func weekday(_ name: String) -> Int? {
        switch name.lowercased() {
        case "sunday": return 1
        case "monday": return 2
        case "tuesday": return 3
        case "wednesday": return 4
        case "thursday": return 5
        case "friday": return 6
        case "saturday": return 7
        default: return nil
        }
    }
}

/// What has already been shown, tapped or dismissed. The value the policy reads (`NudgeLedger`) is built from
/// `NudgeLedgerEntry` rows, so the policy itself never opens a store.
struct NudgeLedger: Equatable, Sendable {

    struct Sent: Equatable, Sendable {
        var rule: NudgeRule
        var category: NudgeCategory
        var at: Date
        var fingerprint: String
        var delivery: NudgeDelivery
        var severity: Double
        var templateID: String
    }

    struct Dismissal: Equatable, Sendable {
        var category: NudgeCategory
        var at: Date
    }

    var sent: [Sent] = []
    /// "Not now" and pushes nobody tapped inside `policyUntappedHours` (counted when the ledger is built).
    var dismissed: [Dismissal] = []
    /// "Not now" pauses a category until the user's next wake time.
    var snoozedUntil: [NudgeCategory: Date] = [:]
    /// Routine pushes already spent today. Normally derived from `sent`; kept separately so a caller (or a policy
    /// case) can state the budget without inventing delivery rows that would also trip the 6-hour gap.
    var routinePushesToday: Int = 0
    /// The OS notification permission (or the user's master switch). False = no push at all, but the nudge still
    /// appears as a Today card and in the "For you" list (policy rule 10) — the card is the product, the push is the
    /// interruption.
    var notificationsEnabled: Bool = true
    /// E2's cooldown is per metric, not per category: the last time each metric was celebrated (`steps`, `sleep`,
    /// `active_minutes`). The category gap cannot express "steps was celebrated nine days ago" (catalog rule 1/E2).
    var metricCelebrated: [String: Date] = [:]
    /// Template id → last time it was shown, for the 7-day rotation.
    var templateLastUsed: [String: Date] = [:]

    func sentToday(_ now: Date, calendar: Calendar = .current) -> [Sent] {
        sent.filter { calendar.isDate($0.at, inSameDayAs: now) }
    }

    func sentToday(rule: NudgeRule, now: Date, calendar: Calendar = .current) -> [Sent] {
        sentToday(now, calendar: calendar).filter { $0.rule == rule }
    }

    func fingerprints(on day: Date, calendar: Calendar = .current) -> Set<String> {
        Set(sentToday(day, calendar: calendar).map(\.fingerprint))
    }

    func lastSent(category: NudgeCategory) -> Sent? {
        sent.filter { $0.category == category }.max { $0.at < $1.at }
    }

    func dismissals(in category: NudgeCategory, since: Date) -> Int {
        dismissed.filter { $0.category == category && $0.at >= since }.count
    }

    /// Build the ledger the policy reads from the delivery rows (`NudgeLedgerStore`). This is the only place the two
    /// meet: the policy stays a pure function of this value, and the store stays free of policy.
    static func build(
        entries: [NudgeLedgerEntry],
        snoozes: [NudgeCategory: Date],
        now: Date,
        calendar: Calendar = .current
    ) -> NudgeLedger {
        var ledger = NudgeLedger()
        ledger.sent = entries.compactMap { entry in
            guard let rule = NudgeRule(rawValue: entry.rule) else { return nil }
            return Sent(
                rule: rule,
                category: entry.category,
                at: entry.date,
                fingerprint: entry.nudgeId,
                delivery: .push,
                severity: 0,
                templateID: entry.templateID
            )
        }
        // A dismissal is a "Not now" or a push nobody tapped inside the untapped window (NudgeOutcome knows which).
        ledger.dismissed = entries.filter(\.isDismissal).map {
            Dismissal(category: $0.category, at: $0.date)
        }
        ledger.snoozedUntil = snoozes
        for sent in ledger.sent where !sent.templateID.isEmpty {
            if let existing = ledger.templateLastUsed[sent.templateID], existing > sent.at { continue }
            ledger.templateLastUsed[sent.templateID] = sent.at
        }
        // Routine pushes already spent today: celebrations draw on their own budget (policy rule 1).
        ledger.routinePushesToday = entries.filter {
            calendar.isDate($0.date, inSameDayAs: now) && !$0.category.isCelebration && $0.outcome == .shown
        }.count
        return ledger
    }
}

// MARK: - Persistence
