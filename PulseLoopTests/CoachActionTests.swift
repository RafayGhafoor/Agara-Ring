import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

@MainActor
final class CoachActionTests: XCTestCase {

    private func writeFlags() -> CoachFeatureFlags {
        var s = CoachSettings.default
        s.enableWriteTools = true
        return CoachFeatureFlags(settings: s, hasAPIKey: true)
    }

    private func ctx(_ c: ModelContext) -> ToolExecutionContext {
        ToolExecutionContext(modelContext: c, flags: writeFlags())
    }

    private func tool(_ name: String, _ c: ModelContext) throws -> AnyCoachTool {
        try XCTUnwrap(ToolRegistry(flags: writeFlags()).tool(named: name))
    }

    private func parse(_ result: ToolResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any])
    }

    // MARK: set_goal

    func testSetGoalUpdatesUserGoal() async throws {
        let c = try TestSupport.makeContext()
        let result = try await tool("set_goal", c).run(Data(#"{"goal_type":"steps","target":12000,"reason":"more active"}"#.utf8), ctx(c))
        XCTAssertEqual((try parse(result))["ok"] as? Bool, true)
        let goal = try XCTUnwrap(MetricsRepository.goals(context: c))
        XCTAssertEqual(goal.steps, 12000)
    }

    // MARK: create session

    func testCreateSessionNeedsDurationThenCreates() async throws {
        let c = try TestSupport.makeContext()
        let t = try tool("create_activity_session_from_description", c)

        let noDur = try await t.run(Data(#"{"activity_type":"run","date":"2026-06-01","start_time":null,"duration_min":null,"distance_km":null,"notes":"","confidence":"medium"}"#.utf8), ctx(c))
        XCTAssertEqual((try parse(noDur))["needs_follow_up"] as? Bool, true)
        XCTAssertTrue(ActivityRepository.sessions(context: c).isEmpty)

        let created = try await t.run(Data(#"{"activity_type":"run","date":"2026-06-01","start_time":null,"duration_min":30,"distance_km":5,"notes":"morning","confidence":"high"}"#.utf8), ctx(c))
        XCTAssertEqual((try parse(created))["created"] as? Bool, true)
        let sessions = ActivityRepository.sessions(context: c)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.type, "run")
    }

    func testCreateSessionAcceptsOmittedMetadataAndTwelveHourTime() async throws {
        let c = try TestSupport.makeContext()
        let t = try tool("create_activity_session_from_description", c)
        let args = #"{"activity_type":"run","date":"2026-06-01","start_time":"7:00 PM","duration_min":20}"#

        let result = try await t.run(Data(args.utf8), ctx(c))

        XCTAssertEqual((try parse(result))["created"] as? Bool, true)
        let session = try XCTUnwrap(ActivityRepository.sessions(context: c).first)
        XCTAssertEqual(Calendar.current.component(.hour, from: session.startedAt), 19)
        XCTAssertNil(session.notes, "the activity service normalizes an omitted note to nil")
    }

    // MARK: log_user_note → typed memory

    func testLogUserNoteWritesTypedMemory() async throws {
        let c = try TestSupport.makeContext()
        _ = try await tool("log_user_note", c).run(Data(#"{"date":"2026-06-01","note_type":"symptom","content":"felt dizzy after lunch"}"#.utf8), ctx(c))
        let mems = (try? c.fetch(FetchDescriptor<CoachMemory>())) ?? []
        XCTAssertEqual(mems.count, 1)
        XCTAssertEqual(mems.first?.memoryType, "health_note")
        XCTAssertEqual(mems.first?.value, "felt dizzy after lunch")
    }

    // MARK: delete → confirmation card (no immediate delete)

    func testDeleteReturnsConfirmationAndExecutorDeletes() async throws {
        let c = try TestSupport.makeContext()
        let session = ActivitySession(type: "run", status: .finished, startedAt: TestSupport.day(-2), endedAt: TestSupport.day(-2))
        c.insert(session)
        try c.save()

        let context = ctx(c)
        let result = try await tool("delete_activity_session", c).run(Data(#"{"activity_id":"\#(session.id.uuidString)","reason":"duplicate"}"#.utf8), context)
        XCTAssertEqual((try parse(result))["needs_confirmation"] as? Bool, true)
        XCTAssertEqual(context.pendingActions.count, 1)
        // NOT deleted yet.
        XCTAssertEqual(ActivityRepository.sessions(context: c).count, 1)

        // Confirm → executor deletes.
        let action = try XCTUnwrap(context.pendingActions.first)
        _ = PendingActionExecutor.execute(action, context: c)
        XCTAssertTrue(ActivityRepository.sessions(context: c).isEmpty)
    }

    func testUpdateOldSessionRequiresConfirmation() async throws {
        let c = try TestSupport.makeContext()
        let session = ActivitySession(type: "run", status: .finished, startedAt: TestSupport.day(-5), endedAt: TestSupport.day(-5))
        c.insert(session)
        try c.save()
        let context = ctx(c)
        let json = #"{"activity_id":"\#(session.id.uuidString)","type":"cycle","notes":null,"distance_km":null,"duration_min":null,"perceived_effort":null,"start_time":null,"reason":"misclassified"}"#
        let result = try await tool("update_activity_session", c).run(Data(json.utf8), context)
        XCTAssertEqual((try parse(result))["needs_confirmation"] as? Bool, true)
        XCTAssertEqual(context.pendingActions.first?.kind, .updateActivitySession)
        XCTAssertEqual(session.type, "run")  // unchanged until confirmed
    }

    // MARK: gating

    func testWriteToolsHiddenWhenDisabled() {
        let readOnly = CoachFeatureFlags(settings: .default, hasAPIKey: true)  // writes off
        let names = Set(ToolRegistry(flags: readOnly).toolSpecs.compactMap { $0["name"] as? String })
        XCTAssertFalse(names.contains("set_goal"))
        XCTAssertFalse(names.contains("delete_activity_session"))
        XCTAssertFalse(names.contains("trigger_measurement"))
    }

    func testWriteToolsPresentWhenEnabled() {
        let names = Set(ToolRegistry(flags: writeFlags()).toolSpecs.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("set_goal"))
        XCTAssertTrue(names.contains("save_memory"))
        XCTAssertTrue(names.contains("delete_activity_session"))
        XCTAssertFalse(names.contains("trigger_measurement"))  // live still off
    }

    // MARK: memory retrieval (drop expired, rank by importance)

    func testContextMemoriesDropExpiredAndRankByImportance() throws {
        let c = try TestSupport.makeContext()
        c.insert(CoachMemory(key: "low", value: "v", memoryType: "note", importance: 1))
        c.insert(CoachMemory(key: "top", value: "v", memoryType: "goal", importance: 5))
        c.insert(CoachMemory(key: "gone", value: "v", memoryType: "note", importance: 4,
                             expiresAt: Date().addingTimeInterval(-3600)))
        try c.save()

        let packet = CoachContextBuilder.build(context: c)
        let keys = packet.memories.map(\.key)
        XCTAssertFalse(keys.contains("gone"))      // expired dropped
        XCTAssertEqual(keys.first, "top")          // importance-ranked
    }
}

@MainActor
final class CoachChartDomainTests: XCTestCase {
    func testTrendLineAutoscalesAwayFromZero() {
        let d = CoachChartView.yDomain(values: [70, 72, 75, 71], chartType: .line, metric: .hr)
        XCTAssertGreaterThan(d.lowerBound, 50)  // not anchored at 0
        XCTAssertLessThan(d.lowerBound, 70)
        XCTAssertGreaterThan(d.upperBound, 75)
    }

    func testMagnitudeBarStartsAtZero() {
        let d = CoachChartView.yDomain(values: [4000, 8000, 12000], chartType: .bar, metric: .steps)
        XCTAssertEqual(d.lowerBound, 0)
        XCTAssertGreaterThan(d.upperBound, 12000)
    }

    func testSpO2ClampedTo100() {
        let d = CoachChartView.yDomain(values: [96, 98, 99], chartType: .dot, metric: .spo2)
        XCTAssertLessThanOrEqual(d.upperBound, 100)
        XCTAssertLessThan(d.lowerBound, 96)
    }

    /// Model output is untrusted: negative magnitudes, NaN/∞ and out-of-range SpO₂ must not trap.
    func testHostileValuesNeverBuildAnInvalidRange() {
        let cases: [([Double], CoachChartType, CoachChartMetric)] = [
            ([-200, -100], .bar, .calories), ([-5], .bar, .steps), ([-3, -3], .bar, .sleep),
            ([.nan, 70], .line, .hr), ([.infinity], .dot, .hr), ([.nan], .bar, .steps),
            ([150, 160], .dot, .spo2), ([100], .line, .spo2), ([-1, 4], .bar, .distance),
        ]
        for (values, type, metric) in cases {
            let d = CoachChartView.yDomain(values: values, chartType: type, metric: metric)
            XCTAssertTrue(d.lowerBound.isFinite && d.upperBound.isFinite, "\(values)")
            XCTAssertLessThan(d.lowerBound, d.upperBound, "\(values)")
            for v in values where v.isFinite && metric != .spo2 {
                XCTAssertTrue(d.contains(v), "\(v) outside \(d)")
            }
        }
    }
}

/// The coach chart's labels: model output carries ISO dates and sleep arrives in minutes, and both used to reach the
/// screen raw ("2026-10-13" under a bar, "350 … 425" on a sleep axis).
final class CoachChartLabelTests: XCTestCase {
    private let en = Locale(identifier: "en_US_POSIX")

    func testSleepAxisReadsInHours() {
        XCTAssertEqual(CoachChartView.yAxisLabel(480, metric: .sleep), "8h")
        XCTAssertEqual(CoachChartView.yAxisLabel(450, metric: .sleep), "7.5h")
        XCTAssertEqual(CoachChartView.yAxisLabel(0, metric: .sleep), "0h")
    }

    func testStepsAxisIsCompact() {
        XCTAssertEqual(CoachChartView.yAxisLabel(12000, metric: .steps), "12k")
        XCTAssertEqual(CoachChartView.yAxisLabel(800, metric: .steps), "800")
    }

    func testSleepGridIsHourlyWhenNarrowAndTwoHourlyWhenWide() {
        XCTAssertEqual(CoachChartView.sleepGridStep(domain: 340...500), 60)
        XCTAssertEqual(CoachChartView.sleepGridStep(domain: 0...562), 120)
    }

    func testAWeekOfDatesReadsAsWeekdays() {
        XCTAssertEqual(CoachChartView.xAxisLabel("2026-10-16", pointCount: 7, locale: en), "Fri")
    }

    func testALongerRangeReadsAsDayAndMonth() {
        XCTAssertEqual(CoachChartView.xAxisLabel("2026-10-16", pointCount: 14, locale: en), "Oct 16")
    }

    func testNonDateLabelsPassThrough() {
        XCTAssertEqual(CoachChartView.xAxisLabel("22:00", pointCount: 7, locale: en), "22:00")
        XCTAssertEqual(CoachChartView.xDetailLabel("deep", locale: en), "deep")
    }

    func testTooltipNamesTheDay() {
        XCTAssertEqual(CoachChartView.xDetailLabel("2026-10-16", locale: en), "Fri, Oct 16")
    }
}

final class CoachTextTests: XCTestCase {
    private let nb = "\u{00A0}"

    func testCompoundDurationNeverBreaks() {
        XCTAssertEqual(CoachText.keepUnitsTogether("at 5 h 56 m, and"), "at 5\(nb)h\(nb)56\(nb)m, and")
    }

    func testUnitsStayWithTheirNumbers() {
        XCTAssertEqual(CoachText.keepUnitsTogether("49 min under, 62 bpm, 98 %"), "49\(nb)min under, 62\(nb)bpm, 98\(nb)%")
    }

    func testWordsThatStartLikeUnitsAreLeftAlone() {
        XCTAssertEqual(CoachText.keepUnitsTogether("3 more nights"), "3 more nights")
        XCTAssertEqual(CoachText.keepUnitsTogether("2 hours"), "2 hours")
    }
}

/// A nudge's title is its first sentence; it is the push's bold line and the Settings ledger's label.
final class NudgeTitleTests: XCTestCase {
    func testAThousandsSeparatorIsNotTheEndOfASentence() {
        XCTAssertEqual(CoachNudge.title(from: "2.400 steps to go today. A 20-minute walk would close it."),
                       "2.400 steps to go today.")
    }

    func testADecimalIsNotTheEndOfASentence() {
        XCTAssertEqual(CoachNudge.title(from: "You covered 1.5 km more than last week! Nice."),
                       "You covered 1.5 km more than last week!")
    }

    func testASingleSentenceIsItsOwnTitle() {
        XCTAssertEqual(CoachNudge.title(from: "7 days in a row on your step goal."), "7 days in a row on your step goal.")
    }

    func testNoTerminatorReturnsTheWholeText() {
        XCTAssertEqual(CoachNudge.title(from: "No data from Agara Ring for 26 hours"), "No data from Agara Ring for 26 hours")
    }
}

/// Found by wiring the engine to the demo store (2026-10-22): signals and evidence that the rule cases never exercised.
final class NudgeLiveDataTests: XCTestCase {
    func testBedtimesAreComparedAcrossMidnight() {
        XCTAssertEqual(CoachSignalsBuilder.centeredBedMinute(23 * 60), -60)
        XCTAssertEqual(CoachSignalsBuilder.centeredBedMinute(30), 30)
        XCTAssertEqual(CoachSignalsBuilder.centeredBedMinute(-65), -65)
        // 23:00 and 00:30 are 90 minutes apart, not 22.5 hours.
        XCTAssertEqual(abs(CoachSignalsBuilder.centeredBedMinute(23 * 60) - CoachSignalsBuilder.centeredBedMinute(30)), 90)
    }

    func testAUsualBedtimeReadsAsAClockTime() {
        let evening = CoachNudgeEvidence(metric: "median_bedtime_minute", value: -65, unit: "min_of_day")
        // Apple writes a narrow no-break space before "PM" (U+202F) — correct typography, so normalise it here.
        let text = NudgeFact.format(evening, locale: Locale(identifier: "en_US_POSIX")).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(text, "10:55 PM")
    }

    /// The judged night must not sit inside the median it is judged against (spec: "excluding the night being
    /// judged"). Eight nights with the newest deliberately extreme: the baseline is the seven earlier ones.
    @MainActor
    func testTheBaselineExcludesTheNightBeingJudged() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 20)))

        // Oldest first; each ends on a different waking day, so `SleepDayRule` keeps them apart.
        let durations = [400, 410, 420, 430, 440, 450, 460, 900]
        for (index, minutes) in durations.enumerated() {
            let wake = try XCTUnwrap(calendar.date(byAdding: .day,
                                                   value: -(durations.count - 1 - index), to: now))
            let start = wake.addingTimeInterval(-Double(minutes) * 60)
            let session = SleepSession(date: start, startAt: start, endAt: wake, totalMinutes: minutes)
            context.insert(session)
            // Full coverage: the 80 % data gate must not be what silences this test.
            context.insert(SleepStageBlock(sessionId: session.id, startAt: start, startMinute: 0,
                                           durationMinutes: minutes, stage: .light))
        }
        try context.save()

        let signals = CoachSignalsBuilder.build(context: context, now: now)

        XCTAssertEqual(signals.lastNight?.totalMinutes, 900, "the newest night is the one being judged")
        XCTAssertEqual(signals.baseline.nightsRecorded, 7,
                       "the judged night must not count toward the baseline")
        XCTAssertEqual(signals.baseline.sleepMinutes, 430, accuracy: 0.001,
                       "median of the seven earlier nights; including the 900-minute night would give 435")
    }

    func testStepsWithoutHourlyBucketsKeepTheStillnessNudgeSilent() {
        var signals = CoachSignals(now: Date(timeIntervalSince1970: 1_792_000_000))
        signals.today.steps = 8_401
        signals.today.blocks = []
        signals.today.awake = true
        let b3 = NudgeRules.evaluate(signals, now: signals.now).first { $0.rule == .b3 }
        XCTAssertNil(b3?.nudge, "B3 fired with 8,401 steps and no hourly data")
        XCTAssertEqual(b3?.silentReason, "no hourly step data today")
    }
}

/// The day's sleep score (owner 2026-10-22, option A): the night and the naps scored together.
final class SleepDayScoreTests: XCTestCase {
    private func summary(start: Date, deep: Int, light: Int, rem: Int = 0, awake: Int = 0) -> SleepSummary {
        let total = deep + light + rem + awake
        let session = SleepSession(date: Calendar.current.startOfDay(for: start), startAt: start,
                                   endAt: start.addingTimeInterval(TimeInterval(total * 60)), totalMinutes: total, score: nil)
        return SleepSummary(session: session, lightMinutes: light, deepMinutes: deep, awakeMinutes: awake,
                            blocks: [], remMinutesWithoutBlocks: rem)
    }

    private let night = Date(timeIntervalSince1970: 1_792_000_000)

    func testOneSessionScoresExactlyAsBefore() {
        let main = summary(start: night, deep: 70, light: 230, rem: 60, awake: 25)
        XCTAssertEqual(SleepScore.calculate(day: SleepDay(main: main)).score, SleepScore.calculate(main).score)
    }

    func testANapAfterAShortNightRaisesTheDayScore() {
        let shortNight = summary(start: night, deep: 50, light: 210, rem: 40, awake: 20)   // 5 h asleep
        let nap = summary(start: night.addingTimeInterval(12 * 3600), deep: 15, light: 75)  // 1 h 30 m nap
        let alone = SleepScore.calculate(shortNight).score
        let day = SleepScore.calculate(day: SleepDay(main: shortNight, naps: [nap])).score
        XCTAssertGreaterThan(day, alone, "a 90-minute nap after a 5-hour night must count toward the day")
    }

    func testTheDayScoreSumsEveryMinuteNotTheScores() {
        let main = summary(start: night, deep: 80, light: 240, rem: 70, awake: 20)
        let nap = summary(start: night.addingTimeInterval(13 * 3600), deep: 10, light: 30)
        let inputs = SleepScore.inputs(main) + SleepScore.inputs(nap)
        XCTAssertEqual(inputs.asleep, 430)   // night 80 + 240 + 70 asleep, plus a 40-minute nap
        XCTAssertEqual(SleepScore.calculate(day: SleepDay(main: main, naps: [nap])).score, SleepScore.score(inputs).score)
    }

    func testTheBreakdownSaysTheNapsArePartOfTheTotal() {
        XCTAssertEqual(SleepDayRule.breakdownCaption(mainMinutes: 405, napCount: 2, napMinutes: 97), "Night 6h 45m · 2 naps 1h 37m")
        XCTAssertEqual(SleepDayRule.breakdownCaption(mainMinutes: 420, napCount: 1, napMinutes: 40), "Night 7h 0m · nap 40m")
        XCTAssertNil(SleepDayRule.breakdownCaption(mainMinutes: 420, napCount: 0, napMinutes: 0))
    }
}

/// Tiles lead with the LATEST reading; the day's range/average and the reading's age are context (owner 2026-10-22).
final class LatestValueTileTests: XCTestCase {
    private func samples(_ values: [Double]) -> [MetricSample] {
        values.enumerated().map { MetricSample(timestamp: Date(timeIntervalSince1970: 1_792_000_000 + Double($0.offset) * 600), value: $0.element) }
    }

    func testTheRangeIsContextNotTheNumber() {
        XCTAssertEqual(VitalsCardFactory.dayRange(samples([62, 88, 152, 72])), "62–152 today")
        XCTAssertNil(VitalsCardFactory.dayRange(samples([72])), "a range of one reading is not context")
    }

    func testTheAverageIsContextNotTheNumber() {
        XCTAssertEqual(VitalsCardFactory.dayAverage(samples([96, 98, 97]), unit: "%"), "avg 97% today")
        XCTAssertNil(VitalsCardFactory.dayAverage(samples([96]), unit: "%"))
    }

    func testTheAgeDropsTheWordUpdated() {
        XCTAssertEqual(TodayTileContext.age("Updated 4m ago"), "4m ago")
        XCTAssertEqual(TodayTileContext.age("Updated just now"), "just now")
    }
}

/// The coach's sleep packet: "last night" is the main sleep (deep + light + REM), never the waking-day total that adds
/// naps. Jimmy's 2026-10-23 case: a 5 h 25 m night plus a 4 h 40 m nap read as "10 h 5 m last night", and the answer
/// called it short of a 7-hour goal (owner report).
final class CoachSleepContextTests: XCTestCase {
    @MainActor
    func testLastNightIsTheMainSleepNotTheDayTotalIncludingNaps() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 20)))
        AppClock.configure("2026-10-24T20:00:00", debugBuild: true, systemNow: Date(), timeZone: .current)
        defer { AppClock.reset() }

        let context = try TestSupport.makeContext()

        // Night: 23:12 → 04:37 = 5 h 25 m in bed; deep 100 + light 160 + REM 64 + awake 1.
        let nightStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 12)))
        let night = SleepSession(date: now, startAt: nightStart,
                                 endAt: nightStart.addingTimeInterval(325 * 60), totalMinutes: 325)
        context.insert(night)
        var minute = 0
        for (stage, minutes) in [(SleepStage.deep, 100), (.light, 160), (.rem, 64), (.awake, 1)] {
            context.insert(SleepStageBlock(sessionId: night.id,
                                           startAt: nightStart.addingTimeInterval(Double(minute) * 60),
                                           startMinute: minute, durationMinutes: minutes, stage: stage))
            minute += minutes
        }

        // The same waking day: an afternoon nap, 13:00 → 17:40 = 4 h 40 m. `SleepDayRule` makes the longer sleep the
        // night and this the nap, so the day total is 10 h 5 m.
        let napStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 13)))
        let nap = SleepSession(date: now, startAt: napStart,
                               endAt: napStart.addingTimeInterval(280 * 60), totalMinutes: 280)
        context.insert(nap)
        context.insert(SleepStageBlock(sessionId: nap.id, startAt: napStart, startMinute: 0,
                                       durationMinutes: 280, stage: .light))
        try context.save()

        let packet = CoachContextBuilder.build(context: context, now: now)
        let sleep = try XCTUnwrap(packet.latestSleep)
        XCTAssertEqual(sleep.nightMin, 324, "last night is the main sleep: deep + light + REM")
        XCTAssertEqual(sleep.remMin, 64, "REM is decoded and reported")
        XCTAssertEqual(sleep.totalMin, 605, "the day total adds the 280-minute nap")
        XCTAssertEqual(sleep.napMin, 280)

        // The readiness tool carries the same distinction, because the answer quotes it.
        let readiness = InsightTools.readinessObject(context)
        let part = try XCTUnwrap(readiness["sleep"] as? [String: Any])
        XCTAssertEqual(part["night_min"] as? Double, 324)
        XCTAssertEqual(part["day_total_min"] as? Double, 605)
        XCTAssertEqual(part["rem_min"] as? Double, 64)
        XCTAssertEqual(part["nap_min"] as? Double, 280)
    }
}
