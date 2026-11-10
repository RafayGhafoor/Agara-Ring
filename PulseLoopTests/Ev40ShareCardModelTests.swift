import XCTest
@testable import PulseLoop

/// The share card's formatted model (plan `ev40-share-card-v2`): the date line both platforms must print the same way
/// (R3), the streak/perfect/active numbers the card shows (A1/A2), and the 40-day journey as heat levels (A3).
final class Ev40ShareCardModelTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-05 12:00 UTC — noon, so no timezone can move the local day.
    private func day(_ key: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: key + " 12:00")!
    }

    /// The pinned date shape: `EEE, d MMM` reads "Tue, 10 Nov" — the same string Android prints (R3).
    func testTheDateLineIsTheSameOnBothPlatforms() {
        let model = Ev40ShareCardModel.make(mask: 1, userName: "Rafay", now: day("2026-11-10"),
                                            calendar: calendar, trackedKeys: ["2026-11-10"])
        XCTAssertEqual(model.dateLine, "Tue, 10 Nov")
    }

    func testTheJourneyIsOneHeatLevelPerDayFromTheFirstTickedDay() {
        let masks = ["2026-11-03": 15, "2026-11-04": 0, "2026-11-05": 255]
        let model = Ev40ShareCardModel.make(mask: 255, userName: nil, now: day("2026-11-05"), calendar: calendar,
                                            trackedKeys: ["2026-11-03", "2026-11-04", "2026-11-05"],
                                            masksByKey: masks)
        // v3 moved the day into the pill (dayLabel removed): asserted as the number the pill prints.
        XCTAssertEqual(model.dayNumber, 3)
        XCTAssertEqual(model.pillLabel, "DAY 3 / 40")
        XCTAssertEqual(model.journeyToday, 2)
        XCTAssertEqual(model.journey.count, Ev40Challenge.totalDays)
        XCTAssertEqual(Array(model.journey.prefix(4)), [2, 0, 4, 0])
    }

    func testTheCardCarriesTheStreakThePerfectDaysAndTheDaysActive() {
        let masks = ["2026-11-01": 255, "2026-11-02": 3, "2026-11-03": 255, "2026-11-04": 1, "2026-11-05": 255]
        let model = Ev40ShareCardModel.make(mask: 255, userName: "  ", now: day("2026-11-05"), calendar: calendar,
                                            trackedKeys: Array(masks.keys), masksByKey: masks)
        XCTAssertEqual(model.streak, 5)
        XCTAssertEqual(model.perfectDays, 3)
        XCTAssertEqual(model.daysActive, 5)
        XCTAssertTrue(model.isPerfect)
        // An empty or blank name hides the row rather than printing a placeholder.
        XCTAssertNil(model.userName)
        XCTAssertEqual(model.done, 8)
        XCTAssertEqual(model.percent, 100)
    }

    func testAnUnfinishedDayIsNotPerfect() {
        let model = Ev40ShareCardModel.make(mask: 127, userName: "Rafay", now: day("2026-11-10"), calendar: calendar,
                                            trackedKeys: ["2026-11-10"], masksByKey: ["2026-11-10": 127])
        XCTAssertFalse(model.isPerfect)
        XCTAssertEqual(model.done, 7)
        XCTAssertEqual(model.percent, 88)
        XCTAssertEqual(model.streak, 1)
        XCTAssertEqual(model.perfectDays, 0)
    }

    /// A day someone opened but did not tick must not start the challenge (the `dayNumber` rule), so the streak, the
    /// journey and "Day N of 40" agree on where it starts.
    func testAnEmptyDayDoesNotStartTheChallenge() {
        let model = Ev40ShareCardModel.make(mask: 1, userName: nil, now: day("2026-11-05"), calendar: calendar,
                                            trackedKeys: ["2026-11-01", "2026-11-05"],
                                            masksByKey: ["2026-11-01": 0, "2026-11-05": 1])
        XCTAssertEqual(model.dayNumber, 1)
        XCTAssertEqual(model.pillLabel, "DAY 1 / 40")
        XCTAssertEqual(model.streak, 1)
        XCTAssertEqual(model.daysActive, 1)
        XCTAssertEqual(model.journey[0], 1)
    }

    // MARK: Stats line — singular at exactly 1, the streak not repeated (mirror of Android `Ev40ShareCardStatsTest`)

    private func card(perfect: Int = 0, active: Int = 0, day: Int? = 14) -> Ev40ShareCardModel {
        Ev40ShareCardModel(userName: nil, dateLine: "Tue, 10 Nov", done: 6, total: 8,
                           disciplines: [], streak: 9, perfectDays: perfect, daysActive: active,
                           journey: [], journeyToday: nil, dayNumber: day)
    }

    // Policy history: v2 printed one stats line ("1 perfect day · 2 days active"); v3 (owner, 2026-11-10) gives each
    // stat its own row with an icon, so the line became three labels. Asserted now: singular at exactly 1 and only then;
    // the pill names the day of the challenge, or TODAY before it starts (D9). Mirror of Android Ev40ShareCardStatsTest.

    func testEachStatLabelTakesTheSingularOnlyAtExactlyOne() {
        XCTAssertEqual(card(perfect: 0).perfectLabel, "perfect days")
        XCTAssertEqual(card(perfect: 1).perfectLabel, "perfect day")
        XCTAssertEqual(card(perfect: 2).perfectLabel, "perfect days")
        XCTAssertEqual(card(active: 0).activeLabel, "days active")
        XCTAssertEqual(card(active: 1).activeLabel, "day active")
        XCTAssertEqual(card(active: 12).activeLabel, "days active")
        XCTAssertEqual(card().streakLabel, "day streak")
    }

    func testThePillNamesTheDayOfTheChallengeFirstAndLastIncluded() {
        XCTAssertEqual(card(day: 1).pillLabel, "DAY 1 / 40")
        XCTAssertEqual(card(day: 14).pillLabel, "DAY 14 / 40")
        XCTAssertEqual(card(day: 40).pillLabel, "DAY 40 / 40")
    }

    func testBeforeTheChallengeStartsOrOutsideItThePillSaysToday() {
        XCTAssertEqual(card(day: nil).pillLabel, "TODAY")
        XCTAssertEqual(card(day: 0).pillLabel, "TODAY")
        XCTAssertEqual(card(day: 41).pillLabel, "TODAY")
    }

    func testMakeCarriesTheDayNumberIntoThePill() {
        let model = Ev40ShareCardModel.make(mask: 1, userName: "Rafay", now: day("2026-11-10"), calendar: calendar,
                                            trackedKeys: ["2026-11-08", "2026-11-10"],
                                            masksByKey: ["2026-11-08": 3, "2026-11-10": 1])
        XCTAssertEqual(model.dayNumber, 3)
        XCTAssertEqual(model.pillLabel, "DAY 3 / 40")
    }

    func testEveryDisciplineEntryCarriesTheTrackersOwnSymbol() {
        let model = Ev40ShareCardModel.make(mask: 0, userName: nil, trackedKeys: [])
        XCTAssertEqual(model.disciplines.map(\.symbol), Ev40Discipline.allCases.map(\.symbol))
        XCTAssertFalse(model.disciplines.contains { $0.symbol == "circle" }, "no discipline falls back to a blank disc")
    }

    func testTheCopyAroundTheNumbersComesFromTheCatalogTemplates() {
        XCTAssertEqual(card().ringCount, "6 of 8")
        XCTAssertEqual(Ev40ShareCardModel.journeyDay(1), "Day 1")
        XCTAssertEqual(Ev40ShareCardModel.journeyDay(40), "Day 40")
    }

    // MARK: The 40-day window (review 2026-11-10, finding 1) — mirror of Android Ev40ChallengeTest

    private func key(_ date: Date) -> String { Ev40Challenge.key(date, calendar: calendar) }

    func testOnTheLastDayTheGridIsTheWholeChallengeWithTodayInTheLastSlot() {
        let masks = ["2026-09-26": 1, "2026-11-04": 255]
        let (slots, today) = Ev40ShareCardModel.journey(tickedKeys: Array(masks.keys), masksByKey: masks,
                                                        today: day("2026-11-04"), calendar: calendar)
        XCTAssertEqual(today, 39)
        XCTAssertEqual(slots.first, 1)
        XCTAssertEqual(slots[39], 4)
    }

    func testPastTheLastDayTheGridSlidesSoTodayStaysOnItWithTheDaysJustBefore() {
        var masks = ["2026-09-26": 1, "2026-11-04": 7, "2026-11-05": 255]
        let (slots, today) = Ev40ShareCardModel.journey(tickedKeys: Array(masks.keys), masksByKey: masks,
                                                        today: day("2026-11-05"), calendar: calendar)
        XCTAssertEqual(slots.count, 40)
        XCTAssertEqual(today, 39, "today is the last slot, not slot 40 (off the grid)")
        XCTAssertEqual(slots[39], 4, "and carries today's 8/8")
        XCTAssertEqual(slots[38], 2, "yesterday's 3 ticks")
        XCTAssertEqual(slots[0], 0, "day 1 has slid off")
        masks["2026-11-06"] = 1
        let (later, laterToday) = Ev40ShareCardModel.journey(tickedKeys: Array(masks.keys), masksByKey: masks,
                                                             today: day("2026-11-06"), calendar: calendar)
        XCTAssertEqual(laterToday, 39)
        XCTAssertEqual(later[39], 1)
        XCTAssertEqual(later[38], 4)
    }

    // MARK: The one shrink rule (review findings 2 and 12) — mirror of Android Ev40ShareCardStatsTest

    func testTextThatFitsKeepsItsSizeTheBoundaryIncluded() {
        XCTAssertEqual(Ev40ShareCardView.fitSize(base: 96, widthAtBase: 500, available: 936, floor: 48), 96)
        XCTAssertEqual(Ev40ShareCardView.fitSize(base: 96, widthAtBase: 936, available: 936, floor: 48), 96)
    }

    func testTextThatIsTooWideShrinksInProportionButNeverBelowTheFloor() {
        XCTAssertEqual(Ev40ShareCardView.fitSize(base: 96, widthAtBase: 1872, available: 936, floor: 48), 48)
        XCTAssertEqual(Ev40ShareCardView.fitSize(base: 96, widthAtBase: 1248, available: 936, floor: 48), 72)
        XCTAssertEqual(Ev40ShareCardView.fitSize(base: 96, widthAtBase: 9000, available: 936, floor: 48), 48)
    }

    func testAnEmptyStringDoesNotDivideByZero() {
        XCTAssertEqual(Ev40ShareCardView.fitSize(base: 32, widthAtBase: 0, available: 100, floor: 18), 32)
    }

    func testTheAddressGetsWhatTheTaglineLeavesLessTheGapAndNeverNothing() {
        XCTAssertEqual(Ev40ShareCardView.addressRoom(taglineWidth: 400), 512)
        XCTAssertEqual(Ev40ShareCardView.addressRoom(taglineWidth: 5000), 1)
    }
}
