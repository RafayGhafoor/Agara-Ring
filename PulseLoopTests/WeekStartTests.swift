import XCTest
@testable import PulseLoop

/// The week boundary (plan `asana-heart-bugs-2026-11-01`, item D / owner D3). Mirrors Android's `WeekStartTest`:
/// the default comes from the device locale, an explicit choice wins, and the boundary is idempotent.
final class WeekStartTests: XCTestCase {

    private func calendar(_ localeId: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: localeId)
        cal.firstWeekday = Locale(identifier: localeId).calendar.firstWeekday
        return cal
    }

    func testLocaleDefaultsMatchCldr() {
        XCTAssertEqual(WeekStart.localeDay(calendar("en_US")), 1, "en_US starts on Sunday")
        XCTAssertEqual(WeekStart.localeDay(calendar("en_GB")), 2, "en_GB starts on Monday")
        XCTAssertEqual(WeekStart.localeDay(calendar("de_DE")), 2, "de_DE starts on Monday")
        XCTAssertEqual(WeekStart.localeDay(calendar("ja_JP")), 1, "ja_JP starts on Sunday")
        XCTAssertEqual(WeekStart.localeDay(calendar("ar_EG")), 7, "ar_EG starts on Saturday")
    }

    func testAnExplicitChoiceWins() {
        XCTAssertEqual(WeekStart.day(stored: 2, calendar: calendar("en_US")), 2)
        XCTAssertEqual(WeekStart.day(stored: 7, calendar: calendar("en_GB")), 7)
        XCTAssertEqual(WeekStart.day(stored: WeekStart.locale, calendar: calendar("en_US")), 1)
        XCTAssertEqual(WeekStart.day(stored: 42, calendar: calendar("en_GB")), 2, "a corrupted value falls back")
    }

    func testStartOfWeekIsIdempotent() throws {
        let cal = calendar("en_GB")
        let wednesday = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        let monday = WeekStart.startOfWeek(wednesday, day: 2, calendar: cal)
        XCTAssertEqual(cal.startOfDay(for: monday), monday)
        XCTAssertEqual(monday, cal.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        XCTAssertEqual(monday, WeekStart.startOfWeek(monday, day: 2, calendar: cal),
                       "the second pass returns the same day")
    }

    func testTheDayBeforeTheStartBelongsToThePreviousWeek() throws {
        let cal = calendar("en_US")
        let sunday = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        // With a Sunday start that Sunday is the start…
        XCTAssertEqual(sunday, WeekStart.startOfWeek(sunday, day: 1, calendar: cal))
        // …and with a Monday start it is the last day of the previous week.
        XCTAssertEqual(cal.date(from: DateComponents(year: 2026, month: 10, day: 26)),
                       WeekStart.startOfWeek(sunday, day: 2, calendar: cal))
    }
}
