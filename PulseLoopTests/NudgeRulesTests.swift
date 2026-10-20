import XCTest
@testable import PulseLoop

/// The 13 rules at their edges (exactly at, one below, one above) and the wording renderer.
///
/// Every signal is built by hand, so each assertion names the one number it moves. Thresholds are read from
/// `AgaraConfig.Nudges` — if the catalog changes, these tests move with it.
final class NudgeRulesTests: XCTestCase {

    private typealias N = AgaraConfig.Nudges

    // MARK: Fixtures

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    private func at(hour: Int, minute: Int = 0, on day: String) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date(day))
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    /// A recovery-shaped morning: a 21-night baseline, a normal night, and a user who just moved.
    private func morningSignal(
        _ day: String = "2026-10-20T07:30:00Z",
        hour: Int = 7,
        minute: Int = 30,
        baselineNights: Int = 21,
        sleepGoalMinutes: Double = 480,
        sleepTotalMinutes: Double = 480,
        restingHeartRate: Double = 60,
        baselineRestingHeartRate: Double = 60,
        eveningStress: Double = 30,
        baselineEveningStress: Double = 30,
        dataPercent: Double = 96
    ) -> CoachSignals {
        var signals = CoachSignals(now: at(hour: hour, minute: minute, on: day))
        signals.baseline = CoachSignals.Baseline(
            nightsRecorded: baselineNights,
            sleepMinutes: 480,
            bedMinute: -60,
            wakeMinute: 420,
            restingHeartRate: baselineRestingHeartRate,
            eveningStress: baselineEveningStress,
            stressPercentile: 55
        )
        signals.lastNight = CoachSignals.Night(
            totalMinutes: sleepTotalMinutes,
            asleepMinutes: sleepTotalMinutes,
            dataPercent: dataPercent,
            restingHeartRate: restingHeartRate,
            bedMinute: -60,
            wakeMinute: 420,
            eveningStress: eveningStress
        )
        signals.goals = CoachSignals.Goals(steps: 10_000, sleepMinutes: sleepGoalMinutes)
        signals.today = CoachSignals.Today(
            steps: 2_000,
            blocks: [CoachSignals.StepBlock(startMinute: hour * 60 + minute - 30, steps: 500)],
            inWorkout: false,
            awake: true,
            dataPercent: 100
        )
        return signals
    }

    private func activitySignal(steps: Int, hour: Int, minute: Int = 0) -> CoachSignals {
        var signals = morningSignal(hour: hour, minute: minute)
        signals.today.steps = steps
        signals.today.blocks = [CoachSignals.StepBlock(startMinute: hour * 60 + minute - 30, steps: 500)]
        return signals
    }

    private func outcome(_ signals: CoachSignals, _ rule: NudgeRule) -> RuleOutcome {
        NudgeRules.evaluate(signals).first { $0.rule == rule }!
    }

    // MARK: A1 low readiness

    func testA1FiresAtTwoSignalsDownExactly() {
        // resting HR exactly +12% and sleep exactly 2h short: the threshold itself counts.
        let signals = morningSignal(sleepTotalMinutes: 480 - 120, restingHeartRate: 60 * 1.12)
        let result = outcome(signals, .a1)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.category, .recovery)
        XCTAssertEqual(result.nudge?.delivery, .push)
        XCTAssertEqual(result.nudge?.buttons ?? [], [NudgeButton.keepGoal, .lighterToday, .why])
    }

    func testA1SilentOneBelowBothThresholds() {
        let signals = morningSignal(sleepTotalMinutes: 480 - 119, restingHeartRate: 60 * 1.119)
        let result = outcome(signals, .a1)
        XCTAssertNil(result.nudge)
        XCTAssertEqual(result.silentReason, "only one signal down")
    }

    func testA1SilentWhileLearningTheBaseline() {
        let signals = morningSignal(baselineNights: N.baselineMinNights - 1, sleepTotalMinutes: 300, restingHeartRate: 80)
        for rule in [NudgeRule.a1, .a2, .a3] {
            let result = outcome(signals, rule)
            XCTAssertNil(result.nudge, "\(rule) must stay silent while learning")
            XCTAssertEqual(result.silentReason, "learning the baseline")
        }
    }

    func testA1SilentOnThinNight() {
        let signals = morningSignal(sleepTotalMinutes: 300, restingHeartRate: 80, dataPercent: Double(N.minDataPercent) - 1)
        XCTAssertEqual(outcome(signals, .a1).silentReason, "night data below \(N.minDataPercent)%")
    }

    func testA1UsesStressAsTheSecondSignal() {
        // Stress above the user's own normal is a signal down, exactly like resting HR and sleep.
        var signals = morningSignal(sleepTotalMinutes: 480, restingHeartRate: 60, eveningStress: 61, baselineEveningStress: 60)
        XCTAssertEqual(outcome(signals, .a1).silentReason, "only one signal down")
        signals.lastNight?.restingHeartRate = 60 * 1.13
        XCTAssertNotNil(outcome(signals, .a1).nudge)
    }

    // MARK: A2 short night

    func testA2FiresJustUnderFourHoursAlone() {
        var signals = morningSignal(sleepTotalMinutes: Double(N.a2ShortNightHours * 60) - 1)
        signals.lastNight?.restingHeartRate = 60
        let result = outcome(signals, .a2)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.delivery, .card)
        XCTAssertEqual(result.nudge?.buttons ?? [], [NudgeButton.lighterToday, .why])
    }

    func testA2SilentAtExactlyFourHoursAgainstASixHourGoal() {
        // Four hours is not "under four hours", and with a six-hour goal it is not two hours short either.
        let signals = morningSignal(sleepGoalMinutes: 300, sleepTotalMinutes: Double(N.a2ShortNightHours * 60))
        XCTAssertEqual(outcome(signals, .a2).silentReason, "not a short night")
    }

    func testA2AbsorbedByA1WithASecondSignal() {
        // 3.5 h is short on its own; the elevated resting HR makes it A1's story instead.
        let signals = morningSignal(sleepTotalMinutes: 210, restingHeartRate: 60 * 1.13)
        XCTAssertNotNil(outcome(signals, .a1).nudge)
        XCTAssertEqual(outcome(signals, .a2).silentReason, "absorbed by a1")
    }

    // MARK: A3 good to go

    func testA3FiresAtNinetyPercentOfGoalAndEverySignalAtBaseline() {
        let signals = morningSignal(sleepTotalMinutes: 480 * 0.9, restingHeartRate: 60, eveningStress: 30, baselineEveningStress: 30)
        let result = outcome(signals, .a3)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.delivery, .card)
        XCTAssertEqual(result.nudge?.buttons ?? [], [NudgeButton.why])
    }

    func testA3SilentOnePercentBelowTheGoal() {
        // 89% of the goal, RHR and evening stress at baseline: the sleep floor is the only thing saying no, and the
        // reason now names that cause instead of "a signal is below baseline".
        let signals = morningSignal(sleepTotalMinutes: 480 * 0.89)
        XCTAssertEqual(outcome(signals, .a3).silentReason, "sleep at 89% of goal")
    }

    // MARK: B1 behind on steps

    func testB1SilentOneMinuteBeforeTheCheckTime() {
        let signals = activitySignal(steps: 100, hour: 14, minute: 59)
        XCTAssertEqual(outcome(signals, .b1).silentReason, "before the 15:00 check")
    }

    func testB1FiresOneStepBelowAQuarterOfTheGoal() {
        let threshold = 10_000 * N.b1FractionPercent / 100
        let signals = activitySignal(steps: threshold - 1, hour: 15)
        let result = outcome(signals, .b1)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.delivery, .push)
        XCTAssertEqual(result.nudge?.buttons ?? [], [NudgeButton.why, .notNow])
    }

    func testB1SilentAtExactlyAQuarterOfTheGoal() {
        let threshold = 10_000 * N.b1FractionPercent / 100
        let signals = activitySignal(steps: threshold, hour: 15)
        XCTAssertEqual(outcome(signals, .b1).silentReason, "at or above 25% of goal")
    }

    // MARK: B2 almost there

    func testB2SilentBeforeSeventeen() {
        let signals = activitySignal(steps: 8_600, hour: 16, minute: 59)
        XCTAssertEqual(outcome(signals, .b2).silentReason, "before 17:00")
    }

    func testB2FiresAtTheLowerBandEdge() {
        let signals = activitySignal(steps: 10_000 * N.b2FractionMinPercent / 100, hour: 17)
        XCTAssertNotNil(outcome(signals, .b2).nudge)
    }

    func testB2SilentOnePercentBelowTheBand() {
        let signals = activitySignal(steps: 10_000 * (N.b2FractionMinPercent - 1) / 100, hour: 17)
        XCTAssertEqual(outcome(signals, .b2).silentReason, "outside the 85–99% band")
    }

    func testB2SilentWhenQuietHoursAreInsideTheBuffer() {
        let quietStart = at(hour: 22 - N.b2QuietBufferHours, minute: 0, on: "2026-10-20T07:30:00Z")
        _ = quietStart
        let signals = activitySignal(steps: 9_000, hour: 21, minute: 30)
        XCTAssertEqual(outcome(signals, .b2).silentReason, "quiet hours within the buffer")
    }

    // MARK: B3 been still

    func testB3SilentOneMinuteInsideTheWindow() {
        var signals = activitySignal(steps: 3_000, hour: 14)
        signals.today.blocks = [CoachSignals.StepBlock(startMinute: 14 * 60 - N.b3WindowMinutes + 1 - N.b3BlockMinutes, steps: N.b3BlockSteps)]
        XCTAssertEqual(outcome(signals, .b3).silentReason, "active within 180 min")
    }

    func testB3FiresAtTheWindowEdge() {
        var signals = activitySignal(steps: 3_000, hour: 14)
        signals.today.blocks = [CoachSignals.StepBlock(startMinute: 14 * 60 - N.b3WindowMinutes - N.b3BlockMinutes, steps: N.b3BlockSteps)]
        XCTAssertNotNil(outcome(signals, .b3).nudge)
    }

    func testB3IgnoresBlocksUnderTheStepFloor() {
        var signals = activitySignal(steps: 3_000, hour: 14)
        signals.today.blocks = [CoachSignals.StepBlock(startMinute: 14 * 60 - 30, steps: N.b3BlockSteps - 1)]
        // A block that never qualified does not count as movement: the window runs from midnight.
        XCTAssertNotNil(outcome(signals, .b3).nudge)
    }

    // MARK: B4 goal reached

    func testB4FiresAtExactlyTheGoal() {
        let signals = activitySignal(steps: 10_000, hour: 18)
        let result = outcome(signals, .b4)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.category, .goal)
        XCTAssertTrue(result.nudge?.isCelebration ?? false)
    }

    func testB4SilentOneStepShort() {
        let signals = activitySignal(steps: 9_999, hour: 18)
        XCTAssertEqual(outcome(signals, .b4).silentReason, "goal not reached")
    }

    // MARK: C1 stress

    private func stressSignal(minutes: Int, steps: Int, score: Int = 75, hour: Int = 15) -> CoachSignals {
        var signals = morningSignal(hour: hour)
        // `score` is part of the reading now: C1 refuses a run below the absolute floor even when the user's own
        // percentile says it is high (catalog nudge_c1_min_score).
        signals.stressRun = CoachSignals.StressRun(minutes: minutes, steps: steps, score: score)
        return signals
    }

    func testC1SilentOneMinuteShortOfTheDuration() {
        let signals = stressSignal(minutes: N.c1MinDurationMinutes - 1, steps: 0)
        XCTAssertEqual(outcome(signals, .c1).silentReason, "duration below 60 min")
    }

    func testC1FiresAtTheDurationEdge() {
        let result = outcome(stressSignal(minutes: N.c1MinDurationMinutes, steps: 0), .c1)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.buttons ?? [], [NudgeButton.breathe, .notNow])
    }

    func testC1SilentWhenTheUserWalkedItOff() {
        let signals = stressSignal(minutes: N.c1MinDurationMinutes, steps: N.c1MaxSteps)
        XCTAssertEqual(outcome(signals, .c1).silentReason, "too many steps during the high stretch")
    }

    func testC1SilentInAWorkoutOrAsleep() {
        var signals = stressSignal(minutes: 90, steps: 0)
        signals.today.inWorkout = true
        XCTAssertEqual(outcome(signals, .c1).silentReason, "in a workout")
        signals.today.inWorkout = false
        signals.today.awake = false
        XCTAssertEqual(outcome(signals, .c1).silentReason, "asleep")
    }

    // MARK: E1 drifting sleep times

    private func driftSignal(driftingNights: Int) -> CoachSignals {
        var signals = morningSignal()
        signals.nights = (0..<N.e1WindowNights).map { index in
            let drift = index < driftingNights ? N.e1DriftHours * 60 + 30 : 0
            return CoachSignals.NightPoint(bedMinute: -60 + drift, wakeMinute: 420 + drift, sleepMinutes: 480)
        }
        return signals
    }

    func testE1FiresAtThreeDriftingNights() {
        let result = outcome(driftSignal(driftingNights: N.e1DriftNights), .e1)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.category, .insight)
    }

    func testE1SilentOneNightShort() {
        XCTAssertEqual(outcome(driftSignal(driftingNights: N.e1DriftNights - 1), .e1).silentReason, "only 2 drifted nights")
    }

    func testE1SilentWithoutAFullWeek() {
        var signals = driftSignal(driftingNights: 3)
        signals.nights = Array(signals.nights.prefix(N.e1WindowNights - 1))
        XCTAssertEqual(outcome(signals, .e1).silentReason, "fewer than 5 recorded nights")
    }

    // MARK: E2 improving

    private func trendSignal(improvementPercent: Double, daysAbove: Int) -> CoachSignals {
        var signals = morningSignal()
        let earlier = 5_000.0
        let window = N.e2WindowDays
        // Solve for the strong days so the two-week average lands exactly on the requested improvement.
        let weak = earlier * 0.95
        let target = earlier * (1 + improvementPercent / 100)
        let strongDays = N.e2MinDaysAbove
        let strong = (target * Double(window) - Double(window - strongDays) * weak) / Double(strongDays)
        var days: [CoachSignals.DayPoint] = (0..<window).map { index in
            CoachSignals.DayPoint(
                steps: index < daysAbove ? Int(strong) : Int(weak),
                sleepMinutes: 480,
                activeMinutes: 40,
                stepGoalMet: index < daysAbove
            )
        }
        days += (0..<window).map { _ in
            CoachSignals.DayPoint(steps: Int(earlier), sleepMinutes: 480, activeMinutes: 40, stepGoalMet: false)
        }
        signals.days = days
        return signals
    }

    func testE2FiresAtTenPercentAndTenDaysAbove() {
        let result = outcome(trendSignal(improvementPercent: Double(N.e2ImprovementPercent), daysAbove: N.e2MinDaysAbove), .e2)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.category, .celebration)
    }

    func testE2SilentOneDayBelowTheCount() {
        let signals = trendSignal(improvementPercent: Double(N.e2ImprovementPercent), daysAbove: N.e2MinDaysAbove - 1)
        XCTAssertEqual(outcome(signals, .e2).silentReason, "below 10%")
    }

    func testE2SilentOnePercentBelowTheImprovement() {
        let signals = trendSignal(improvementPercent: Double(N.e2ImprovementPercent) - 1, daysAbove: N.e2MinDaysAbove)
        XCTAssertEqual(outcome(signals, .e2).silentReason, "below 10%")
    }

    // MARK: F1 streak

    private func streakSignal(_ streak: Int) -> CoachSignals {
        var signals = activitySignal(steps: 10_000, hour: 20)
        signals.days = (0..<max(0, streak - 1)).map { _ in
            CoachSignals.DayPoint(steps: 10_000, sleepMinutes: 480, activeMinutes: 40, stepGoalMet: true)
        }
        return signals
    }

    func testF1FiresOnEveryListedMilestone() {
        let milestones = N.f1StreakDays.split(separator: ",").compactMap { Int($0) }
        for milestone in milestones {
            XCTAssertNotNil(outcome(streakSignal(milestone), .f1).nudge, "\(milestone)-day streak must fire")
        }
        XCTAssertNotNil(outcome(streakSignal(30 + N.f1RepeatEvery), .f1).nudge, "every 30 days after 30")
    }

    func testF1SilentOffMilestone() {
        XCTAssertEqual(outcome(streakSignal(4), .f1).silentReason, "4 is not a milestone")
    }

    // MARK: F2 weekly review

    private func reviewSignal(goodDays: Int) -> CoachSignals {
        var signals = morningSignal("2026-10-18T18:30:00Z", hour: 18, minute: 30)
        signals.days = (0..<7).map { index in
            CoachSignals.DayPoint(steps: index < goodDays ? 9_000 : 0, sleepMinutes: index < goodDays ? 470 : 0,
                                  activeMinutes: 30, stepGoalMet: index < goodDays)
        }
        return signals
    }

    func testF2FiresOnSundayAtTheReviewTimeWithFiveGoodDays() {
        let result = outcome(reviewSignal(goodDays: N.f2MinGoodDays), .f2)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.category, .insight)
    }

    func testF2SilentOneGoodDayShort() {
        XCTAssertEqual(outcome(reviewSignal(goodDays: N.f2MinGoodDays - 1), .f2).silentReason,
                       "fewer than 5 good days")
    }

    func testF2SilentOnAnotherDay() {
        var signals = reviewSignal(goodDays: 7)
        signals.now = at(hour: 18, minute: 30, on: "2026-10-19T07:30:00Z")
        XCTAssertEqual(outcome(signals, .f2).silentReason, "not the chosen day")
    }

    func testF2SilentBeforeTheReviewTime() {
        var signals = reviewSignal(goodDays: 7)
        signals.now = at(hour: 17, minute: 59, on: "2026-10-18T18:30:00Z")
        XCTAssertEqual(outcome(signals, .f2).silentReason, "before the weekly review time")
    }

    // MARK: G1 ring data missing

    private func ringSignal(hoursSinceSync: Double?, paired: Bool = true) -> CoachSignals {
        var signals = morningSignal()
        signals.ring = CoachSignals.Ring(
            paired: paired,
            name: "Agara Ring",
            lastSync: hoursSinceSync.map { signals.now.addingTimeInterval(-$0 * 3600) }
        )
        return signals
    }

    func testG1FiresAtTwentyFourHours() {
        let result = outcome(ringSignal(hoursSinceSync: Double(N.g1NoSyncHours)), .g1)
        XCTAssertNotNil(result.nudge)
        XCTAssertEqual(result.nudge?.buttons ?? [], [NudgeButton.openRing])
    }

    func testG1SilentOneHourShort() {
        XCTAssertEqual(outcome(ringSignal(hoursSinceSync: Double(N.g1NoSyncHours) - 1), .g1).silentReason,
                       "synced recently")
    }

    func testG1SilentWithoutAPairedRing() {
        XCTAssertEqual(outcome(ringSignal(hoursSinceSync: 48, paired: false), .g1).silentReason, "no ring paired")
    }

    // MARK: Wording

    /// Every variant of every rule renders with realistic numbers, and no `{slot}` survives.
    func testEveryVariantOfEveryRuleRendersWithoutAPlaceholder() {
        let slots = realisticSlots()
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "fr_FR")] {
            for rule in NudgeRule.allCases {
                for variant in NudgeTemplate.variants(for: rule) {
                    let rendered = NudgeTemplate.render(variant.text, slots: slots, locale: locale)
                    XCTAssertNotNil(rendered, "\(variant.id) has an unfilled slot")
                    XCTAssertFalse(rendered?.contains("{") ?? true, "\(variant.id) left a placeholder: \(rendered ?? "")")
                    XCTAssertFalse(rendered?.isEmpty ?? true)
                }
                XCTAssertNotNil(NudgeTemplate.render(NudgeTemplate.seed(for: rule), slots: slots, locale: locale),
                                "\(rule) seed has an unfilled slot")
            }
        }
    }

    func testPluralFormsFollowTheCount() {
        let one = NudgeTemplate.render(
            "{steps_left} steps to go",
            slots: [.stepsLeft: .count(1, unit: .step)],
            locale: Locale(identifier: "en_US")
        )
        let many = NudgeTemplate.render(
            "{steps_left} steps to go",
            slots: [.stepsLeft: .count(2_400, unit: .step)],
            locale: Locale(identifier: "en_US")
        )
        XCTAssertEqual(one, "1 step to go")
        XCTAssertEqual(many, "2,400 steps to go")
    }

    func testDurationsArePluralizedAndLocalized() {
        let hour = NudgeTemplate.render(
            "You slept {sleep_total}.",
            slots: [.sleepTotal: .duration(minutes: 60)],
            locale: Locale(identifier: "en_US")
        )
        let hours = NudgeTemplate.render(
            "You slept {sleep_total}.",
            slots: [.sleepTotal: .duration(minutes: 120)],
            locale: Locale(identifier: "en_US")
        )
        let french = NudgeTemplate.render(
            "Vous avez dormi {sleep_total}.",
            slots: [.sleepTotal: .duration(minutes: 120)],
            locale: Locale(identifier: "fr_FR")
        )
        XCTAssertEqual(hour, "You slept 1h.")
        XCTAssertEqual(hours, "You slept 2h.")
        XCTAssertTrue(french?.contains("2") ?? false, "French abbreviation expected, got \(french ?? "nil")")
    }

    func testMissingSlotMakesAWordingIneligible() {
        XCTAssertNil(NudgeTemplate.render("{steps_left} steps", slots: [:], locale: Locale(identifier: "en_US")))
    }

    func testRotationSkipsWordingsShownInTheLastWeek() {
        let slots = realisticSlots()
        let now = date("2026-10-20T07:30:00Z")
        let first = NudgeTemplate.rotation(for: .a1, slots: slots, lastUsed: [:], now: now)!
        let second = NudgeTemplate.rotation(
            for: .a1, slots: slots, lastUsed: [first.id: now.addingTimeInterval(-86_400)], now: now
        )!
        XCTAssertNotEqual(first.id, second.id, "a different wording must rotate in")
        let allUsed = Dictionary(uniqueKeysWithValues: NudgeTemplate.variants(for: .a1).map { ($0.id, now) })
        XCTAssertNotNil(NudgeTemplate.rotation(for: .a1, slots: slots, lastUsed: allUsed, now: now))
    }

    private func realisticSlots() -> [NudgeSlot: NudgeSlotValue] {
        [
            .stepsLeft: .count(2_400, unit: .step),
            .stepsDone: .count(7_600, unit: .step),
            .goalSteps: .count(10_000, unit: .step),
            .walkMin: .number(24),
            .sleepShort: .duration(minutes: 135),
            .sleepTotal: .duration(minutes: 375),
            .sleepGoal: .duration(minutes: 480),
            .rhrDelta: .percent(12),
            .stressMinutes: .count(75, unit: .minute),
            .streakDays: .number(7),
            .driftMinutes: .count(185, unit: .minute),
            .medianBedtime: .timeOfDay(-60),
            .medianWake: .timeOfDay(420),
            .pctAbove: .percent(14),
            .bestWin: .text("9,400 steps"),
            .weekDays: .count(5, unit: .day),
            .hoursSinceSync: .count(27, unit: .hour),
            .ringName: .text("Agara Ring"),
            .percent: .percent(20)
        ]
    }
}
