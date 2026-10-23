import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// Coach insights (2026-10-22, docs/process/plans/coach-insights.md): the new metrics and evidence tools, on seeded
/// stores, through the registry — the same path the coach takes.
@MainActor
final class CoachInsightToolsTests: XCTestCase {
    private let cal = Calendar.current

    private func flags(write: Bool = true) -> CoachFeatureFlags {
        var settings = TestSupport.enabledCoachSettings()
        settings.enableWriteTools = write
        return CoachFeatureFlags(settings: settings, hasAPIKey: true)
    }

    private func run(_ name: String, _ args: String, _ c: ModelContext) async throws -> [String: Any] {
        let f = flags()
        let tool = try XCTUnwrap(ToolRegistry(flags: f).tool(named: name), "\(name) is not registered")
        let result = try await tool.run(Data(args.utf8), ToolExecutionContext(modelContext: c, flags: f))
        XCTAssertFalse(result.isError, result.jsonString)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any])
    }

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: AppClock.now))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// A night that starts the evening of `dayOffset` at `hour:minute` and lasts `minutes`, with `awake` awake minutes
    /// at the end, plus heart rate inside it (min = `restingHR`) and one daytime reading that must not count.
    @discardableResult
    private func night(_ c: ModelContext, evening dayOffset: Int, hour: Int = 23, minute: Int = 0, minutes: Int = 420,
                       awake: Int = 15, restingHR: Double? = 55) -> SleepSession {
        let start = at(dayOffset, hour, minute)
        let stages = Array(repeating: SleepStage.light, count: minutes - awake - 60) + Array(repeating: .deep, count: 60)
            + Array(repeating: .awake, count: awake)
        let s = TestSupport.insertSleep(nightStart: start, stages: stages, into: c)
        if let restingHR {
            for (i, v) in [restingHR + 7, restingHR, restingHR + 3].enumerated() {
                TestSupport.insertMeasurement(kind: .heartRate, value: v, timestamp: start.addingTimeInterval(Double(i + 1) * 3600), into: c)
            }
            TestSupport.insertMeasurement(kind: .heartRate, value: 41, timestamp: start.addingTimeInterval(-6 * 3600), into: c)
        }
        return s
    }

    // MARK: - The new metrics

    func testSleepDerivedMetrics() throws {
        let c = try TestSupport.makeContext()
        let s = night(c, evening: -2, hour: 23, minute: 30, minutes: 430, awake: 20, restingHR: 54)
        // A nap on the waking day counts toward the day's sleep and awake time, not the bedtime.
        TestSupport.insertSleep(nightStart: at(-1, 14), stages: Array(repeating: .light, count: 30), into: c)
        let range = (InsightTools.day(-3), InsightTools.day(0))
        func value(_ m: CoachChartMetric) -> Double? {
            CoachDataAccess.dailySeries(metric: m, start: range.0, end: range.1, context: c)
                .first { cal.isDate($0.date, inSameDayAs: s.date) }?.value
        }
        XCTAssertEqual(value(.sleep), 460, "night 430 + nap 30 — the day's total, not one point per session")
        XCTAssertEqual(value(.bedtime), -30, "23:30 is 30 minutes before midnight")
        XCTAssertEqual(value(.wakeTime), Double(CoachSignals.minuteOfDay(s.endAt)))
        XCTAssertEqual(value(.restingHr), 54, "the lowest heart rate DURING the main sleep; the 41 at 17:30 is outside it")
        XCTAssertEqual(value(.sleepAwake), 20)
        XCTAssertNotNil(value(.sleepScore))
        XCTAssertEqual(CoachChartView.clock(-30), "23:30")
        XCTAssertEqual(CoachDataAccess.sleepDays(start: range.0, end: range.1, context: c).first?.night.contains("→"), true)
    }

    func testIntensityStressAndRespiration() throws {
        let c = try TestSupport.makeContext()
        let d = at(-1, 10)
        for (i, met) in [1.0, 3.5, 4.0, 2.9, 5.0].enumerated() {
            TestSupport.insertMeasurement(kind: .met, value: met, timestamp: d.addingTimeInterval(Double(i) * 300), into: c)
        }
        for v in [20.0, 40.0] { TestSupport.insertMeasurement(kind: .stress, value: v, timestamp: d, into: c) }
        TestSupport.insertMeasurement(kind: .respiratoryRate, value: 15, timestamp: d, into: c)
        let r = (InsightTools.day(-1), InsightTools.day(-1))
        XCTAssertEqual(CoachDataAccess.dailySeries(metric: .intensityMinutes, start: r.0, end: r.1, context: c).first?.value, 15,
                       "three 5-minute records at MET ≥ 3")
        XCTAssertEqual(CoachDataAccess.dailySeries(metric: .stress, start: r.0, end: r.1, context: c).first?.value, 30)
        XCTAssertEqual(CoachDataAccess.dailySeries(metric: .respRate, start: r.0, end: r.1, context: c).first?.value, 15)
    }

    func testEveryToolOffersEveryMetricExceptTheExcludedOnes() {
        let all = Set(CoachChartMetric.toolEnum)
        XCTAssertTrue(all.isSuperset(of: ["stress", "resting_hr", "resp_rate", "intensity_minutes", "sleep_score", "bedtime", "wake_time", "sleep_awake"]))
        XCTAssertTrue(all.isDisjoint(with: ["hrv", "glucose", "bp_sys", "bp_dia", "total_cholesterol"]),
                      "HRV unvalidated; BP/glucose/blood components out by owner decision D1")
        for metric in CoachChartMetric.allCases { _ = CoachChartView.valueLabel(1, metric: metric) }
    }

    // MARK: - Coverage

    func testCoverageFlagsThinData() throws {
        XCTAssertTrue(CoachDataAccess.isSparse(daysWithData: 2, daysInRange: 7), "under 3 days")
        XCTAssertTrue(CoachDataAccess.isSparse(daysWithData: 5, daysInRange: 28), "under half the range")
        XCTAssertFalse(CoachDataAccess.isSparse(daysWithData: 5, daysInRange: 7))
    }

    func testAnalysisResultsCarryCoverageBesideTheirFields() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...14 { TestSupport.insertActivity(date: TestSupport.day(-i), steps: 8000 + i * 10, into: c) }
        let out = try await run("compare_periods", #"""
        {"metric":"steps","period_a_start":"\#(InsightTools.day(-7))","period_a_end":"\#(InsightTools.day(-1))",
         "period_b_start":"\#(InsightTools.day(-14))","period_b_end":"\#(InsightTools.day(-8))"}
        """#, c)
        XCTAssertNotNil(out["a_average"], "the result's own fields are unchanged")
        let ca = try XCTUnwrap(out["coverage_a"] as? [String: Any])
        XCTAssertEqual(ca["days_with_data"] as? Int, 7)
        XCTAssertEqual(ca["sparse"] as? Bool, false)
    }

    // MARK: - Evidence tools

    func testBaselinesSayWhatIsUnusualForThisUser() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...20 { _ = night(c, evening: -i - 1, restingHR: 55 + Double(i % 3)) }
        _ = night(c, evening: -1, restingHR: 66)    // last night: well above the usual 55–57
        let out = try await run("get_baselines", #"{"metrics":["resting_hr","bedtime"]}"#, c)
        let rows = try XCTUnwrap(out["baselines"] as? [[String: Any]])
        let rhr = try XCTUnwrap(rows.first { $0["metric"] as? String == "resting_hr" })
        XCTAssertEqual((rhr["latest"] as? [String: Any])?["value"] as? Double, 66)
        XCTAssertEqual(try XCTUnwrap(rhr["avg_28d"] as? Double), 56, accuracy: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(rhr["latest_vs_28d"] as? Double), 9)
        XCTAssertEqual(rows.first { $0["metric"] as? String == "bedtime" }?["latest_clock"] as? String, "23:00")
    }

    /// Owner decision C (2026-10-23): the tools round at source — whole numbers for heart rate, stress, steps, minutes;
    /// one decimal for breathing rate — so the model never sees "67.7" to copy.
    func testBaselinesRoundForDisplay() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...6 { _ = night(c, evening: -i - 1, restingHR: i % 2 == 0 ? 56 : 57) }   // average 56.5
        _ = night(c, evening: -1, restingHR: 60)
        let d = at(-2, 10)
        for v in [14.26, 14.31] { TestSupport.insertMeasurement(kind: .respiratoryRate, value: v, timestamp: d, into: c) }
        TestSupport.insertMeasurement(kind: .respiratoryRate, value: 15.2, timestamp: at(0, 3), into: c)
        let out = try await run("get_baselines", #"{"metrics":["resting_hr","resp_rate"]}"#, c)
        let rows = try XCTUnwrap(out["baselines"] as? [[String: Any]])
        let rhr = try XCTUnwrap(rows.first { $0["metric"] as? String == "resting_hr" })
        let avg = try XCTUnwrap(rhr["avg_28d"] as? Double)
        XCTAssertEqual(avg, avg.rounded(), "resting heart rate is whole: \(avg)")
        let resp = try XCTUnwrap(rows.first { $0["metric"] as? String == "resp_rate" })
        let r = try XCTUnwrap(resp["avg_28d"] as? Double)
        XCTAssertEqual(r, (r * 10).rounded() / 10, "breathing rate keeps one decimal: \(r)")
    }

    /// The owner's 28-day sleep average read 4 h 52 m while he slept 7 h 04 m: nap-only days and partial recordings
    /// were averaged as nights. Days under `sleepBaselineMinMinutes` (shared catalog) leave the averages and are counted.
    func testShortSleepDaysLeaveTheSleepAverages() async throws {
        let c = try TestSupport.makeContext()
        for i in 2...8 { _ = night(c, evening: -i - 1, minutes: 420) }                         // 7 h nights
        for i in 9...11 {                                                                       // nap-only days
            TestSupport.insertSleep(nightStart: at(-i, 14), stages: Array(repeating: .light, count: 40), into: c)
        }
        _ = night(c, evening: -1, minutes: 424)                                                  // last night
        let readiness = try await run("get_readiness", "{}", c)
        let sleep = try XCTUnwrap(readiness["sleep"] as? [String: Any])
        // Readiness compares NIGHTS (main sleep, awake excluded): a 7 h night with 15 awake minutes is 405 asleep.
        XCTAssertEqual(try XCTUnwrap(sleep["avg_28d_min"] as? Double), 405, accuracy: 1, "naps are not nights to average")
        XCTAssertEqual(sleep["short_days_excluded"] as? Int, 3)
        let baselines = try await run("get_baselines", #"{"metrics":["sleep"]}"#, c)
        let row = try XCTUnwrap((baselines["baselines"] as? [[String: Any]])?.first)
        // `get_baselines` reports the `sleep` metric the Sleep tab shows: the waking-day total (night + naps).
        XCTAssertEqual(try XCTUnwrap(row["avg_28d"] as? Double), 420, accuracy: 1)
        XCTAssertEqual(row["short_days_excluded"] as? Int, 3)
    }

    func testWeekReviewIsOneCallForEveryMetric() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...7 { TestSupport.insertActivity(date: TestSupport.day(-i), steps: 9000, into: c) }
        for i in 8...14 { TestSupport.insertActivity(date: TestSupport.day(-i), steps: 8000, into: c) }
        let out = try await run("get_week_review", "{}", c)
        let steps = try XCTUnwrap((out["metrics"] as? [[String: Any]])?.first { $0["metric"] as? String == "steps" })
        XCTAssertEqual(steps["this_week"] as? Double, 9000)
        XCTAssertEqual(steps["last_week"] as? Double, 8000)
        XCTAssertEqual(steps["change_pct"] as? Double, 13, "percent changes are whole (owner decision C, 2026-10-23)")
        XCTAssertEqual((out["metrics"] as? [[String: Any]])?.count, InsightTools.weekMetrics.count)
    }

    func testReadinessIsAnEvidenceBundleThatNamesWhatIsMissing() async throws {
        let c = try TestSupport.makeContext()
        for i in 2...15 { _ = night(c, evening: -i - 1, minutes: 450, restingHR: 56) }
        _ = night(c, evening: -1, minutes: 330, restingHR: 64)        // short night, resting HR up
        let out = try await run("get_readiness", "{}", c)
        let sleep = try XCTUnwrap(out["sleep"] as? [String: Any])
        // 330 minutes in bed with 15 awake → 315 asleep, REM included (0 here: the fixture seeds light + deep).
        XCTAssertEqual(sleep["night_min"] as? Double, 315)
        XCTAssertLessThan(try XCTUnwrap(sleep["vs_avg_min"] as? Double), -100)
        let rhr = try XCTUnwrap(out["resting_hr"] as? [String: Any])
        XCTAssertEqual(rhr["vs_baseline"] as? Double, 8)
        XCTAssertNil(out["score"], "no invented readiness score")
        let missing = try XCTUnwrap(out["missing"] as? [String])
        XCTAssertTrue(missing.contains { $0.contains("stress") }, "no stress readings were seeded: \(missing)")
        XCTAssertTrue((out["not_used"] as? [String])?.first?.contains("hrv") ?? false)
    }

    func testSleepPatternsSeparateLateFromShortAndFragmented() async throws {
        let c = try TestSupport.makeContext()
        for i in 2...9 { _ = night(c, evening: -i, hour: 23, minutes: 450, awake: 10) }
        // 01:30 in the early hours of today: its own waking day (today), very late, short and broken.
        _ = night(c, evening: 0, hour: 1, minute: 30, minutes: 300, awake: 70)
        let out = try await run("get_sleep_patterns", #"{"start":"\#(InsightTools.day(-10))","end":"\#(InsightTools.day(1))"}"#, c)
        let summary = try XCTUnwrap(out["summary"] as? [String: Any])
        XCTAssertEqual(summary["median_bedtime"] as? String, "23:00")
        XCTAssertGreaterThanOrEqual(summary["short_nights"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(summary["fragmented_nights"] as? Int ?? 0, 1)
        XCTAssertGreaterThan(summary["bedtime_spread_min"] as? Double ?? 0, 0)
        let nights = try XCTUnwrap(out["nights"] as? [[String: Any]])
        XCTAssertTrue(nights.allSatisfy { ($0["night"] as? String)?.contains("→") == true }, "every night says which evening and morning")
    }

    func testTimeOfDayFindsWhenTheUserMoves() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...5 {
            c.insert(ActivityBucketSample(timestamp: at(-i, 19), steps: 3000, distanceMeters: 2000))
            c.insert(ActivityBucketSample(timestamp: at(-i, 15), steps: 200, distanceMeters: 150))
        }
        try c.save()
        let out = try await run("get_time_of_day_profile",
                                #"{"metric":"steps","start":"\#(InsightTools.day(-6))","end":"\#(InsightTools.day(-1))"}"#, c)
        XCTAssertEqual((out["peak_hours"] as? [Int])?.first, 19)
        XCTAssertGreaterThan(out["share_evening_18_23"] as? Double ?? 0, 90)
        XCTAssertEqual(out["days_with_data"] as? Int, 5)
    }

    func testWorkoutResponseLinksTheNextNightAndMorning() async throws {
        let c = try TestSupport.makeContext()
        let w = ActivitySession(type: "run", status: .finished, startedAt: at(-2, 20), endedAt: at(-2, 21), useGps: false)
        w.avgHeartRate = 158
        c.insert(w)
        try c.save()
        _ = night(c, evening: -2, hour: 23, minutes: 360, restingHR: 62)
        _ = night(c, evening: -3, hour: 23, minutes: 470, restingHR: 55)
        let out = try await run("get_workout_response", #"{"start":"\#(InsightTools.day(-4))","end":"\#(InsightTools.day(-1))"}"#, c)
        let row = try XCTUnwrap((out["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["next_night_total_min"] as? Double, 360)
        XCTAssertEqual(row["hours_before_bedtime"] as? Double, 2)
        XCTAssertEqual(row["next_morning_resting_hr"] as? Double, 62)
    }

    func testFindPatternsNeedsEnoughDaysAndThenComparesBestAndWorst() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...4 { _ = night(c, evening: -i - 1) }
        var out = try await run("find_patterns", #"{"target":"sleep","start":"\#(InsightTools.day(-20))","end":"\#(InsightTools.day(0))"}"#, c)
        XCTAssertEqual(out["enough_data"] as? Bool, false)
        for i in 5...12 {
            // Long nights follow quiet days, short nights follow very active ones.
            let long = i % 2 == 0
            _ = night(c, evening: -i - 1, minutes: long ? 480 : 360)
            TestSupport.insertActivity(date: TestSupport.day(-i - 1), steps: long ? 6000 : 15000, into: c)
        }
        out = try await run("find_patterns", #"{"target":"sleep","start":"\#(InsightTools.day(-20))","end":"\#(InsightTools.day(0))"}"#, c)
        XCTAssertEqual(out["enough_data"] as? Bool, true)
        let steps = try XCTUnwrap((out["features"] as? [[String: Any]])?.first { $0["feature"] as? String == "steps_day_before" })
        XCTAssertLessThan(try XCTUnwrap(steps["difference"] as? Double), 0, "best nights followed fewer steps")
    }

    func testAnExperimentComparesItsDaysWithTheDaysBefore() async throws {
        let c = try TestSupport.makeContext()
        for i in 1...7 { _ = night(c, evening: -i - 1, minutes: 380) }
        let started = try await run("start_experiment",
                                    #"{"name":"Earlier bedtime","change":"lights out by 22:45","metric":"sleep","days":7}"#, c)
        XCTAssertEqual(started["ok"] as? Bool, true)
        _ = night(c, evening: -1, minutes: 460)     // tonight's night, dated today = experiment day 1
        let out = try await run("get_experiments", "{}", c)
        let exp = try XCTUnwrap((out["experiments"] as? [[String: Any]])?.first)
        XCTAssertEqual(exp["status"] as? String, "running")
        XCTAssertEqual(exp["during_avg"] as? Double, 460)
        XCTAssertEqual(exp["before_avg"] as? Double, 380)
    }
}

/// The server holds a copy of the app's tool definitions (`server/internal/coach/prompts/tools.json`) and of the chart
/// metric list (`response_schema.json`). Hand-copied, they drift; this test compares them with the app and — with
/// `TEST_RUNNER_WRITE_COACH_CATALOG=1` — rewrites tools.json from the app's registry.
@MainActor
final class CoachToolCatalogTests: XCTestCase {
    private var promptsDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/internal/coach/prompts")
    }

    /// Every tool the app can register (all optional groups on, web search off — the server never offers it).
    private func appTools() -> [[String: Any]] {
        var settings = TestSupport.enabledCoachSettings()
        settings.enableWriteTools = true
        settings.enableLiveMeasurements = true
        settings.enableWebSearch = false
        var flags = CoachFeatureFlags(settings: settings, hasAPIKey: true)
        flags.nutritionPrefs.masterEnabled = true
        flags.nutritionPrefs.shareWithCoach = true
        return ToolRegistry(flags: flags).toolSpecs.map { spec in
            var function: [String: Any] = ["name": spec["name"]!, "description": spec["description"]!,
                                           "parameters": spec["parameters"]!]
            if let strict = spec["strict"] { function["strict"] = strict }   // the server keeps the strict-schema flag
            return ["type": "function", "function": function]
        }.sorted { (($0["function"] as! [String: Any])["name"] as! String) < (($1["function"] as! [String: Any])["name"] as! String) }
    }

    private func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func testServerToolsMatchTheApp() throws {
        let url = promptsDir.appendingPathComponent("tools.json")
        let app = appTools()
        if ProcessInfo.processInfo.environment["WRITE_COACH_CATALOG"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: app, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: url)
        }
        let server = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let names = { (list: [[String: Any]]) in Set(list.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }) }
        XCTAssertEqual(names(server), names(app), "tool NAMES differ (run with TEST_RUNNER_WRITE_COACH_CATALOG=1 to regenerate)")
        let byName = Dictionary(uniqueKeysWithValues: server.map { (($0["function"] as! [String: Any])["name"] as! String, $0) })
        for tool in app {
            let name = (tool["function"] as! [String: Any])["name"] as! String
            XCTAssertEqual(try canonical(byName[name] ?? [:]), try canonical(tool), "\(name) differs between the app and tools.json")
        }
    }

    func testTheAnswerSchemaChartMetricsAreTheAppsMetrics() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: promptsDir.appendingPathComponent("response_schema.json"))) as? [String: Any])
        let text = try canonical(schema)
        let enumLists = text.components(separatedBy: "\"enum\":[").dropFirst().map { $0.prefix { $0 != "]" } }
        let chartMetrics = try XCTUnwrap(enumLists.first { $0.contains("\"active_minutes\"") })
        let values = Set(chartMetrics.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
        XCTAssertEqual(values, Set(CoachChartMetric.toolEnum), "response_schema.json chart.metric enum must equal the app's metrics")
    }
}
