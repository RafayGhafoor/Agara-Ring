import Foundation
import SwiftData

/// The 13 deterministic rules. The raw value is the id the policy cases use.
enum NudgeRule: String, CaseIterable, Sendable {
    case a1, a2, a3, b1, b2, b3, b4, c1, e1, e2, f1, f2, g1
}

/// The policy bucket a nudge belongs to. Toggles, gaps and the priority order are per category.
enum NudgeCategory: String, CaseIterable, Codable, Sendable {
    case recovery, stress, goal, activity, celebration, insight
}

enum NudgeDelivery: String, Codable, Sendable {
    case push, card
}

enum NudgeButton: String, Sendable {
    case keepGoal = "keep_goal"
    case lighterToday = "lighter_today"
    case why
    case notNow = "not_now"
    case breathe
    case openRing = "open_ring"

    var title: String {
        switch self {
        case .keepGoal: return AgaraCopy.nudgeButtonKeepGoal
        case .lighterToday: return AgaraCopy.nudgeButtonLighterToday
        case .why: return AgaraCopy.nudgeButtonWhy
        case .notNow: return AgaraCopy.nudgeButtonNotNow
        case .breathe: return AgaraCopy.nudgeButtonBreathe
        case .openRing: return AgaraCopy.nudgeButtonOpenRing
        }
    }
}

/// A number the nudge is built from — carried so the Coach tab can seed a message and a chart from it,
/// and never re-read the stores.
struct CoachNudgeEvidence: Equatable, Sendable {
    var metric: String
    var value: Double
    var unit: String
}

/// One nudge, ready to show. Everything user-visible is rendered by `NudgeTemplate`; this type only carries
/// the rendered text and the numbers behind it.
struct CoachNudge: Identifiable, Equatable, Sendable {
    var rule: NudgeRule
    var category: NudgeCategory
    var delivery: NudgeDelivery
    var title: String
    var body: String
    /// The message the Coach tab opens with (evidence + chart + 3 suggested questions) at zero tokens.
    var seed: String
    var evidence: [CoachNudgeEvidence]
    var buttons: [NudgeButton]
    /// Rounded numbers, so the same nudge is never sent twice in one day.
    var fingerprint: String
    /// How far from the user's normal this nudge is. A materially worse reading may skip the cooldown.
    var severity: Double
    var templateID: String
    var isCelebration: Bool
}

extension NudgeRule {

    /// Readiness uses only sleep, resting HR last night and stress the evening before. Those are the morning rules.
    var category: NudgeCategory {
        switch self {
        case .a1, .a2, .a3: return .recovery
        case .c1: return .stress
        case .b4: return .goal
        case .b1, .b2, .b3, .f1: return .activity
        case .e2: return .celebration
        case .e1, .f2: return .insight
        case .g1: return .activity
        }
    }

    var delivery: NudgeDelivery {
        switch self {
        case .a1: return NudgeDelivery(rawValue: AgaraConfig.Nudges.a1Delivery) ?? .push
        case .a2: return NudgeDelivery(rawValue: AgaraConfig.Nudges.a2Delivery) ?? .card
        case .a3: return NudgeDelivery(rawValue: AgaraConfig.Nudges.a3Delivery) ?? .card
        case .b1: return NudgeDelivery(rawValue: AgaraConfig.Nudges.b1Delivery) ?? .push
        case .b2: return .card
        case .b4: return .card
        default: return .push
        }
    }

    /// Celebrations get one push beyond the routine daily limit (policy rule 1). B4 is a celebration but lands as
    /// the Today card: the goal ring already shows the number, and the extra push goes to the streak (F1) and the
    /// improvement (E2) — the two messages that need to arrive while they still matter.
    var isCelebration: Bool {
        switch self {
        case .b4, .e2, .f1: return true
        default: return false
        }
    }

    /// Rules whose numbers can change during the day. The fingerprint and the 6-hour gap protect those; a rule
    /// judged on last night can only fire once a day anyway.
    var isIntraday: Bool {
        switch self {
        case .b1, .b2, .b3, .b4, .c1, .g1: return true
        default: return false
        }
    }

    var buttons: [NudgeButton] {
        switch self {
        case .a1: return [.keepGoal, .lighterToday, .why]
        case .a2: return [.lighterToday, .why]
        case .a3, .b4, .e1, .e2, .f1, .f2: return [.why]
        case .b1: return [.why, .notNow]
        case .b2, .b3: return [.notNow]
        case .c1: return [.breathe, .notNow]
        case .g1: return [.openRing]
        }
    }
}

extension CoachNudge {

