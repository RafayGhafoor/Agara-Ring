import Foundation
import SwiftUI
import Observation

/// Settings › Notifications (spec §3) — the user's side of the anti-nagging policy. Every value here is read by the
/// delivery pass, never written by the engine: the engine stays a pure function of the store and `now`, so a test can
/// pin both and get the same answer twice.
@MainActor
@Observable
final class NudgePreferencesStore {
    static let shared = NudgePreferencesStore()

    private enum Key {
        static let master = "agara.nudge.master"
        static let dailyLimit = "agara.nudge.dailyLimit"
        static let celebrations = "agara.nudge.celebrationsExtra"
        static let topic = "agara.nudge.topic."
        static let weeklyWeekday = "agara.nudge.weekly.weekday"
        static let weeklyHour = "agara.nudge.weekly.hour"
        static let followSleep = "agara.nudge.quiet.followSleep"
        static let quietStart = "agara.nudge.quiet.start"
        static let quietEnd = "agara.nudge.quiet.end"
        static let stepReminder = "agara.nudge.stepReminder"
    }

    private let defaults: UserDefaults
    /// Bumped on every write so `@Observable` views re-read the stored values (`UserDefaults` is not observable).
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func write(_ run: () -> Void) {
        run()
        revision += 1
    }

    // MARK: Master and pacing

    /// Rule 10 of the policy: with notifications off every nudge still appears as a Today card and in the Coach tab's
    /// "For you" list, so this switch only silences the pushes.
    var masterOn: Bool {
        get { defaults.object(forKey: Key.master) as? Bool ?? true }
        set { write { defaults.set(newValue, forKey: Key.master) } }
    }

    /// Pushes per day before the celebration slot (1–3, default `policyDailyLimit`).
    var dailyLimit: Int {
        get {
            let stored = defaults.object(forKey: Key.dailyLimit) as? Int ?? AgaraConfig.Nudges.policyDailyLimit
            return min(max(stored, AgaraConfig.Nudges.policyDailyLimitMin),
                       AgaraConfig.Nudges.policyDailyLimitMax)
        }
        set {
            write {
                defaults.set(min(max(newValue, AgaraConfig.Nudges.policyDailyLimitMin),
                                  AgaraConfig.Nudges.policyDailyLimitMax), forKey: Key.dailyLimit)
            }
        }
    }

    /// One extra push for a celebration (B4, E2, F1) on top of `dailyLimit`.
    var celebrationsExtra: Bool {
        get { defaults.object(forKey: Key.celebrations) as? Bool ?? (AgaraConfig.Nudges.policyCelebrationExtra == "on") }
        set { write { defaults.set(newValue, forKey: Key.celebrations) } }
    }

    // MARK: Per-topic toggles

    func isOn(_ topic: NudgeTopic) -> Bool {
        switch topic {
        case .celebrations: return celebrationsExtra
        default: return defaults.object(forKey: Key.topic + topic.rawValue) as? Bool ?? true
        }
    }

    func set(_ topic: NudgeTopic, on: Bool) {
        switch topic {
        case .celebrations: celebrationsExtra = on
        default: write { defaults.set(on, forKey: Key.topic + topic.rawValue) }
        }
    }

    // MARK: Weekly review day + time

    /// 1 = Sunday … 7 = Saturday (the `Calendar` weekday numbering), default from `f2Weekday`/`f2Time`.
    var weeklyWeekday: Int {
        get {
            let stored = defaults.object(forKey: Key.weeklyWeekday) as? Int
            return stored ?? NudgePreferencesStore.weekday(from: AgaraConfig.Nudges.f2Weekday)
        }
        set { write { defaults.set(newValue, forKey: Key.weeklyWeekday) } }
    }

    var weeklyHour: Int {
        get {
            let stored = defaults.object(forKey: Key.weeklyHour) as? Int
            return stored ?? (Int(AgaraConfig.Nudges.f2Time.prefix(2)) ?? 18)
        }
        set { write { defaults.set(newValue, forKey: Key.weeklyHour) } }
    }

    // MARK: Quiet hours

    /// "Follow my sleep": the quiet window is the user's own sleep window instead of fixed from/to times.
    var quietHoursFollowSleep: Bool {
        get { defaults.object(forKey: Key.followSleep) as? Bool ?? false }
        set { write { defaults.set(newValue, forKey: Key.followSleep) } }
    }

    /// Minutes after midnight, so the window can wrap past midnight.
    var quietStartMinutes: Int {
        get { (defaults.object(forKey: Key.quietStart) as? Int) ?? Self.minutes(AgaraConfig.Nudges.policyQuietStart) }
        set { write { defaults.set(newValue, forKey: Key.quietStart) } }
    }

