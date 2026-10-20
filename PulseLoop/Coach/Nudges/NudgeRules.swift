import Foundation

/// What one rule decided: the nudge, or why it stayed silent. The policy only ever sees this.
struct RuleOutcome: Equatable, Sendable {
    var rule: NudgeRule
    var nudge: CoachNudge?
    var silentReason: String?
}

/// The 13 rules as pure evaluators over `CoachSignals`. Every threshold comes from
/// `AgaraConfig.Nudges` — there is no literal number in this file except the wording constants noted below.
enum NudgeRules {

    /// A movement break is what B3 suggests, not a rule threshold: the wording says "a few minutes".
    private static let movementBreakMinutes = 5
    /// Rough walking pace used to turn "steps left" into "a N-minute walk" in the wording.
    private static let stepsPerWalkMinute = 100

    static func evaluate(
        _ signals: CoachSignals,
        settings: NudgeSettings = .standard,
        lastUsed: [String: Date] = [:],
        now: Date? = nil,
        locale: Locale = .current
    ) -> [RuleOutcome] {
        let now = now ?? signals.now
        let context = Context(signals: signals, settings: settings, lastUsed: lastUsed, now: now, locale: locale)
        return NudgeRule.allCases.map { rule in
            switch rule {
            case .a1: return context.a1()
            case .a2: return context.a2()
            case .a3: return context.a3()
            case .b1: return context.b1()
            case .b2: return context.b2()
            case .b3: return context.b3()
            case .b4: return context.b4()
            case .c1: return context.c1()
            case .e1: return context.e1()
            case .e2: return context.e2()
            case .f1: return context.f1()
            case .f2: return context.f2()
            case .g1: return context.g1()
            }
        }
    }

    private struct Context {
        typealias N = AgaraConfig.Nudges
        var signals: CoachSignals
        var settings: NudgeSettings
        var lastUsed: [String: Date]
        var now: Date
        var locale: Locale

        var minute: Int { signals.minuteOfDay }

        // MARK: Recovery (A)

        /// Shared gate for the morning rules: no baseline, no night, or a night that was mostly not recorded.
        private var recoverySilence: String? {
            // A1/A2/A3 are the morning recovery set: once the day's activity check has begun the readiness reading
            // is a standing card in Today, not a nudge. The window ends at `b1CheckTime` — no extra threshold.
            if minute > (CoachSignals.minuteOfDay(N.b1CheckTime) ?? 15 * 60) { return "after the morning recovery window" }
            if signals.isLearningBaseline { return "learning the baseline" }
            guard let night = signals.lastNight else { return "no night recorded" }
            if !signals.nightHasEnoughData { return "night data below \(N.minDataPercent)%" }
            if night.totalMinutes <= 0 { return "no night recorded" }
            return nil
        }

        /// The three readiness signals that are allowed to speak. HRV is deliberately absent.
        private var signalsDown: Int {
            [
                (signals.restingHeartRateDeltaPercent ?? 0) >= Double(N.a1RhrAbovePercent),
                (signals.sleepShortMinutes ?? 0) >= Double(N.a1SleepUnderGoalHours * 60),
                signals.stressAboveNormal
            ].filter { $0 }.count
        }

        func a1() -> RuleOutcome {
            if let reason = recoverySilence { return silent(.a1, reason) }
            guard signalsDown >= N.a1MinSignals else { return silent(.a1, "only one signal down") }
            let rhr = signals.restingHeartRateDeltaPercent ?? 0
            let short = signals.sleepShortMinutes ?? 0
            return make(.a1, slots: [
                .rhrDelta: .percent(rhr),
                .sleepShort: .duration(minutes: short)
            ], evidence: [
                CoachNudgeEvidence(metric: "resting_heart_rate_delta_percent", value: rhr, unit: "%"),
                CoachNudgeEvidence(metric: "sleep_short_minutes", value: short, unit: "min"),
                CoachNudgeEvidence(metric: "sleep_goal_minutes", value: signals.sleepGoalMinutes, unit: "min"),
                CoachNudgeEvidence(metric: "baseline_nights", value: Double(signals.baseline.nightsRecorded), unit: "nights")
            ], severity: max(rhr, short / 60))
        }

