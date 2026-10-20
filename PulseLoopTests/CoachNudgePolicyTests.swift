import XCTest
@testable import PulseLoop

/// Drives `CoachNudgePolicy` from `docs/config/coach_nudges_cases.json`: each case is a pure input → expected
/// output (emitted ids in order, silent reasons, push count). The fixture lives next to the tests so the cases
/// travel with the code; the workspace catalog is the same file.
final class CoachNudgePolicyTests: XCTestCase {

    // MARK: Fixture

    private struct CaseFile: Decodable {
        var version: Int
        var cases: [Case]
    }

    private struct Case: Decodable {
        struct Expectations: Decodable {
            var emit: [String]
            var silent: [String: String]?
            var push_count: Int
        }
        struct Settings: Decodable {
            var daily_limit: Int?
            var celebration_extra: Bool?
            var quiet_start: String?
            var quiet_end: String?
            var disabled_topics: [String]?
            var step_reminders: Bool?
            var weekly_review_day: String?
            var weekly_review_time: String?
            /// Defaults to Sunday 18:00 when the case does not name it.
        }
        struct Signals: Decodable {
            var rhr_delta_percent: Double?
            var sleep_under_goal_hours: Double?
            var sleep_total_hours: Double?
            var sleep_goal_hours: Double?
            var night_data_percent: Double?
            var baseline_nights: Int?
            var evening_stress_above_normal: Bool?
            /// The canonical catalog's spelling of the same fact (`docs/config/coach_nudges_cases.json` was written by a
            /// second agent in parallel). Both are accepted so neither vocabulary has to be rewritten by hand.
            var stress_evening_above_normal: Bool?
            var evening_stress: Double?
            var baseline_evening_stress: Double?
            var steps_today: Int?
            var day_data_percent: Double?
            var step_goal: Int?
            var goal_override_percent: Int?
            var awake: Bool?
            var in_workout: Bool?
            var minutes_since_active_block: Int?
            var stress_high_minutes: Int?
            var stress_high_steps: Int?
            /// Catalog spelling for the steps taken during the high-stress stretch.
            var steps_during_stress: Int?
            /// Catalog spelling for the peak stress reading in that stretch.
            var stress_score_now: Int?
            var streak_days: Int?
            var drift_nights: Int?
            /// The canonical catalog's spelling of the same fact (`docs/config/coach_nudges_cases.json`).
            var drift_nights_last_7: Int?
            var nights_recorded_last_7: Int?
            var drift_minutes: Int?
            var improvement_percent: Double?
            /// Which metric improved: steps | sleep | active_minutes (E2 is per metric).
            var improvement_metric: String?
            var days_above: Int?
            /// The canonical catalog's spelling of the same fact.
            var days_above_previous: Int?
            var good_days: Int?
            var good_days_last_7: Int?
            var ring_paired: Bool?
            var sync_hours_ago: Double?
            var hours_since_sync: Double?
            /// Quiet hours appear under `signals` in the canonical catalog and under `settings` in the fixture's own
            /// cases; both are the user's setting, which is why they are applied to `NudgeSettings` either way.
            var quiet_start: String?
            var quiet_end: String?
        }
        struct LedgerInput: Decodable {
            struct Sent: Decodable {
                var nudge: String
                var at: String
                var severity: Double?
            }
            var sent_today: [Sent]?
            var fingerprints_today: [String]?
            var routine_pushes_today: Int?
            var category_dismissals_7d: [String: Int]?
            var category_last_sent: [String: String]?
            var category_last_severity: [String: Double]?
            var snoozed_until: [String: String]?
            var notifications_enabled: Bool?
            /// Celebration pushes already shown today (`b4`, `e2`, `f1`): the policy's once-a-day gate for them.
            var celebration_sent_today: [String]?
            /// The user's chosen routine limit, and whether celebrations get their own push.
            var daily_limit: Int?
            var celebration_extra: String?
            /// `["22:00", "08:00"]`: the same two bounds the settings carry.
            var quiet_hours: [String]?
            /// E2's per-metric cooldown: metric -> when it was last celebrated.
            var metric_celebrated: [String: String]?
        }
        var id: String
        var why: String?
        var now: String
        var signals: Signals
        var settings: Settings?
        var ledger: LedgerInput?
        var expect: Expectations
    }