    /// Build a nudge from signals. Returns nil when no wording can be fully rendered (a slot is missing).
    static func make(
        rule: NudgeRule,
        slots: [NudgeSlot: NudgeSlotValue],
        evidence: [CoachNudgeEvidence],
        severity: Double,
        fingerprint: String,
        lastUsed: [String: Date],
        now: Date,
        locale: Locale = .current
    ) -> CoachNudge? {
        guard let rendered = NudgeTemplate.rotation(for: rule, slots: slots, lastUsed: lastUsed, now: now, locale: locale),
              let seed = NudgeTemplate.render(NudgeTemplate.seed(for: rule), slots: slots, locale: locale)
        else { return nil }
        return CoachNudge(
            rule: rule,
            category: rule.category,
            delivery: rule.delivery,
            title: title(from: rendered.text),
            body: rendered.text,
            seed: seed,
            evidence: evidence,
            buttons: rule.buttons,
            fingerprint: fingerprint,
            severity: severity,
            templateID: rendered.id,
            isCelebration: rule.isCelebration
        )
    }

    /// A push needs a title; the catalog has none, so it is the first sentence of the wording — never new copy.
    static func title(from body: String) -> String {
        if let end = body.firstIndex(where: { ".!?".contains($0) }) {
            return String(body[...end]).trimmingCharacters(in: .whitespaces)
        }
        return body
    }
}

@MainActor
protocol NudgeProviding {
    /// The nudges that survive the policy right now, most important first (priority order:
    /// recovery → stress → goal → activity → celebration → insight). Empty means "nothing to say" — thin data, quiet
    /// hours, the daily limit, a snooze and the learning-baseline rule all end here, as silence rather than an excuse.
    func pending(now: Date, context: ModelContext) -> [CoachNudge]
}

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

struct NudgeFact: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

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

// MARK: - Delivery seams (N2) and the bridge to the engine (N1)

/// What the delivery layer needs from a button that the copy catalog does not describe: the notification action id, and
/// whether the tap counts as a dismissal for the policy's learning rule ("Not now", or no tap within 4 h).
extension NudgeCategory {
    /// Celebrations have their own push budget (policy rule 1) and never consume a routine push.
    var isCelebration: Bool { self == .celebration }

    /// Which notification category a push for this lane is posted under. Three categories, not six: the actions a user
    /// can take are the same, and the system UI groups them by what they are asking for.
    var notificationCategory: AgaraNotificationCategory {
        switch self {
        case .recovery: return .coachRecovery
        case .stress: return .coachStress
        default: return .coachGeneric
        }
    }
}

extension NudgeButton: Identifiable, CaseIterable {
    var id: String { rawValue }
    /// The `UNNotificationAction` identifier the app registers.
    var notificationIdentifier: String { "agara.nudge.\(rawValue)" }
    /// "Not now" is the only button that is a dismissal; any other tap resets the category's gap.
    var countsAsDismissal: Bool { self == .notNow }
}

/// The delivery layer was written against its own `NudgeAction` while the engine shipped `NudgeButton` with the same six
/// cases. One name serves both, so no call site had to learn a second vocabulary.
typealias NudgeAction = NudgeButton

extension CoachNudge {
    /// Stable identity for SwiftUI lists and the ledger: rule plus fingerprint (the same rule with different rounded
    /// numbers is a different nudge).
    var id: String { "\(rule.rawValue):\(fingerprint)" }
    /// The rule as the string the ledger, the fixtures and the notification payload store.
    var ruleID: String { rule.rawValue }
    /// The seed message the Coach tab opens with (the engine calls it `seed`).
    var seedMessage: String { seed }
    /// Accessibility identifier for the card (the UI tests find it by rule).
    var cardIdentifier: String { "nudge.card \(rule.rawValue)" }
    /// Accessibility identifier for one of its buttons.
    func actionIdentifier(_ button: NudgeButton) -> String { "nudge.\(rule.rawValue).\(button.rawValue)" }

    /// Evidence in the shape the card and the Coach seed render. The chart stays nil until a rule carries a series -
    /// the chart itself is drawn by the shared chart component from a spec, never here.
    var evidencePayload: NudgeEvidence {
        NudgeEvidence(facts: evidence.enumerated().map { index, item in
            NudgeFact(id: "\(rule.rawValue)-\(index)-\(item.metric)",
                      label: NudgeFact.label(for: item.metric),
                      value: NudgeFact.format(item))
        }, chart: nil, learningBaseline: false)
    }
}

// MARK: - Evidence presentation