        func a2() -> RuleOutcome {
            if let reason = recoverySilence { return silent(.a2, reason) }
            let total = signals.sleepTotalMinutes ?? 0
            let short = signals.sleepShortMinutes ?? 0
            let shortOnItsOwn = total < Double(N.a2ShortNightHours * 60)
            let underGoal = short >= Double(N.a2UnderGoalHours * 60)
            guard shortOnItsOwn || underGoal else { return silent(.a2, "not a short night") }
            // A1 absorbs A2 whenever a second signal is down: two reasons to slow down is one message, not two.
            guard signalsDown < N.a1MinSignals else { return silent(.a2, "absorbed by a1") }
            return make(.a2, slots: [
                .sleepTotal: .duration(minutes: total),
                .sleepShort: .duration(minutes: short),
                .sleepGoal: .duration(minutes: signals.sleepGoalMinutes)
            ], evidence: [
                CoachNudgeEvidence(metric: "sleep_total_minutes", value: total, unit: "min"),
                CoachNudgeEvidence(metric: "sleep_short_minutes", value: short, unit: "min"),
                CoachNudgeEvidence(metric: "sleep_goal_minutes", value: signals.sleepGoalMinutes, unit: "min")
            ], severity: short / 60)
        }

        func a3() -> RuleOutcome {
            // A3 ("good to go") has its own, earlier end: the reassurance is a morning message, and letting it run to the
            // activity check made it fire every ordinary afternoon (reports carried it into the activity cases).
            if minute >= (CoachSignals.minuteOfDay(N.a3UntilTime) ?? 12 * 60) {
                return silent(.a3, "after the good-to-go window")
            }
            if let reason = recoverySilence { return silent(.a3, reason) }
            guard let goalPercent = signals.sleepGoalPercent else { return silent(.a3, "no night recorded") }
            let rhrOK = (signals.restingHeartRateDeltaPercent ?? 0) <= 0
            let stressOK = !signals.stressAboveNormal
            guard stressOK else { return silent(.a3, "evening stress above normal") }
            guard rhrOK else { return silent(.a3, "resting heart rate above baseline") }
            guard goalPercent >= Double(N.a3SleepGoalPercent) else {
                return silent(.a3, "sleep at \(Int(goalPercent.rounded()))% of goal")
            }
            let total = signals.sleepTotalMinutes ?? 0
            return make(.a3, slots: [
                .sleepTotal: .duration(minutes: total),
                .sleepGoal: .duration(minutes: signals.sleepGoalMinutes)
            ], evidence: [
                CoachNudgeEvidence(metric: "sleep_total_minutes", value: total, unit: "min"),
                CoachNudgeEvidence(metric: "sleep_goal_percent", value: goalPercent, unit: "%"),
                CoachNudgeEvidence(metric: "resting_heart_rate_delta_percent", value: signals.restingHeartRateDeltaPercent ?? 0, unit: "%")
            ], severity: 0)
        }

        // MARK: Activity (B)

        /// Activity rules need a day that was actually recorded, a user who is awake, and no workout in progress.
        private var activitySilence: String? {
            if !settings.stepReminders { return "step reminders are off" }
            if !signals.today.awake { return "asleep" }
            if signals.today.inWorkout { return "in a workout" }
            if !signals.dayHasEnoughData { return "day data below \(N.minDataPercent)%" }
            return nil
        }

        private var walkMinutes: Int {
            max(1, Int((Double(signals.stepsLeft) / Double(stepsPerWalkMinute)).rounded(.up)))
        }

        private func stepSlots() -> [NudgeSlot: NudgeSlotValue] {
            [
                .stepsLeft: .count(signals.stepsLeft, unit: .step),
                .stepsDone: .count(signals.today.steps, unit: .step),
                .goalSteps: .count(signals.stepGoal, unit: .step),
                .walkMin: .number(walkMinutes)
            ]
        }

        private var stepEvidence: [CoachNudgeEvidence] {
            [
                CoachNudgeEvidence(metric: "steps_today", value: Double(signals.today.steps), unit: "steps"),
                CoachNudgeEvidence(metric: "step_goal", value: Double(signals.stepGoal), unit: "steps"),
                CoachNudgeEvidence(metric: "step_goal_percent", value: signals.stepGoalPercent, unit: "%")
            ]
        }

