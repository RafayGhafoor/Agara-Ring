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
}
