import XCTest
@testable import PulseLoop

/// A nap is not a night (owner 2026-11-04, option (a)): its own page carries no score or rating, while the day's score
/// above the carousel still includes it. The rule lives in `SleepDay`, so it is testable without a device.
///
/// Android counterpart: `SleepDayTest` (`isMain`, `heroLabel`, `heroShowsScore`).
@MainActor
final class SleepNapScoreTests: XCTestCase {
    private let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 0))!

    private func summary(id: UUID = UUID(), startMinute: Int, minutes: Int) -> SleepSummary {
        let session = SleepSession(date: midnight, startAt: midnight.addingTimeInterval(Double(startMinute) * 60),
                                   endAt: midnight.addingTimeInterval(Double(startMinute + minutes) * 60),
                                   totalMinutes: minutes)
        return SleepSummary(session: session, lightMinutes: minutes, deepMinutes: 0, awakeMinutes: 0, blocks: [])
    }

    func testTheLongestSessionIsMainAndTheRestAreNaps() throws {
        // The night is listed last and the nap first by start time: `main` is positional (the longest), not the first.
        let nap = summary(startMinute: -600, minutes: 40)
        let night = summary(startMinute: 5, minutes: 439)
        let day = try XCTUnwrap(SleepDay(sessions: [nap, night]))

        XCTAssertEqual(day.main.session.totalMinutes, 439)
        XCTAssertEqual(day.naps.count, 1)
        XCTAssertTrue(day.isMain(night))
        XCTAssertFalse(day.isMain(nap))
        XCTAssertEqual(day.totalMinutes, 439 + 40, "the day still counts the nap")
    }

    func testANapPageShowsNoScoreAndSaysWhatItIs() {
        XCTAssertEqual(SleepDay.heroLabel(isMain: true), "Last Sleep")
        XCTAssertTrue(SleepDay.heroShowsScore(isMain: true))
        XCTAssertEqual(SleepDay.heroLabel(isMain: false), "Nap")
        XCTAssertFalse(SleepDay.heroShowsScore(isMain: false), "a nap page draws no score column at all")
    }

    func testASingleShortNightIsStillTheMainSleep() throws {
        // "Main" is not a duration threshold: a 3½-hour night with no nap keeps its score.
        let only = summary(startMinute: 0, minutes: 210)
        let day = try XCTUnwrap(SleepDay(sessions: [only]))
        XCTAssertTrue(day.isMain(only))
        XCTAssertTrue(SleepDay.heroShowsScore(isMain: day.isMain(only)))
    }

    func testTwoNapsLeaveOnlyTheNightScored() throws {
        let nap1 = summary(startMinute: -700, minutes: 25)
        let nap2 = summary(startMinute: 600, minutes: 35)
        let night = summary(startMinute: 5, minutes: 400)
        let day = try XCTUnwrap(SleepDay(sessions: [nap1, night, nap2]))

        XCTAssertEqual(day.naps.count, 2)
        XCTAssertTrue(day.isMain(night))
        XCTAssertFalse(day.isMain(nap1))
        XCTAssertFalse(day.isMain(nap2))
        XCTAssertEqual(day.totalMinutes, 400 + 25 + 35)
        // The day's score still includes both naps (it is one score over the summed inputs).
        XCTAssertEqual(day.score.score, SleepScore.calculate(day: day).score)
    }
}