        func b1() -> RuleOutcome {
            if let reason = activitySilence { return silent(.b1, reason) }
            let checkTime = CoachSignals.minuteOfDay(N.b1CheckTime) ?? 0
            guard minute >= checkTime else { return silent(.b1, "before the \(N.b1CheckTime) check") }
            guard signals.stepGoalPercent < Double(N.b1FractionPercent) else {
                return silent(.b1, "at or above \(N.b1FractionPercent)% of goal")
            }
            return make(.b1, slots: stepSlots(), evidence: stepEvidence, severity: 100 - signals.stepGoalPercent)
        }

        func b2() -> RuleOutcome {
            if let reason = activitySilence { return silent(.b2, reason) }
            let after = CoachSignals.minuteOfDay(N.b2After) ?? 0
            guard minute >= after else { return silent(.b2, "before 17:00") }
            let percent = signals.stepGoalPercent
            guard percent >= Double(N.b2FractionMinPercent), percent <= Double(N.b2FractionMaxPercent) else {
                return silent(.b2, "outside the 85–99% band")
            }
            let quietStart = settings.quietStartMinute(signals: signals)
            // Inclusive: "2 h before quiet hours" includes exactly 2 h before.
            guard quietStart - minute > N.b2QuietBufferHours * 60 else {
                return silent(.b2, "quiet hours within the buffer")
            }
            return make(.b2, slots: stepSlots(), evidence: stepEvidence, severity: 100 - percent)
        }

        func b3() -> RuleOutcome {
            if let reason = activitySilence { return silent(.b3, reason) }
            guard signals.minutesSinceActiveBlock >= N.b3WindowMinutes else { return silent(.b3, "active within 180 min") }
            return make(.b3, slots: [.walkMin: .number(movementBreakMinutes)], evidence: [
                CoachNudgeEvidence(metric: "minutes_since_active_block", value: Double(signals.minutesSinceActiveBlock), unit: "min")
            ], severity: Double(signals.minutesSinceActiveBlock) / 60)
        }

        func b4() -> RuleOutcome {
            if let reason = activitySilence { return silent(.b4, reason) }
            guard signals.stepGoalPercent >= Double(N.b4FractionPercent) else {
                return silent(.b4, "goal not reached")
            }
            return make(.b4, slots: stepSlots(), evidence: stepEvidence, severity: 0)
        }

        // MARK: Stress (C)

        func c1() -> RuleOutcome {
            // Two gates the catalog states and the first version missed: a percentile alone is not a reading (a user whose
            // 80th percentile is 30 should not be nudged about nothing), and stress while walking is being discharged,
            // not endured.
            if !settings.topicEnabled(.stress) { return silent(.c1, "stress nudges are off") }
            if !signals.today.awake { return silent(.c1, "asleep") }
            if signals.today.inWorkout { return silent(.c1, "in a workout") }
            guard let run = signals.stressRun else { return silent(.c1, "no sustained high stress reading") }
            guard run.minutes >= N.c1MinDurationMinutes else { return silent(.c1, "duration below 60 min") }
            guard run.score >= N.c1MinScore else { return silent(.c1, "below the \(N.c1MinScore) floor") }
            // Walking it off is not a reason to be told you are stressed.
            guard run.steps < N.c1MaxSteps else { return silent(.c1, "too many steps during the high stretch") }
            return make(.c1, slots: [.stressMinutes: .count(run.minutes, unit: .minute)], evidence: [
                CoachNudgeEvidence(metric: "stress_minutes_high", value: Double(run.minutes), unit: "min"),
                CoachNudgeEvidence(metric: "stress_steps_during", value: Double(run.steps), unit: "steps"),
                CoachNudgeEvidence(metric: "stress_p80", value: signals.baseline.stressPercentile, unit: "score")
            ], severity: Double(run.minutes) / 60)
        }

        // MARK: Insight (E, F)

