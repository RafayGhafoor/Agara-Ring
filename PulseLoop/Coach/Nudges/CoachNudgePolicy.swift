import Foundation

/// What the policy decided for one evaluation: what goes out, in order, and why everything else stayed quiet.
struct NudgeDeliveryPlan: Equatable, Sendable {
    var delivered: [CoachNudge] = []
    /// rule → the documented reason it produced nothing (rules and policy share one map).
    var silent: [NudgeRule: String] = [:]
    var routinePushesUsed: Int = 0
    var celebrationPushesUsed: Int = 0

    var pushCount: Int { delivered.filter { $0.delivery == .push }.count }
    var rules: [NudgeRule] { delivered.map(\.rule) }
}

/// The anti-nagging policy — a pure function of its arguments. No clock, no store, no network: the caller passes
/// the candidates the rules produced, the ledger of what already happened, the instant being decided, and the
/// user's settings. That is what makes every rule in `docs/config/coach_nudges_cases.json` checkable.
enum CoachNudgePolicy {

    typealias N = AgaraConfig.Nudges

    /// Categories in the order that wins: recovery → stress → goal → activity → celebration → insight.
    static let priority: [NudgeCategory] = N.policyPriorityOrder
        .split(separator: ",")
        .compactMap { NudgeCategory(rawValue: $0.trimmingCharacters(in: .whitespaces)) }

    /// The gap ladder, e.g. 6 → 12 → 24 hours.
    static let gapLadder: [Double] = N.policyGapLadderHours
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

    static func decide(
        candidates: [RuleOutcome],
        ledger: NudgeLedger,
        now: Date,
        settings: NudgeSettings = .standard,
        signals: CoachSignals? = nil,
        calendar: Calendar = .current
    ) -> NudgeDeliveryPlan {
        var plan = NudgeDeliveryPlan()

        // 1. Start from the rules' verdicts.
        var eligible: [CoachNudge] = []
        for outcome in candidates {
            if let nudge = outcome.nudge {
                eligible.append(nudge)
            } else if let reason = outcome.silentReason {
                plan.silent[outcome.rule] = reason
            }
        }

        // 2. Related nudges merge, and recovery beats activity for the rest of the day.
        let sentToday = ledger.sentToday(now, calendar: calendar)
        let recoveryFired = sentToday.contains { $0.rule == .a1 || $0.rule == .a2 }
            || eligible.contains { $0.rule == .a1 || $0.rule == .a2 }
        let goalReached = sentToday.contains { $0.rule == .b4 || $0.rule == .f1 }
            || eligible.contains { $0.rule == .b4 || $0.rule == .f1 }

        if eligible.contains(where: { $0.rule == .a1 }) {
            eligible.removeAll { $0.rule == .a2 }
            plan.silent[.a2] = "absorbed by a1"
        }
        if recoveryFired {
            eligible.removeAll { [.b1, .b2, .b3].contains($0.rule) }
            for rule in [NudgeRule.b1, .b2, .b3] { plan.silent[rule] = "recovery fired today" }
        }
        if goalReached {
            eligible.removeAll { $0.rule == .b1 || $0.rule == .b2 }
            plan.silent[.b1] = "goal reached"
            plan.silent[.b2] = "goal reached"
        }

        // 3. Per-nudge gates: toggles, "Not now", once-a-day, fingerprints, the gap, quiet hours.
        let quiet = settings.isQuiet(minuteOfDay: minutes(now, calendar: calendar), signals: signals ?? .init(now: now))
        var gated: [CoachNudge] = []
        for nudge in eligible {
            if !settings.topicEnabled(nudge.category) {
                plan.silent[nudge.rule] = "turned off in settings"
                continue
            }
            if let until = ledger.snoozedUntil[nudge.category], until > now {
                plan.silent[nudge.rule] = "not now until tomorrow"
                continue
            }
            if oncePerDay(nudge.rule), sentToday.contains(where: { $0.rule == nudge.rule }) {
                plan.silent[nudge.rule] = "already sent today"
                continue
            }
            if nudge.rule == .c1, sentToday.filter({ $0.rule == .c1 }).count >= 2 {
                plan.silent[nudge.rule] = "one follow-up already sent"
                continue
            }
            if nudge.rule.isIntraday, ledger.fingerprints(on: now, calendar: calendar).contains(nudge.fingerprint) {
                plan.silent[nudge.rule] = "duplicate fingerprint today"
                continue
            }
            if let gapReason = gapSilence(for: nudge, ledger: ledger, now: now) {
                plan.silent[nudge.rule] = gapReason
                continue
            }
            if nudge.delivery == .push, quiet,
               !(nudge.category == .recovery && (signals?.today.awake ?? false)) {
                // A nudge that lands in quiet hours is dropped, not saved for the morning. The one exception is the
                // morning recovery push: when the ring already shows the user awake at the end of quiet hours, A1 is
                // the message the quiet window would otherwise make impossible to deliver at all.
                plan.silent[nudge.rule] = "quiet hours"
                continue
            }
            gated.append(nudge)
        }

        // 4. Priority order, then the push budget.
        gated.sort { lhs, rhs in
            let left = priority.firstIndex(of: lhs.category) ?? priority.count
            let right = priority.firstIndex(of: rhs.category) ?? priority.count
            if left != right { return left < right }
            return lhs.severity > rhs.severity
        }

        var routine = ledger.routinePushesToday
            + sentToday.filter { $0.delivery == .push && !isCelebration($0.rule) }.count
        var celebrations = sentToday.filter { $0.delivery == .push && isCelebration($0.rule) }.count
        let routineLimit = min(N.policyDailyLimitMax, max(N.policyDailyLimitMin, settings.dailyLimit))
        let celebrationLimit = settings.celebrationExtra ? 1 : 0

        for nudge in gated {
            // Notifications off (or not yet permitted): the nudge is still delivered — as a card — and consumes no push
            // budget. Dropping it entirely would make "turn off notifications" mean "turn off the feature".
            if nudge.delivery == .push, !ledger.notificationsEnabled {
                var asCard = nudge
                asCard.delivery = .card
                plan.delivered.append(asCard)
                continue
            }
            if nudge.delivery == .push {
                if nudge.isCelebration {
                    guard celebrations < celebrationLimit else {
                        plan.silent[nudge.rule] = "celebration push already used today"
                        continue
                    }
                    celebrations += 1
                } else {
                    guard routine < routineLimit else {
                        plan.silent[nudge.rule] = "daily push limit reached"
                        continue
                    }
                    routine += 1
                }
            }
            plan.delivered.append(nudge)
        }

        // 5. A delivered streak absorbs "goal reached": the big number is already the streak's opening line.
        if plan.delivered.contains(where: { $0.rule == .f1 }) {
            plan.delivered.removeAll { $0.rule == .b4 }
            plan.silent[.b4] = "absorbed by f1"
        }

        plan.routinePushesUsed = routine
        plan.celebrationPushesUsed = celebrations
        return plan
    }

