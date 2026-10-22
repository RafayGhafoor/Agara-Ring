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
