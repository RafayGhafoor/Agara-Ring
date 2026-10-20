import Foundation
import SwiftData

/// The seam between the deterministic rule engine (N1: `PulseLoop/Coach/Nudges/` rules, signals, median baselines and
/// the anti-nagging policy) and everything that *shows* a nudge (this delivery layer: cards, pushes, the Coach seed,
/// breathing, the lighter-today override and Settings).
///
/// The engine is a pure function of the store plus `now`; it never posts a notification, never renders copy and never
/// touches a clock of its own. Delivery reads `pending` once per screen/push pass and owns every side effect.
@MainActor
protocol NudgeProviding {
    /// The nudges that survive the policy right now, most important first (priority order:
    /// recovery → stress → goal → activity → celebration → insight). Empty means "nothing to say" — thin data, quiet
    /// hours, the daily limit, a snooze and the learning-baseline rule all end here, as silence rather than an excuse.
    func pending(now: Date, context: ModelContext) -> [CoachNudge]
}

/// Baseline state, so Today can say "Learning your baseline" (`AgaraCopy.nudgeLearningBaseline`) instead of an empty
/// list that looks broken, and Settings can explain why nothing arrives.
@MainActor
protocol NudgeStatusProviding {
    /// 28-day median over at least `AgaraConfig.Nudges.baselineMinNights` nights; until then every recovery rule
    /// stays silent.
    func status(now: Date, context: ModelContext) -> NudgeStatus
}

struct NudgeStatus: Equatable {
    var learningBaseline: Bool
    var nightsRecorded: Int

    /// Enough data: no "learning" card, recovery rules allowed.
    static let ready = NudgeStatus(learningBaseline: false, nightsRecorded: AgaraConfig.Nudges.baselineMinNights)
}

/// The six policy lanes (`AgaraConfig.Nudges.policyPriorityOrder`). The priority order and the 6-hour cooldown are
/// per category, so the category — not the rule id — is what the policy, the settings toggles and the notification
/// actions key on.
enum NudgeCategory: String, CaseIterable, Codable, Identifiable {
    case recovery, stress, goal, activity, celebration, insight

    var id: String { rawValue }

    /// Position in `policyPriorityOrder` — lower wins when two nudges compete for the same push slot.
    var priority: Int {
        switch self {
        case .recovery: 0
        case .stress: 1
        case .goal: 2
        case .activity: 3
        case .celebration: 4
        case .insight: 5
        }
    }

    /// The notification category a push for this lane is posted under (`AgaraNotificationCategory.coach*`).
    var notificationCategory: AgaraNotificationCategory {
        switch self {
        case .recovery: .coachRecovery
        case .stress: .coachStress
        default: .coachGeneric
        }
    }

    /// The lane a rule id belongs to. The 13 ids are fixed by the approved spec, so a push payload that only knows its
    /// rule (a notification callback) can still pick the right category.
    static func category(forRule rule: String) -> NudgeCategory {
        switch rule {
        case "a1", "a2", "a3": .recovery
        case "c1": .stress
        case "b1", "b2", "b3", "b4": .activity
        case "e1", "f2", "g1": .insight
        case "e2", "f1": .celebration
        default: .insight
        }
    }
}

/// The user-facing group a nudge belongs to — one Settings toggle each (spec §3). Finer than `NudgeCategory` because
/// "Patterns" (sleep drift, missing ring data) and "Weekly review" are both insights, and celebrations are their own
/// optional extra.
enum NudgeTopic: String, CaseIterable, Codable, Identifiable {
    case recoverySleep, stress, activityGoals, patterns, weeklyReview, celebrations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recoverySleep: "Recovery & sleep"
        case .stress: "Stress"
        case .activityGoals: "Activity & goals"
        case .patterns: "Patterns"
        case .weeklyReview: "Weekly review"
        case .celebrations: "Celebrations"
        }
    }

    /// The rule ids are part of the approved spec (a1…g1), so mapping a rule to the toggle that mutes it belongs to the
    /// delivery side and stays stable even as the engine changes its wording.
    static func topic(forRule rule: String, category: NudgeCategory) -> NudgeTopic {
        switch rule {
        case "a1", "a2", "a3": .recoverySleep
        case "c1": .stress
        case "b1", "b2", "b3", "b4": .activityGoals
        case "e1", "g1": .patterns
        case "f2": .weeklyReview
        case "e2", "f1": .celebrations
        default:
            switch category {
            case .recovery: .recoverySleep
            case .stress: .stress
            case .goal, .activity: .activityGoals
            case .insight: .patterns
            case .celebration: .celebrations
            }
        }
    }
}

