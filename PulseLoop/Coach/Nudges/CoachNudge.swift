import Foundation

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
struct CoachNudge: Equatable, Sendable {
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
