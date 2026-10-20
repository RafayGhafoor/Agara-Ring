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

    /// Build the ledger the policy reads from the persisted rows.
    static func build(
        entries: [NudgeLedgerEntry],
        dismissals: [NudgeLedgerDismissal],
        snoozes: [NudgeCategory: Date],
        now: Date,
        calendar: Calendar = .current
    ) -> NudgeLedger {
        var ledger = NudgeLedger()
        ledger.sent = entries.compactMap { entry in
            guard let rule = NudgeRule(rawValue: entry.ruleRaw),
                  let category = NudgeCategory(rawValue: entry.categoryRaw),
                  let delivery = NudgeDelivery(rawValue: entry.deliveryRaw)
            else { return nil }
            return Sent(
                rule: rule,
                category: category,
                at: entry.sentAt,
                fingerprint: entry.fingerprint,
                delivery: delivery,
                severity: entry.severity,
                templateID: entry.templateID
            )
        }
        ledger.dismissed = dismissals.map {
            Dismissal(category: NudgeCategory(rawValue: $0.categoryRaw) ?? .insight, at: $0.dismissedAt)
        }
        ledger.snoozedUntil = snoozes
        for sent in ledger.sent {
            if let existing = ledger.templateLastUsed[sent.templateID], existing > sent.at { continue }
            ledger.templateLastUsed[sent.templateID] = sent.at
        }
        // A push that was never tapped inside the untapped window counts as a dismissal for the learning rule.
        let untapped = TimeInterval(AgaraConfig.Nudges.policyUntappedHours) * 3600
        for sent in ledger.sent where sent.delivery == .push {
            guard now.timeIntervalSince(sent.at) >= untapped else { continue }
            let tapped = dismissals.contains { $0.sentAt == sent.at }
            if !tapped { ledger.dismissed.append(Dismissal(category: sent.category, at: sent.at.addingTimeInterval(untapped))) }
        }
        return ledger
    }
}

// MARK: - Persistence

/// Delivery history for the deterministic nudges. Supersedes `CoachNotificationRecord` for nudge history: that row
/// keeps the coach's own check-in slots, this one records what the rule engine decided, for the daily limit, the
/// fingerprint, the 6-hour gap, the learning ladder and the 7-day wording rotation.
@Model
final class NudgeLedgerEntry {
    @Attribute(.unique) var id: UUID
    var ruleRaw: String
    var categoryRaw: String
    var deliveryRaw: String
    var fingerprint: String
    var severity: Double
    var templateID: String
    var sentAt: Date
    var title: String
    var body: String
    /// When the user tapped the nudge (opened the Coach tab). Any tap resets the learning ladder.
    var tappedAt: Date?

    init(
        id: UUID = UUID(),
        rule: NudgeRule,
        category: NudgeCategory,
        delivery: NudgeDelivery,
        fingerprint: String,
        severity: Double,
        templateID: String,
        sentAt: Date = AppClock.now,
        title: String,
        body: String,
        tappedAt: Date? = nil
    ) {
        self.id = id
        self.ruleRaw = rule.rawValue
        self.categoryRaw = category.rawValue
        self.deliveryRaw = delivery.rawValue
        self.fingerprint = fingerprint
        self.severity = severity
        self.templateID = templateID
        self.sentAt = sentAt
        self.title = title
        self.body = body
        self.tappedAt = tappedAt
    }
}

/// An explicit "Not now" (as opposed to a push that was simply not tapped).
@Model
final class NudgeLedgerDismissal {
    @Attribute(.unique) var id: UUID
    var categoryRaw: String
    var dismissedAt: Date
    var sentAt: Date?

    init(id: UUID = UUID(), category: NudgeCategory, dismissedAt: Date = AppClock.now, sentAt: Date? = nil) {
        self.id = id
        self.categoryRaw = category.rawValue
        self.dismissedAt = dismissedAt
        self.sentAt = sentAt
    }
}

/// The user's "make today lighter" choice: a lower step goal for one day only. The normal goal is never changed —
/// the row expires at midnight and the goal comes back by itself.
@Model
final class DailyGoalOverride {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// Percent the step goal is lowered by for that day (10 or 20).
    var percentLower: Int
    var expiresAt: Date

    init(id: UUID = UUID(), date: Date, percentLower: Int, expiresAt: Date) {
        self.id = id
        self.date = date
        self.percentLower = percentLower
        self.expiresAt = expiresAt
    }

    static func lowerPercent(context: ModelContext, on date: Date, calendar: Calendar = .current) -> Int? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let predicate = #Predicate<DailyGoalOverride> { $0.date >= start && $0.date < end && $0.expiresAt > date }
        return ((try? context.fetch(FetchDescriptor<DailyGoalOverride>(predicate: predicate))) ?? []).first?.percentLower
    }
}

/// One row holding the user's nudge preferences as JSON, so `NudgeSettings` can stay a pure value.
@Model
final class NudgeSettingsRecord {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var updatedAt: Date

    init(id: UUID = UUID(), settings: NudgeSettings = .standard, updatedAt: Date = AppClock.now) {
        self.id = id
        self.payload = (try? JSONEncoder().encode(settings)) ?? Data()
        self.updatedAt = updatedAt
    }

    var settings: NudgeSettings {
        (try? JSONDecoder().decode(NudgeSettings.self, from: payload)) ?? .standard
    }
}