    // MARK: Helpers

    private static func isCelebration(_ rule: NudgeRule) -> Bool { rule.isCelebration }

    private static func minutes(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Rules that are judged on last night (or on a day that has ended) can only fire once a day.
    private static func oncePerDay(_ rule: NudgeRule) -> Bool {
        switch rule {
        case .a1, .a2, .a3, .b3, .b4, .e1, .e2, .f1, .f2, .g1: return true
        case .b1, .b2, .c1: return false
        }
    }

    /// Rule-specific gaps the category cooldown cannot express: E1 is weekly, E2 every two weeks per metric,
    /// C1's follow-up waits `c1FollowupHours`.
    static func ruleGap(_ rule: NudgeRule, base: Double) -> Double {
        switch rule {
        case .e1: return Double(N.e1CooldownDays) * 86_400
        case .e2: return Double(N.e2CooldownDays) * 86_400
        case .c1: return Double(N.c1FollowupHours) * 3600
        default: return base
        }
    }

    /// 3 dismissals in 7 days double the category's gap, then double again (6 → 12 → 24 h). Any tap or action
    /// clears the dismissals, which resets the ladder.
    static func categoryGap(_ category: NudgeCategory, ledger: NudgeLedger, now: Date) -> Double {
        let window = now.addingTimeInterval(-Double(N.policyDismissalWindowDays) * 86_400)
        let dismissals = ledger.dismissals(in: category, since: window)
        let steps = N.policyDismissalsToDouble > 0 ? dismissals / N.policyDismissalsToDouble : 0
        let index = min(max(steps, 0), gapLadder.count - 1)
        return (gapLadder.indices.contains(index) ? gapLadder[index] : Double(N.policyCooldownHours)) * 3600
    }

    private static func gapSilence(for nudge: CoachNudge, ledger: NudgeLedger, now: Date) -> String? {
        let base = categoryGap(nudge.category, ledger: ledger, now: now)
        guard let last = ledger.lastSent(category: nudge.category) else { return nil }
        let gap = ruleGap(nudge.rule, base: base)
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed < gap else { return nil }
        // A materially worse reading may speak inside the gap: the gap exists to stop repeats, not to hide a change.
        guard nudge.severity <= last.severity else { return nil }
        let widened = base > Double(N.policyCooldownHours) * 3600
        return widened
            ? "category gap widened to \(Int((gap / 3600).rounded()))h"
            : "inside the \(Int((gap / 3600).rounded()))h gap"
    }
}