        func e1() -> RuleOutcome {
            guard signals.nights.count >= N.e1WindowNights else { return silent(.e1, "fewer than 5 recorded nights") }
            let medianBed = CoachSignalsBuilder.median(signals.nights.map { Double($0.bedMinute) })
            let medianWake = CoachSignalsBuilder.median(signals.nights.map { Double($0.wakeMinute) })
            let driftMinutes = signals.nights.map { night in
                max(abs(Double(night.bedMinute) - medianBed), abs(Double(night.wakeMinute) - medianWake))
            }
            let drifting = driftMinutes.filter { $0 > Double(N.e1DriftHours * 60) }.count
            guard drifting >= N.e1DriftNights else {
                return silent(.e1, "only \(drifting) drifted nights")
            }
            let drift = CoachSignalsBuilder.median(driftMinutes)
            return make(.e1, slots: [
                .driftMinutes: .count(Int(drift.rounded()), unit: .minute),
                .medianBedtime: .timeOfDay(Int(medianBed.rounded())),
                .medianWake: .timeOfDay(Int(medianWake.rounded()))
            ], evidence: [
                CoachNudgeEvidence(metric: "drift_minutes", value: drift, unit: "min"),
                CoachNudgeEvidence(metric: "drift_nights", value: Double(drifting), unit: "nights"),
                CoachNudgeEvidence(metric: "median_bedtime_minute", value: medianBed, unit: "min")
            ], severity: drift / 60)
        }

        /// One metric's two-window trend: the last `e2WindowDays` against the same span before them.
        private struct Trend {
            var metric: String
            var improvementPercent: Double
            var daysAbove: Int
        }

        private var trends: [Trend] {
            let window = N.e2WindowDays
            guard signals.days.count >= window * 2 else { return [] }
            let recent = Array(signals.days.prefix(window))
            let earlier = Array(signals.days.dropFirst(window).prefix(window))
            let metrics: [(String, (CoachSignals.DayPoint) -> Double)] = [
                ("steps", { Double($0.steps) }),
                ("sleep", { $0.sleepMinutes }),
                ("active_minutes", { Double($0.activeMinutes) })
            ]
            return metrics.compactMap { name, value in
                let earlierValues = earlier.map(value)
                let earlierAverage = earlierValues.reduce(0, +) / Double(earlierValues.count)
                guard earlierAverage > 0 else { return nil }
                let recentValues = recent.map(value)
                let recentAverage = recentValues.reduce(0, +) / Double(recentValues.count)
                let improvement = (recentAverage - earlierAverage) / earlierAverage * 100
                let daysAbove = recentValues.filter { $0 > earlierAverage }.count
                return Trend(metric: name, improvementPercent: improvement, daysAbove: daysAbove)
            }
        }

        func e2() -> RuleOutcome {
            let qualifying = trends.filter {
                $0.improvementPercent >= Double(N.e2ImprovementPercent) && $0.daysAbove >= N.e2MinDaysAbove
            }
            guard let best = qualifying.max(by: { $0.improvementPercent < $1.improvementPercent }) else {
                // Say which half of the test failed: not enough change, or not enough days carrying it.
                if let biggest = trends.max(by: { $0.improvementPercent < $1.improvementPercent }),
                   biggest.improvementPercent >= Double(N.e2ImprovementPercent) {
                    return silent(.e2, "only \(biggest.daysAbove) of 14 days above the earlier average")
                }
                return silent(.e2, "below \(N.e2ImprovementPercent)%")
            }
            return make(.e2, slots: [
                .pctAbove: .percent(best.improvementPercent),
                .weekDays: .count(best.daysAbove, unit: .day)
            ], evidence: [
                CoachNudgeEvidence(metric: "improvement_percent", value: best.improvementPercent, unit: "%"),
                CoachNudgeEvidence(metric: "days_above", value: Double(best.daysAbove), unit: "days"),
                CoachNudgeEvidence(metric: "metric", value: Double(best.metric == "steps" ? 1 : best.metric == "sleep" ? 2 : 3), unit: best.metric)
            ], severity: best.improvementPercent)
        }

        func f1() -> RuleOutcome {
            let streak = signals.stepGoalStreakDays
            let milestones = N.f1StreakDays.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let isMilestone = milestones.contains(streak) || (streak > (milestones.max() ?? 0) && (streak - (milestones.max() ?? 0)) % N.f1RepeatEvery == 0)
            guard isMilestone else { return silent(.f1, "\(streak) is not a milestone") }
            return make(.f1, slots: [.streakDays: .number(streak)], evidence: [
                CoachNudgeEvidence(metric: "streak_days", value: Double(streak), unit: "days")
            ], severity: Double(streak))
        }