    var quietEndMinutes: Int {
        get { (defaults.object(forKey: Key.quietEnd) as? Int) ?? Self.minutes(AgaraConfig.Nudges.policyQuietEnd) }
        set { write { defaults.set(newValue, forKey: Key.quietEnd) } }
    }

    // MARK: Step reminders (B3's cadence)

    /// How often "been still" may speak up: off, every 2 h or every 3 h. `nil` = off.
    var stepReminderHours: Int? {
        get {
            let stored = defaults.object(forKey: Key.stepReminder) as? Int ?? 3
            return stored == 0 ? nil : stored
        }
        set { write { defaults.set(newValue ?? 0, forKey: Key.stepReminder) } }
    }

    // MARK: Helpers

    static func minutes(_ hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":")
        let hour = parts.first.flatMap { Int($0) } ?? 0
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return hour * 60 + minute
    }

    static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func weekday(from name: String) -> Int {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return (names.firstIndex(of: name.lowercased()) ?? 0) + 1
    }

    static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[min(max(weekday - 1, 0), 6)]
    }
}

// MARK: - The ledger

/// What happened to each nudge, for the two things the user can see: the "last 7 days" list in Settings › Notifications
/// › Tools and the dismissal-learning rule (3 dismissals in 7 days double the category's gap). Stored in
/// `UserDefaults` — it is a few hundred bytes of delivery bookkeeping, not health data, so it does not belong in the
/// SwiftData store the engine reads.
struct NudgeLedgerEntry: Codable, Identifiable, Equatable {
    let id: String
    let nudgeId: String
    let rule: String
    let category: NudgeCategory
    let title: String
    let date: Date
    var outcome: NudgeOutcome
    /// Which wording variant was shown. The 7-day rotation reads it; optional so rows written before it existed still
    /// decode (an unknown template simply never blocks a variant).
    var templateID: String = ""

    var isDismissal: Bool { outcome == .notNow || outcome == .untapped }
}

/// One spelling per button, plus the two states only the ledger can see.
enum NudgeOutcome: String, Codable, CaseIterable {
    case shown, tapped, whyOpened, keptGoal, madeLighter, notNow, breathed, openedRing, untapped

    var label: String {
        switch self {
        case .shown: "Shown"
        case .tapped: "Tapped"
        case .whyOpened: "Opened the coach"
        case .keptGoal: "Kept the goal"
        case .madeLighter: "Made today lighter"
        case .notNow: "Not now"
        case .breathed: "Did a breathing session"
        case .openedRing: "Opened the ring screen"
        case .untapped: "No tap within 4 h"
        }
    }

    /// Any tap or action resets the learning tolerance for that category (policy rule 9).
    var resetsLearning: Bool {
        switch self {
        case .whyOpened, .keptGoal, .madeLighter, .breathed, .openedRing, .tapped: true
        default: false
        }
    }
}

@MainActor
@Observable
final class NudgeLedgerStore {
    static let shared = NudgeLedgerStore()

    private enum Key {
        static let entries = "agara.nudge.ledger"
        static let snoozes = "agara.nudge.snoozes"
    }

    private let defaults: UserDefaults
    private(set) var revision = 0
    private var cached: [NudgeLedgerEntry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cached = Self.decode([NudgeLedgerEntry].self, from: defaults.data(forKey: Key.entries)) ?? []
        #if DEBUG
        // `-nudgeFixtureReset YES`: start each UI-test launch with an empty ledger and no snoozes. The tests always
        // passed it, but nothing read it — harmless until the fixture honoured "Not now", after which one test's
        // snooze hid the next test's card. Here, in the shared store's one-time init, it runs once per launch.
        if defaults === UserDefaults.standard, DebugLaunch.bool("nudgeFixtureReset") {
            cached = []
            defaults.removeObject(forKey: Key.entries)
            defaults.removeObject(forKey: Key.snoozes)
        }
        #endif
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // A 30-day window is all the ledger ever needs to answer for; older rows would only make the Tools list long.
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        cached = cached.filter { $0.date >= cutoff }
        defaults.set(try? encoder.encode(cached), forKey: Key.entries)
        revision += 1
    }

    // MARK: Entries

    var entries: [NudgeLedgerEntry] { cached }

    /// Newest first, for the Settings read-out.
    func recent(days: Int = 7, now: Date = Date()) -> [NudgeLedgerEntry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return cached.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
    }

    /// Record that a nudge was shown (once per nudge id) and then what the user did with it.
    @discardableResult
    func record(_ nudge: CoachNudge, outcome: NudgeOutcome, now: Date = Date()) -> NudgeLedgerEntry {
        if let index = cached.firstIndex(where: { $0.nudgeId == nudge.id }) {
            cached[index].outcome = outcome
            cached[index] = NudgeLedgerEntry(id: cached[index].id, nudgeId: nudge.id, rule: nudge.ruleID,
                                             category: nudge.category, title: nudge.title,
                                             date: cached[index].date, outcome: outcome)
            persist()
            return cached[index]
        }
        let entry = NudgeLedgerEntry(id: UUID().uuidString, nudgeId: nudge.id, rule: nudge.ruleID,
                                     category: nudge.category, title: nudge.title, date: now, outcome: outcome)
        cached.append(entry)
        persist()
        return entry
    }