/// A button on a nudge. One spelling per action across the card, the push and the tests: the raw value is the
/// accessibility id suffix (`nudge.action.lighterToday`), the notification action identifier
/// (`agara.nudge.lighterToday`) and the ledger outcome key.
enum NudgeAction: String, CaseIterable, Codable, Identifiable {
    case keepGoal, lighterToday, why, notNow, breathe, openRing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepGoal: AgaraCopy.nudgeButtonKeepGoal
        case .lighterToday: AgaraCopy.nudgeButtonLighterToday
        case .why: AgaraCopy.nudgeButtonWhy
        case .notNow: AgaraCopy.nudgeButtonNotNow
        case .breathe: AgaraCopy.nudgeButtonBreathe
        case .openRing: AgaraCopy.nudgeButtonOpenRing
        }
    }

    /// `UNNotificationAction` identifier, registered once in `AgaraNotifications.start()`.
    var notificationIdentifier: String { "agara.nudge.\(rawValue)" }

    /// "Not now" is the dismissal the learning rule counts (3 in 7 days doubles the gap).
    var countsAsDismissal: Bool { self == .notNow }
}

/// One number the nudge is based on, already formatted for the user's locale and unit system by the engine's
/// `NudgeTemplate` renderer. Delivery shows it verbatim — it never re-formats, so the card and the push agree.
struct NudgeFact: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

/// Everything behind a nudge that the Coach answer needs: the numbers, the chart, and the honest "no data yet" flag.
/// `chart` is a `CoachChart` (the shape `prepare_chart` produces), so the seeded answer and the chat answer render the
/// same spec through the one chart component (`CoachChartView` → `AgaraChart`).
struct NudgeEvidence: Equatable {
    var facts: [NudgeFact]
    var chart: CoachChart?
    var learningBaseline: Bool

    init(facts: [NudgeFact] = [], chart: CoachChart? = nil, learningBaseline: Bool = false) {
        self.facts = facts
        self.chart = chart
        self.learningBaseline = learningBaseline
    }

    static let none = NudgeEvidence()
}

/// One ready-to-render nudge. Copy arrives rendered (slots filled, plurals and units done); delivery only decides
/// placement, buttons' effects and pacing.
struct CoachNudge: Identifiable, Equatable {
    let id: String
    let rule: String
    let category: NudgeCategory
    let title: String
    let body: String
    let buttons: [NudgeAction]
    let evidence: NudgeEvidence
    /// The `nudge_<rule>_seed` template rendered with the same numbers: the message the Coach tab opens with when the
    /// card (or "Why?") is tapped. Written by the engine, never sent to a model by itself.
    let seedMessage: String

    var topic: NudgeTopic { NudgeTopic.topic(forRule: rule, category: category) }
    var isCelebration: Bool { category == .celebration }

    /// Stable accessibility identifiers so the UI tests can find a card and its buttons without matching copy.
    var cardIdentifier: String { "nudge.card.\(rule)" }
    func actionIdentifier(_ action: NudgeAction) -> String { "nudge.action.\(action.rawValue)" }
}

// MARK: - Placeholder engine (N1 replaces this)

/// The loading rule engine: it says nothing. Every screen therefore has to handle "no nudges" as a normal state, which
/// is also what thin data, quiet hours and the daily limit produce. N1 deletes this type when the real engine lands
/// behind `NudgeEngine`; nothing else in the delivery layer names it, they all take an injected `NudgeProviding`.
struct SilentNudgeProvider: NudgeProviding, NudgeStatusProviding {
    func pending(now: Date, context: ModelContext) -> [CoachNudge] { [] }
    func status(now: Date, context: ModelContext) -> NudgeStatus { .ready }
}

/// Debug-only fixture provider: `-nudgeFixture a1` puts one hand-written nudge on Today and in the Coach tab so the six
/// UI test actions have something to press without a 28-day store behind them. Never reachable in a release build.
struct NudgeFixtureProvider: NudgeProviding, NudgeStatusProviding {
    let fixture: String
    /// One reset per process, so `-nudgeFixtureReset YES` gives each UI test the same clean ledger.
    private static var didReset = false

    private static func resetIfRequested() {
        guard !didReset, DebugLaunch.bool("nudgeFixtureReset") else { return }
        didReset = true
        NudgeLedgerStore.shared.resetAll()
        DailyGoalOverrideStore.shared.clear()
    }

