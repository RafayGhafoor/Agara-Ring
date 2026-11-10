import XCTest
@testable import PulseLoop

/// The challenge day number — mirror of Android `Ev40ChallengeTest` (Rule 2). Boundaries first: the first day, the exact
/// first and last of the 40, the day after it ends, and the all-zero day that must not start a challenge.
final class Ev40ChallengeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testNoTrackedDayMeansNoChallenge() {
        XCTAssertNil(Ev40Challenge.dayNumber(trackedKeys: [], today: "2026-11-05", calendar: calendar))
        XCTAssertNil(Ev40Challenge.label(dayNumber: nil))
    }

    func testTheFirstTickedDayIsDayOne() {
        let day = Ev40Challenge.dayNumber(trackedKeys: ["2026-11-05"], today: "2026-11-05", calendar: calendar)
        XCTAssertEqual(day, 1)
        XCTAssertEqual(Ev40Challenge.label(dayNumber: day), "Day 1 of \(Ev40Challenge.totalDays)")
    }

    func testThirteenDaysAfterTheStartIsDayFourteen() {
        let day = Ev40Challenge.dayNumber(trackedKeys: ["2026-11-01", "2026-10-23"], today: "2026-11-05",
                                         calendar: calendar)
        XCTAssertEqual(day, 14)
        XCTAssertEqual(Ev40Challenge.label(dayNumber: day), "Day 14 of 40")
    }

    func testTheLastDayIsFortyAndTheNextIsPastIt() {
        XCTAssertEqual(Ev40Challenge.dayNumber(trackedKeys: ["2026-09-27"], today: "2026-11-05", calendar: calendar), 40)
        XCTAssertEqual(Ev40Challenge.label(dayNumber: 40), "Day 40 of 40")
        XCTAssertEqual(Ev40Challenge.dayNumber(trackedKeys: ["2026-09-26"], today: "2026-11-05", calendar: calendar), 41)
        // Past its length the label disappears rather than reading "Day 41 of 40".
        XCTAssertNil(Ev40Challenge.label(dayNumber: 41))
    }

    func testAnUnparseableKeyIsIgnoredRatherThanCrashing() {
        XCTAssertNil(Ev40Challenge.dayNumber(trackedKeys: ["not-a-date"], today: "2026-11-05", calendar: calendar))
        // A row dated ahead of today (clock skew) is still day one, not a negative number.
        XCTAssertEqual(Ev40Challenge.dayNumber(trackedKeys: ["2026-11-09"], today: "2026-11-05", calendar: calendar), 1)
    }

    // MARK: Streak (plan ev40-share-card-v2, A1/D4.2)

    func testNoTickedDayIsNoStreak() {
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: [], today: "2026-11-05", calendar: calendar), 0)
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["not-a-date"], today: "2026-11-05", calendar: calendar), 0)
    }

    func testAStreakCountsBackFromToday() {
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-05"], today: "2026-11-05", calendar: calendar), 1)
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-05", "2026-11-04"], today: "2026-11-05",
                                            calendar: calendar), 2)
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-05", "2026-11-04", "2026-11-03", "2026-10-30"],
                                            today: "2026-11-05", calendar: calendar), 3)
    }

    /// Breakfast: today has no tick yet, so the run ends yesterday and the card does not read "0-day streak".
    func testTodayEmptyStillCountsTheRunEndingYesterday() {
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-04", "2026-11-03"], today: "2026-11-05",
                                            calendar: calendar), 2)
    }

    func testAGapBreaksTheStreak() {
        // Today and the day before yesterday ticked, yesterday empty: the run ending today is one day long.
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-05", "2026-11-03"], today: "2026-11-05",
                                            calendar: calendar), 1)
        // Nothing today and nothing yesterday: no run to count, however long the older one was.
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-03", "2026-11-02"], today: "2026-11-05",
                                            calendar: calendar), 0)
    }

    /// The month boundary is a real gap risk when the run is walked by adding days, so it is pinned: Oct 31 → Nov 1.
    func testAStreakCrossesTheMonthBoundary() {
        XCTAssertEqual(Ev40Challenge.streak(tickedKeys: ["2026-11-01", "2026-10-31", "2026-10-30"],
                                            today: "2026-11-01", calendar: calendar), 3)
    }

    // MARK: Perfect days and days active (A2/A4)

    func testPerfectDaysCountsCompleteDaysSoFar() {
        let masks = ["2026-11-03": 7, "2026-11-04": 255, "2026-11-05": 255,
                     "2026-11-06": 255]                     // tomorrow: not part of the journey yet
        XCTAssertEqual(Ev40Challenge.perfectDays(masksByKey: masks, today: "2026-11-05", calendar: calendar), 2)
    }

    func testPerfectDaysNeedsAllEightTicked() {
        XCTAssertEqual(Ev40Challenge.perfectDays(masksByKey: ["2026-11-05": 127], today: "2026-11-05",
                                                 calendar: calendar), 0)
        XCTAssertEqual(Ev40Challenge.perfectDays(masksByKey: [:], today: "2026-11-05", calendar: calendar), 0)
    }

    /// The challenge starts at the first **ticked** day, so a day merely opened (mask 0) before it is not day one — and
    /// the counts run from the start, so a zero day inside the run simply is not active.
    func testDaysActiveCountsFromTheFirstTickedDay() {
        let masks = ["2026-11-01": 0, "2026-11-02": 1, "2026-11-03": 0, "2026-11-04": 3, "2026-11-05": 0,
                     "2026-11-06": 5]
        XCTAssertEqual(Ev40Challenge.daysActive(masksByKey: masks, today: "2026-11-05", calendar: calendar), 2)
        XCTAssertEqual(Ev40Challenge.daysActive(masksByKey: [:], today: "2026-11-05", calendar: calendar), 0)
    }

    // MARK: Heat levels (A3)

    func testLevelIsTheTicksADayCarried() {
        XCTAssertEqual(Ev40Challenge.level(mask: 0), 0)      // none
        XCTAssertEqual(Ev40Challenge.level(mask: 1), 1)      // 1
        XCTAssertEqual(Ev40Challenge.level(mask: 3), 1)      // 2
        XCTAssertEqual(Ev40Challenge.level(mask: 7), 2)      // 3
        XCTAssertEqual(Ev40Challenge.level(mask: 15), 2)     // 4
        XCTAssertEqual(Ev40Challenge.level(mask: 31), 3)     // 5
        XCTAssertEqual(Ev40Challenge.level(mask: 127), 3)    // 7
        XCTAssertEqual(Ev40Challenge.level(mask: 255), 4)    // 8
    }
}