extension NudgeFact {
    /// Human label for an engine metric key. The engine's keys are stable snake_case ids (they travel to the ledger and
    /// to the Coach seed), so the readable label lives here rather than in the rule.
    static func label(for metric: String) -> String {
        switch metric {
        case "resting_heart_rate_delta_percent": return "Resting HR"
        case "sleep_short_minutes", "sleep_goal_minutes", "sleep_total_minutes": return "Sleep"
        case "baseline_nights": return "Baseline"
        case "steps_today": return "Steps"
        case "step_goal": return "Step goal"
        case "step_goal_percent", "sleep_goal_percent": return "Goal met"
        case "streak_days": return "Streak"
        case "stress_minutes_high": return "Stress"
        case "stress_steps_during": return "Steps during"
        case "minutes_since_active_block": return "Still for"
        case "hours_since_sync": return "No sync for"
        case "drift_nights": return "Nights drifted"
        case "drift_minutes": return "Drift"
        case "median_bedtime_minute": return "Usual bedtime"
        case "improvement_percent", "week_change_percent": return "Change"
        case "days_above": return "Days above"
        case "good_days": return "Good days"
        case "best_day_steps": return "Best day"
        case "metric": return "Metric"
        default:
            // Never show a raw snake_case key to a person: fall back to the words it is made of.
            return metric.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// Formats a value with its unit the way the card and the seed read it: minutes as "1 h 20 min", percentages with a
    /// sign (a delta), counts plain, and locale-aware grouping.
    static func format(_ evidence: CoachNudgeEvidence, locale: Locale = .current) -> String {
        switch evidence.unit {
        case "min":
            let minutes = Int(evidence.value.rounded())
            let hours = minutes / 60, rest = minutes % 60
            if hours > 0 { return "\(hours) h \(rest) min" }
            return "\(minutes) min"
        case "%":
            let value = Int(evidence.value.rounded())
            return evidence.metric.contains("delta") || evidence.metric.contains("improvement")
                || evidence.metric.contains("change") ? "+\(value)%" : "\(value)%"
        case "min_of_day":
            let minutes = Int(evidence.value.rounded()) % (24 * 60)
            return String(format: "%02d:%02d", minutes / 60, minutes % 60)
        case "bpm":
            let value = Int(evidence.value.rounded())
            return evidence.metric.contains("delta") && value > 0 ? "+\(value) bpm" : "\(value) bpm"
        default:
            let formatted = evidence.value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            return evidence.unit.isEmpty ? formatted : "\(formatted) \(evidence.unit)"
        }
    }

    static func format(_ evidence: CoachNudgeEvidence) -> String { format(evidence, locale: .current) }
}

// MARK: - Providers (fixtures for UI tests, silence for a build without the engine wired)

/// A build with no provider wired says nothing. Silence is the documented default: a nudge is an interruption, so
/// "unknown" must never become "show something".
struct SilentNudgeProvider: NudgeProviding, NudgeStatusProviding {
    func pending(now: Date, context: ModelContext) -> [CoachNudge] { [] }
    func status(now: Date, context: ModelContext) -> NudgeStatus { .ready }
}

/// Scripted nudges for UI tests and screenshots (`-nudgeFixture a1|b1|f1|learning`), built from the engine's own model
/// so the card, the buttons and the seed render exactly what a real nudge renders. Debug builds only.
struct NudgeFixtureProvider: NudgeProviding, NudgeStatusProviding {
    let fixture: String

    func pending(now: Date, context: ModelContext) -> [CoachNudge] {
        Self.nudge(fixture, now: now).map { [$0] } ?? []
    }

    func status(now: Date, context: ModelContext) -> NudgeStatus {
        fixture == "learning" ? NudgeStatus(learningBaseline: true, nightsRecorded: 3) : .ready
    }

    static func nudge(_ rule: String, now: Date) -> CoachNudge? {
        switch rule {
        case "a1":
            return CoachNudge(
                rule: .a1, category: .recovery, delivery: .push,
                title: "Rough night",
                body: "Rough night: your resting heart rate is 9 bpm above your usual and you slept 1 h 30 min under goal.",
                seed: "My resting heart rate is 9 bpm above my baseline and I slept 1 h 30 min less than my goal. What should today look like?",
                evidence: [
                    CoachNudgeEvidence(metric: "resting_heart_rate_delta_percent", value: 12, unit: "%"),
                    CoachNudgeEvidence(metric: "sleep_short_minutes", value: 90, unit: "min"),
                ],
                buttons: [.keepGoal, .lighterToday, .why],
                fingerprint: "fixture-a1", severity: 0.8, templateID: "nudge_a1_v1", isCelebration: false)
        case "b1":
            return CoachNudge(
                rule: .b1, category: .activity, delivery: .push,
                title: "Behind on steps",
                body: "2 400 steps to go today. A 20-minute walk would close a good part of it.",
                seed: "I'm at 7 600 steps with 2 400 to go. What is the most efficient way to close it?",
                evidence: [
                    CoachNudgeEvidence(metric: "steps_today", value: 7600, unit: "steps"),
                    CoachNudgeEvidence(metric: "step_goal", value: 10000, unit: "steps"),
                ],
                buttons: [.why, .notNow],
                fingerprint: "fixture-b1", severity: 0.4, templateID: "nudge_b1_v1", isCelebration: false)
        case "f1":
            return CoachNudge(
                rule: .f1, category: .celebration, delivery: .push,
                title: "7-day streak",
                body: "7 days in a row on your step goal.",
                seed: "I'm on a 7-day streak. What would help me keep it going without overdoing it?",
                evidence: [CoachNudgeEvidence(metric: "streak_days", value: 7, unit: "days")],
                buttons: [],
                fingerprint: "fixture-f1", severity: 0.2, templateID: "nudge_f1_v1", isCelebration: true)
        default:
            return nil
        }
    }
}

/// Which provider this build runs. Debug builds can substitute a fixture; everything else is silent until the real
/// provider (signals + rules + policy) is wired to the store.
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