        func f2() -> RuleOutcome {
            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: now)
            guard weekday == settings.weeklyReviewWeekday else { return silent(.f2, "not the chosen day") }
            guard minute >= settings.weeklyReviewMinute else { return silent(.f2, "before the weekly review time") }
            let week = Array(signals.days.prefix(N.e1WindowNights))
            let goodDays = week.filter(\.hasGoodData).count
            guard goodDays >= N.f2MinGoodDays else { return silent(.f2, "fewer than \(N.f2MinGoodDays) good days") }
            guard let best = week.max(by: { $0.steps < $1.steps }), best.steps > 0 else {
                return silent(.f2, "no day stands out this week")
            }
            let change = trends.map(\.improvementPercent).max() ?? 0
            return make(.f2, slots: [
                .bestWin: .text("\(NudgeTemplate.integer(best.steps, locale: locale)) steps"),
                .pctAbove: .percent(change),
                .weekDays: .count(goodDays, unit: .day)
            ], evidence: [
                CoachNudgeEvidence(metric: "best_day_steps", value: Double(best.steps), unit: "steps"),
                CoachNudgeEvidence(metric: "week_change_percent", value: change, unit: "%"),
                CoachNudgeEvidence(metric: "good_days", value: Double(goodDays), unit: "days")
            ], severity: 0)
        }

        func g1() -> RuleOutcome {
            guard signals.ring.paired else { return silent(.g1, "no ring paired") }
            guard let hours = signals.hoursSinceSync else { return silent(.g1, "the ring has not synced yet") }
            guard hours >= Double(N.g1NoSyncHours) else { return silent(.g1, "synced recently") }
            return make(.g1, slots: [
                .hoursSinceSync: .count(Int(hours.rounded()), unit: .hour),
                .ringName: .text(signals.ring.name)
            ], evidence: [
                CoachNudgeEvidence(metric: "hours_since_sync", value: hours, unit: "h")
            ], severity: hours / 24)
        }

        // MARK: Helpers

        private func silent(_ rule: NudgeRule, _ reason: String) -> RuleOutcome {
            RuleOutcome(rule: rule, nudge: nil, silentReason: reason)
        }

        private func make(
            _ rule: NudgeRule,
            slots: [NudgeSlot: NudgeSlotValue],
            evidence: [CoachNudgeEvidence],
            severity: Double
        ) -> RuleOutcome {
            guard let nudge = CoachNudge.make(
                rule: rule,
                slots: slots,
                evidence: evidence,
                severity: severity,
                fingerprint: fingerprint(rule, severity: severity),
                lastUsed: lastUsed,
                now: now,
                locale: locale
            ) else {
                return RuleOutcome(rule: rule, nudge: nil, silentReason: "no wording could be filled")
            }
            return RuleOutcome(rule: rule, nudge: nudge, silentReason: nil)
        }

        /// Rounded numbers only: the same nudge with the same numbers is never sent twice in a day (policy rule 4).
        private func fingerprint(_ rule: NudgeRule, severity: Double) -> String {
            switch rule {
            case .b1, .b2, .b4:
                // Rounded, not truncated: "the rounded numbers" is what the policy promises, and 1,196 and 1,204
                // are the same reading at any sensible rounding.
                return "\(rule.rawValue):\(Int((Double(signals.today.steps) / 100).rounded()))"
            case .b3:
                return "b3:\(signals.minutesSinceActiveBlock / 60)"
            case .c1:
                return "c1:\(Int(severity * 4))"
            case .a1:
                return "a1:\(Int((signals.restingHeartRateDeltaPercent ?? 0).rounded())):\((signals.sleepShortMinutes ?? 0) / 30 == 0 ? 0 : Int(((signals.sleepShortMinutes ?? 0) / 30).rounded()))"
            case .a2, .a3:
                return "\(rule.rawValue):\((signals.sleepTotalMinutes ?? 0) / 30 == 0 ? 0 : Int(((signals.sleepTotalMinutes ?? 0) / 30).rounded()))"
            case .e1:
                return "e1:\(Int(severity * 2))"
            case .e2:
                return "e2:\(Int(severity.rounded()))"
            case .f1:
                return "f1:\(signals.stepGoalStreakDays)"
            case .f2:
                return "f2:\(signals.days.prefix(N.e1WindowNights).filter(\.hasGoodData).count)"
            case .g1:
                return "g1:\(Int(severity.rounded()))"
            }
        }
    }
}
