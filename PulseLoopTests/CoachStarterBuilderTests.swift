import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// The three starter prompts on the empty coach screen: each one quotes a number the app really holds,
/// and a store with no (or partial) data never invents one.
@MainActor
final class CoachStarterBuilderTests: XCTestCase {
    /// 23:00 on the given day — a night that wakes on that day + 1, i.e. "last night" for day 0.
    private func night(_ dayOffset: Int) -> Date {
        let base = TestSupport.day(dayOffset)
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: base) ?? base
    }

    func testFullDataProducesThreeGroundedStarters() throws {
        let context = try TestSupport.makeContext()
        // A week of steps, last night's sleep and a resting heart-rate estimate.
        for offset in -6...0 {
            TestSupport.insertActivity(date: TestSupport.day(offset), steps: 9000 + offset * 100, into: context)
        }
        TestSupport.insertSleep(nightStart: night(-1), stages: Array(repeating: .light, count: 402), into: context)
        TestSupport.insertMeasurement(
            kind: .heartRate, value: 71, timestamp: TestSupport.day(0).addingTimeInterval(3600), into: context)

        let starters = CoachStarterBuilder.build(context: context)

        XCTAssertEqual(starters.count, CoachStarterBuilder.count)
        XCTAssertEqual(Set(starters.map(\.id)).count, starters.count, "starters are distinct")
        let sleep = try XCTUnwrap(starters.first { $0.id == "sleep-vs-goal" })
        // 402 minutes is 6h 42m — the number the app holds, against the app's own sleep goal.
        XCTAssertTrue(sleep.text.contains("6h 42m"), sleep.text)
        let goalMinutes = Int((MetricsService.buildTodaySummary(context: context).goals.sleepHours * 60).rounded())
        XCTAssertTrue(sleep.text.contains("\(goalMinutes / 60)h \(goalMinutes % 60)m"), sleep.text)
        XCTAssertTrue(starters.contains { $0.id == "steps-gap" || $0.id == "steps-done" })
        XCTAssertTrue(starters.contains { $0.id == "week-steps" })
    }

    func testEmptyStoreGivesThreeStartersWithoutInventingNumbers() {
        let starters: [CoachStarter]
        do {
            let context = try TestSupport.makeContext()
            starters = CoachStarterBuilder.build(context: context)
        } catch {
            return XCTFail("could not build an in-memory store: \(error)")
        }
        XCTAssertEqual(starters.count, CoachStarterBuilder.count)
        XCTAssertEqual(Set(starters.map(\.id)).count, starters.count)
        for starter in starters {
            XCTAssertFalse(
                starter.text.contains(where: \.isNumber), "no data, so no figures: \(starter.text)")
        }
    }

    func testPartialDataGroundsOnlyTheSlotsItCan() throws {
        let context = try TestSupport.makeContext()
        // Steps today only: no sleep, one day of history, no heart rate.
        TestSupport.insertActivity(date: TestSupport.day(0), steps: 4120, into: context)

        let starters = CoachStarterBuilder.build(context: context)

        XCTAssertEqual(starters.count, CoachStarterBuilder.count)
        let steps = try XCTUnwrap(starters.first { $0.id == "steps-gap" || $0.id == "steps-done" })
        let goal = MetricsService.buildTodaySummary(context: context).goals.stepsDaily
        XCTAssertTrue(steps.text.contains("\(goal - 4120)"), steps.text)
        XCTAssertFalse(starters.contains { $0.id == "sleep-vs-goal" })
        XCTAssertFalse(starters.contains { $0.id == "week-steps" }, "one day is not a week")
        XCTAssertFalse(starters.contains { $0.id == "resting-hr" || $0.id == "latest-hr" })
        XCTAssertEqual(starters.filter { $0.id.hasPrefix("fallback-") }.count, 2)
    }

    func testSleepOverGoalIsWordedAsQualityNotAsAGap() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-1), stages: Array(repeating: .deep, count: 9 * 60), into: context)

        let sleep = try XCTUnwrap(CoachStarterBuilder.build(context: context).first { $0.id == "sleep-vs-goal" })

        XCTAssertTrue(sleep.text.contains("9h"), sleep.text)
        XCTAssertTrue(sleep.text.contains("quality"), sleep.text)
    }
}