    func outcome(for nudgeId: String) -> NudgeOutcome? {
        cached.first { $0.nudgeId == nudgeId }?.outcome
    }

    /// Dismissals for one category inside the learning window — the number `policyDismissalsToDouble` doubles on.
    func dismissals(in category: NudgeCategory, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(AgaraConfig.Nudges.policyDismissalWindowDays) * 86_400)
        return cached.filter { $0.category == category && $0.isDismissal && $0.date >= cutoff }.count
    }

    // MARK: Snoozes ("Not now" pauses the category until the next wake time)

    /// Category → the moment the pause ends. Kept separate from the entries so "Clear snoozes" in Tools cannot rewrite
    /// history.
    var snoozes: [NudgeCategory: Date] {
        let raw = defaults.dictionary(forKey: Key.snoozes) as? [String: Double] ?? [:]
        return raw.reduce(into: [:]) { result, pair in
            if let category = NudgeCategory(rawValue: pair.key) {
                result[category] = Date(timeIntervalSince1970: pair.value)
            }
        }
    }

    /// The pause ends at the user's next wake time; delivery passes it in so this store owns no clock arithmetic.
    func snooze(_ category: NudgeCategory, until: Date) {
        var raw = defaults.dictionary(forKey: Key.snoozes) as? [String: Double] ?? [:]
        raw[category.rawValue] = max(until.timeIntervalSince1970, Date().timeIntervalSince1970)
        defaults.set(raw, forKey: Key.snoozes)
        revision += 1
    }

    func isSnoozed(_ category: NudgeCategory, now: Date = Date()) -> Bool {
        guard let until = snoozes[category] else { return false }
        return until > now
    }

    /// Debug fixtures only: forget every entry and snooze, so each UI test starts from the same clean slate.
    func resetAll() {
        cached = []
        defaults.removeObject(forKey: Key.entries)
        defaults.removeObject(forKey: Key.snoozes)
        revision += 1
    }

    func clearSnoozes() {
        defaults.removeObject(forKey: Key.snoozes)
        revision += 1
    }

    // MARK: Day helpers

    /// The local-day key every "once a day" rule and the goal override share.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Lighter today

/// "Lighter today" lowers *today's* step goal by 10% or 20% and expires at midnight; the user's stored goal is never
/// touched (spec §5). A day key rather than a timer, so killing the app or crossing midnight in the background both
/// behave: an override from another day simply is not active.
struct DailyGoalOverride: Equatable {
    let percent: Int
    let dayKey: String

    /// 10 or 20 — the two choices the confirmation offers.
    static let percents = [10, 20]

    static func goal(_ goal: Int, percent: Int) -> Int {
        max(1, Int((Double(goal) * Double(100 - percent) / 100).rounded()))
    }
}

@MainActor
@Observable
final class DailyGoalOverrideStore {
    static let shared = DailyGoalOverrideStore()

    private enum Key {
        static let percent = "agara.nudge.goalOverride.percent"
        static let day = "agara.nudge.goalOverride.day"
    }

    private let defaults: UserDefaults
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // `-nudgeFixtureReset YES` also clears today's "Lighter today" override: one test's confirmation otherwise
        // showed "Today's step goal is 9,000 — 10% lighter" on every later launch of the day.
        if defaults === UserDefaults.standard, DebugLaunch.bool("nudgeFixtureReset") {
            defaults.removeObject(forKey: Key.percent)
            defaults.removeObject(forKey: Key.day)
        }
        #endif
    }

    /// The override in force right now, or nil (none set, or it expired at midnight).
    func active(now: Date = Date()) -> DailyGoalOverride? {
        guard let day = defaults.string(forKey: Key.day),
              let percent = defaults.object(forKey: Key.percent) as? Int,
              day == NudgeLedgerStore.dayKey(now) else { return nil }
        return DailyGoalOverride(percent: percent, dayKey: day)
    }

    func set(percent: Int, now: Date = Date()) {
        defaults.set(percent, forKey: Key.percent)
        defaults.set(NudgeLedgerStore.dayKey(now), forKey: Key.day)
        revision += 1
    }

    func clear() {
        defaults.removeObject(forKey: Key.percent)
        defaults.removeObject(forKey: Key.day)
        revision += 1
    }

    /// The step goal the Today screen should show: the user's goal, lowered for today if an override is active.
    func effectiveGoal(_ goal: Int, now: Date = Date()) -> Int {
        active(now: now).map { DailyGoalOverride.goal(goal, percent: $0.percent) } ?? goal
    }
}