    private func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coach_nudges_cases.json")
        return try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: url)).cases
    }

    /// The fixture states wall-clock times ("2026-10-20T21:30:00Z") and the rules compare local minutes of the day,
    /// so the fixture's clock reading is anchored in the device's own timezone: the case says 21:30, the test sees 21:30.
    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: iso) else {
            fatalError("bad ISO-8601 date in a policy case: \(iso)")
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        return Calendar.current.date(from: components)!
    }

    // MARK: Signals from a case

    private func signals(from input: Case.Signals, now: Date) -> CoachSignals {
        typealias N = AgaraConfig.Nudges
        var signals = CoachSignals(now: now)
        let sleepGoalMinutes = (input.sleep_goal_hours ?? 8) * 60
        let baselineStress = input.baseline_evening_stress ?? 30
        let aboveNormal = input.evening_stress_above_normal ?? input.stress_evening_above_normal
        let eveningStress = input.evening_stress
            ?? (aboveNormal == true ? baselineStress + 10 : baselineStress)
        let baselineRHR = 60.0
        let rhrDelta = input.rhr_delta_percent ?? 3   // unremarkable, neither above baseline nor perfect
        let underGoal = input.sleep_under_goal_hours ?? 1.2   // 85% of goal: not "good to go" by default
        let total = input.sleep_total_hours.map { $0 * 60 } ?? (sleepGoalMinutes - underGoal * 60)

        signals.baseline = CoachSignals.Baseline(
            nightsRecorded: input.baseline_nights ?? 21,
            sleepMinutes: sleepGoalMinutes,
            bedMinute: -60,
            wakeMinute: 420,
            restingHeartRate: baselineRHR,
            eveningStress: baselineStress,
            stressPercentile: 70
        )
        signals.lastNight = CoachSignals.Night(
            totalMinutes: total,
            asleepMinutes: total,
            dataPercent: input.night_data_percent ?? 95,
            restingHeartRate: baselineRHR * (1 + rhrDelta / 100),
            bedMinute: -60,
            wakeMinute: 420,
            eveningStress: eveningStress
        )
        signals.goals = CoachSignals.Goals(
            steps: input.step_goal ?? 10_000,
            sleepMinutes: sleepGoalMinutes,
            stepGoalLowerPercent: input.goal_override_percent ?? 0
        )

        let minuteOfDay = CoachSignals.minuteOfDay(now)
        let moved = input.minutes_since_active_block ?? 30
        let blocks = [CoachSignals.StepBlock(
            startMinute: max(0, minuteOfDay - moved - N.b3BlockMinutes),
            steps: N.b3BlockSteps
        )]
        signals.today = CoachSignals.Today(
            steps: input.steps_today ?? 0,
            blocks: blocks,
            inWorkout: input.in_workout ?? false,
            awake: input.awake ?? true,
            dataPercent: input.day_data_percent ?? (input.steps_today == nil ? 0 : 100),
            activeMinutes: 0
        )

        if let minutes = input.stress_high_minutes {
            signals.stressRun = CoachSignals.StressRun(minutes: minutes, steps: input.stress_high_steps ?? input.steps_during_stress ?? 0, score: input.stress_score_now ?? 75)
        }

        if let drifting = input.drift_nights_last_7 ?? input.drift_nights {
            let defaultDrift = N.e1DriftHours * 60 + 30
            let drift: Int = input.drift_minutes ?? defaultDrift
            // A case may record fewer nights than the window: only those nights exist to judge.
            let window: Int = min(N.e1WindowNights, input.nights_recorded_last_7 ?? N.e1WindowNights)
            var nights: [CoachSignals.NightPoint] = []
            for index in 0..<window {
                let offset: Int = index < drifting ? drift : 0
                let bed: Int = -60 + offset
                let wake: Int = 420 + offset
                nights.append(CoachSignals.NightPoint(bedMinute: bed, wakeMinute: wake, sleepMinutes: sleepGoalMinutes))
            }
            signals.nights = nights
        }

        if let streak = input.streak_days {
            signals.days = (0..<max(0, streak - 1)).map { _ in
                CoachSignals.DayPoint(steps: 10_200, sleepMinutes: 480, activeMinutes: 40, stepGoalMet: true)
            }
        }

        if let goodDays = input.good_days_last_7 ?? input.good_days {
            signals.days = (0..<N.e1WindowNights).map { index in
                CoachSignals.DayPoint(
                    steps: index < goodDays ? 9_400 : 0,
                    sleepMinutes: index < goodDays ? 470 : 0,
                    activeMinutes: 30,
                    stepGoalMet: index < goodDays
                )
            }
        }

        if let improvement = input.improvement_percent {
            // The window average must land on the stated improvement while `days_above` days sit above the earlier
            // average: solve for the strong days, the weak ones stay just under it.
            let earlier = 5_000.0
            let above = input.days_above_previous ?? input.days_above ?? N.e2MinDaysAbove
            let window = N.e2WindowDays
            let weak = earlier * 0.95
            let target = earlier * (1 + improvement / 100)
            let strong = Int((target * Double(window) - Double(window - above) * weak) / Double(max(1, above)))
            let metric = input.improvement_metric ?? "steps"
            signals.days = (0..<window).map { index in
                let strongDay = index < above
                return CoachSignals.DayPoint(
                    steps: metric == "steps" && strongDay ? strong : (metric == "steps" ? Int(earlier * 0.95) : 5_000),
                    sleepMinutes: metric == "sleep" ? (strongDay ? 540 : 400) : 480,
                    activeMinutes: metric == "active_minutes" ? (strongDay ? 60 : 25) : 40,
                    stepGoalMet: index < above
                )
            } + (0..<window).map { _ in
                CoachSignals.DayPoint(steps: Int(earlier), sleepMinutes: 480, activeMinutes: 40, stepGoalMet: false)
            }
        }

        signals.ring = CoachSignals.Ring(
            paired: input.ring_paired ?? false,
            name: "Agara Ring",
            lastSync: (input.hours_since_sync ?? input.sync_hours_ago).map {
                now.addingTimeInterval(-$0 * 3600)
            }
        )
        return signals
    }

    // MARK: Ledger from a case

    private func ledger(from input: Case.LedgerInput?, now: Date) -> NudgeLedger {
        var ledger = NudgeLedger()
        guard let input else { return ledger }
        // Absent means "notifications are on": most cases are about the policy's other clauses.
        ledger.notificationsEnabled = input.notifications_enabled ?? true
        for entry in input.sent_today ?? [] {
            guard let rule = NudgeRule(rawValue: entry.nudge) else { continue }
            ledger.sent.append(NudgeLedger.Sent(
                rule: rule,
                category: rule.category,
                at: date(entry.at),
                fingerprint: "\(rule.rawValue):\(entry.severity ?? 0)",
                delivery: rule.delivery,
                severity: entry.severity ?? .greatestFiniteMagnitude,
                templateID: "\(rule.rawValue)_v1"
            ))
        }
        // A celebration that already went out today is a push of a celebration rule: the once-a-day gate and the
        // daily budget both read it from the delivered rows.
        for raw in input.celebration_sent_today ?? [] {
            guard let rule = NudgeRule(rawValue: raw) else { continue }
            ledger.sent.append(NudgeLedger.Sent(
                rule: rule,
                category: rule.category,
                at: now.addingTimeInterval(-3600),
                fingerprint: "\(rule.rawValue):0",
                delivery: .push,
                severity: 0,
                templateID: "\(rule.rawValue)_v1"
            ))
        }
        for fingerprint in input.fingerprints_today ?? [] {
            guard let rule = NudgeRule(rawValue: String(fingerprint.split(separator: ":").first ?? "")) else { continue }
            ledger.sent.append(NudgeLedger.Sent(
                rule: rule,
                category: rule.category,
                at: now.addingTimeInterval(-3600),
                fingerprint: fingerprint,
                delivery: rule.delivery,
                severity: .greatestFiniteMagnitude,
                templateID: "\(rule.rawValue)_v1"
            ))
        }
        ledger.routinePushesToday = input.routine_pushes_today ?? 0
        for (raw, count) in input.category_dismissals_7d ?? [:] {
            guard let category = NudgeCategory(rawValue: raw) else { continue }
            ledger.dismissed += (0..<count).map {
                NudgeLedger.Dismissal(category: category, at: now.addingTimeInterval(-Double($0 + 1) * 3600))
            }
        }
        for (raw, iso) in input.category_last_sent ?? [:] {
            guard let category = NudgeCategory(rawValue: raw),
                  let rule = NudgeRule.allCases.first(where: { $0.category == category })
            else { continue }
            // Skip when sent_today already describes this delivery: one delivery, one row.
            if ledger.sent.contains(where: { $0.category == category && abs($0.at.timeIntervalSince(date(iso))) < 60 }) {
                continue
            }
            ledger.sent.append(NudgeLedger.Sent(
                rule: rule,
                category: category,
                at: date(iso),
                fingerprint: "\(rule.rawValue):0",
                delivery: rule.delivery,
                severity: input.category_last_severity?[raw] ?? .greatestFiniteMagnitude,
                templateID: "\(rule.rawValue)_v1"
            ))
        }
        for (raw, iso) in input.metric_celebrated ?? [:] {
            ledger.metricCelebrated[raw] = date(iso)
        }
        for (raw, iso) in input.snoozed_until ?? [:] {
            guard let category = NudgeCategory(rawValue: raw) else { continue }
            ledger.snoozedUntil[category] = date(iso)
        }
        return ledger
    }

    /// The settings a case states. The canonical catalog puts quiet hours under `signals` and the routine limit and
    /// celebration toggle under `ledger`; the fixture's own cases put them in `settings`. All three are the user's
    /// setting, so they are read from wherever the case states them.
    private func settings(from testCase: Case) -> NudgeSettings {
        var settings = NudgeSettings.standard
        let input = testCase.settings
        let quiet = testCase.ledger?.quiet_hours ?? []
        settings.dailyLimit = input?.daily_limit ?? testCase.ledger?.daily_limit ?? settings.dailyLimit
        let celebrationFlag = input?.celebration_extra ?? (testCase.ledger?.celebration_extra.map { $0 == "on" })
        if let celebrationFlag { settings.celebrationExtra = celebrationFlag }
        settings.disabledTopics = Set((input?.disabled_topics ?? []).compactMap(NudgeCategory.init(rawValue:)))
        settings.stepReminders = input?.step_reminders ?? settings.stepReminders
        if input?.quiet_start == nil, testCase.signals.quiet_start != nil {
            settings.quietMode = .followSleep
        }
        let quietStart = input?.quiet_start ?? testCase.signals.quiet_start ?? (quiet.count > 0 ? quiet[0] : nil)
        let quietEnd = input?.quiet_end ?? testCase.signals.quiet_end ?? (quiet.count > 1 ? quiet[1] : nil)
        settings.quietStart = quietStart.flatMap(CoachSignals.minuteOfDay) ?? settings.quietStart
        settings.quietEnd = quietEnd.flatMap(CoachSignals.minuteOfDay) ?? settings.quietEnd
        settings.weeklyReviewWeekday = input?.weekly_review_day.flatMap(NudgeSettings.weekday) ?? settings.weeklyReviewWeekday
        settings.weeklyReviewMinute = input?.weekly_review_time.flatMap(CoachSignals.minuteOfDay) ?? settings.weeklyReviewMinute
        return settings
    }

    // MARK: The cases

    func testPolicyCases() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 50, "the policy fixture must cover all ten policy rules")

        var failures: [String] = []
        for testCase in cases {
            let now = date(testCase.now)
            let signals = signals(from: testCase.signals, now: now)
            let settings = settings(from: testCase)
            let ledger = ledger(from: testCase.ledger, now: now)
            let outcomes = NudgeRules.evaluate(signals, settings: settings, now: now)
            let plan = CoachNudgePolicy.decide(
                candidates: outcomes,
                ledger: ledger,
                now: now,
                settings: settings,
                signals: signals,
                calendar: Calendar.current
            )

            let emitted = plan.rules.map(\.rawValue)
            if emitted != testCase.expect.emit {
                failures.append("\(testCase.id): emitted \(emitted), expected \(testCase.expect.emit)")
            }
            for (rule, reason) in testCase.expect.silent ?? [:] {
                // The catalog distinguishes WHICH sink was silenced ("a1_push": the push was sunk, the card still
                // shows) because that is what the user sees; the policy records the rule and its one reason. Compare
                // on the rule, so both vocabularies describe the same behaviour instead of one rewriting 92 cases.
                let key = NudgeRule(rawValue: rule)
                    ?? NudgeRule(rawValue: rule.replacingOccurrences(of: "_push", with: "")
                        .replacingOccurrences(of: "_card", with: ""))
                guard let key else {
                    failures.append("\(testCase.id): silent[\(rule)] is not a rule or a sink key")
                    continue
                }
                // A "_push" key means the PUSH was sunk while the card may still show (notifications off, quiet hours,
                // the daily limit); a "_card" key means the nudge itself produced nothing. Compare against what the plan
                // actually delivers, so "notifications off" is proven by the absence of a push rather than by a label.
                if rule.hasSuffix("_push") {
                    let pushed = plan.delivered.contains { $0.rule == key && $0.delivery == .push }
                    if pushed { failures.append("\(testCase.id): \(key.rawValue) was pushed, expected: \(reason)") }
                } else if rule.hasSuffix("_card") {
                    let shown = plan.delivered.contains { $0.rule == key }
                    if shown { failures.append("\(testCase.id): \(key.rawValue) was delivered, expected: \(reason)") }
                } else {
                    let actual = plan.silent[key]
                    if actual != reason {
                        failures.append("\(testCase.id): silent[\(rule)] = \(actual ?? "nil"), expected \(reason)")
                    }
                }
            }
            if plan.pushCount != testCase.expect.push_count {
                failures.append("\(testCase.id): push_count \(plan.pushCount), expected \(testCase.expect.push_count)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Rule 2 of the policy, checked directly: a lower-priority category never overtakes a higher one.
    func testPriorityOrderComesFromTheCatalog() {
        XCTAssertEqual(CoachNudgePolicy.priority.first, .recovery)
        XCTAssertEqual(CoachNudgePolicy.priority.last, .insight)
        XCTAssertEqual(
            CoachNudgePolicy.priority,
            AgaraConfig.Nudges.policyPriorityOrder.split(separator: ",").compactMap { NudgeCategory(rawValue: String($0)) }
        )
    }

    /// Rule 9's ladder: 3 dismissals double the gap, 6 double it again, and it stops at the last step.
    func testLearningLadderDoublesTheCategoryGap() {
        let now = Date()
        func gap(_ dismissals: Int) -> Double {
            var ledger = NudgeLedger()
            ledger.dismissed = (0..<dismissals).map { _ in .init(category: .activity, at: now.addingTimeInterval(-3600)) }
            return CoachNudgePolicy.categoryGap(.activity, ledger: ledger, now: now) / 3600
        }
        let base = gap(0)
        let step = AgaraConfig.Nudges.policyDismissalsToDouble
        XCTAssertEqual(gap(step - 1), base)
        XCTAssertEqual(gap(step), base * 2)
        XCTAssertEqual(gap(step * 2), base * 4)
        XCTAssertEqual(gap(step * 3), base * 4, "the ladder is capped at its last value")
    }
}