    func pending(now: Date, context: ModelContext) -> [CoachNudge] {
        Self.resetIfRequested()
        if fixture == "learning" { return [] }
        // A live nudge honours the user's answers exactly as the real policy will: "Not now" pauses the category until
        // the next wake time, and an answered nudge is not repeated the same day.
        guard let nudge = Self.nudge(fixture, now: now) else { return [] }
        if NudgeLedgerStore.shared.isSnoozed(nudge.category, now: now) { return [] }
        if let outcome = NudgeLedgerStore.shared.outcome(for: nudge.id), outcome != .shown { return [] }
        return [nudge]
    }

    func status(now: Date, context: ModelContext) -> NudgeStatus {
        fixture == "learning"
            ? NudgeStatus(learningBaseline: true, nightsRecorded: 3)
            : .ready
    }

    static func nudge(_ rule: String, now: Date) -> CoachNudge? {
        let id = "fixture.\(rule).\(NudgeLedgerStore.dayKey(now))"
        switch rule {
        case "a1":
            return CoachNudge(
                id: id, rule: "a1", category: .recovery,
                title: "Rough night",
                body: "Rough night: your resting heart rate is 9 bpm above your usual and you slept 1 h 20 min under goal.",
                buttons: [.keepGoal, .lighterToday, .why],
                evidence: NudgeEvidence(facts: [
                    NudgeFact(id: "rhr", label: "Resting HR", value: "+9 bpm"),
                    NudgeFact(id: "sleep", label: "Sleep", value: "6 h 10 min"),
                ], chart: NudgeFixtureProvider.chart()),
                seedMessage: "My resting heart rate is 9 bpm above my baseline and I slept 1 h 20 min less than my goal. What should today look like?")
        case "a2":
            return CoachNudge(
                id: id, rule: "a2", category: .recovery,
                title: "Short night",
                body: "You slept 3 h 40 min last night — 4 h 20 min under your goal.",
                buttons: [.lighterToday, .why],
                evidence: NudgeEvidence(facts: [NudgeFact(id: "sleep", label: "Sleep", value: "3 h 40 min")],
                                        chart: NudgeFixtureProvider.chart()),
                seedMessage: "I only slept 3 h 40 min last night against a 8 h goal. How should I adjust today?")
        case "c1":
            return CoachNudge(
                id: id, rule: "c1", category: .stress,
                title: "Stress has stayed high",
                body: "Your stress reading has stayed high for 75 minutes. Two minutes of paced breathing can help.",
                buttons: [.breathe, .notNow],
                evidence: NudgeEvidence(facts: [NudgeFact(id: "stress", label: "High for", value: "75 min")]),
                seedMessage: "My stress reading has been high for 75 minutes. What usually helps it come down?")
        case "g1":
            return CoachNudge(
                id: id, rule: "g1", category: .insight,
                title: "Ring out of touch",
                body: "Your Agara Ring hasn't synced for 26 hours — open the ring screen to reconnect.",
                buttons: [.openRing, .notNow],
                evidence: NudgeEvidence(facts: [NudgeFact(id: "sync", label: "Last sync", value: "26 h ago")]),
                seedMessage: "My ring hasn't synced for 26 hours. What might be wrong?")
        default: // b1 — the step/activity family
            return CoachNudge(
                id: id, rule: "b1", category: .activity,
                title: "Behind on steps",
                body: "4,300 steps to go today. A 12-minute walk would close a good part of it.",
                buttons: [.why, .notNow],
                evidence: NudgeEvidence(facts: [
                    NudgeFact(id: "steps", label: "Steps", value: "2,200 of 6,500"),
                ], chart: NudgeFixtureProvider.chart()),
                seedMessage: "I'm at 2,200 steps with 4,300 to go. What is the most efficient way to close it?")
        }
    }

    /// A tiny steps series, so the seeded answer proves it renders through the one chart component.
    static func chart() -> CoachChart {
        let days = (0..<7).map { i -> CoachChartPoint in
            CoachChartPoint(x: "D\(i + 1)", y: Double([5200, 7100, 4300, 8800, 6100, 9900, 2200][i]))
        }
        return CoachChart(chartType: .bar, title: "Steps, last 7 days", metric: .steps,
                          range: CoachChartRange(start: "D1", end: "D7"), data: days)
    }
}

/// The provider every screen reads. One switch, so the fixture cannot leak into a release build and so N1 only has to
/// change this line (plus delete `SilentNudgeProvider`/`NudgeFixtureProvider`).
enum NudgeEngine {
    static func provider() -> NudgeProviding & NudgeStatusProviding {
        #if DEBUG
        if let fixture = DebugLaunch.string("nudgeFixture"), !fixture.isEmpty, fixture != "off" {
            return NudgeFixtureProvider(fixture: fixture)
        }
        #endif
        return SilentNudgeProvider()
    }
}
