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

    // MARK: - The weekly review window (D14 option (a): the last COMPLETE calendar week)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testTheReviewCoversTheLastCompleteCalendarWeek() {
        let cal = calendar("en_GB")   // Monday start
        // Wednesday 2026-11-04 → the week just ended is Mon 10-26 … Sun 11-01. A rolling 7 days would have said
        // 10-28…11-03, i.e. part of the CURRENT week — which is why "week starts" meant nothing before.
        let w = WeekStart.weekReviewWindow(today: date(2026, 11, 4, cal), day: 2, calendar: cal)
        XCTAssertEqual(w.thisStart, "2026-10-26")
        XCTAssertEqual(w.thisEnd, "2026-11-01")
        XCTAssertEqual(w.lastStart, "2026-10-19")
        XCTAssertEqual(w.lastEnd, "2026-10-25")
    }

    func testTheReviewWindowIsStableThroughTheCurrentWeek() {
        let cal = calendar("en_GB")
        let monday = WeekStart.weekReviewWindow(today: date(2026, 11, 2, cal), day: 2, calendar: cal)
        let sunday = WeekStart.weekReviewWindow(today: date(2026, 11, 8, cal), day: 2, calendar: cal)
        XCTAssertEqual(monday.thisStart, sunday.thisStart)
        XCTAssertEqual(monday.thisEnd, sunday.thisEnd)
        XCTAssertEqual(monday.lastStart, sunday.lastStart)
        XCTAssertEqual(monday.lastEnd, sunday.lastEnd)
    }

    func testASundayStartUserGetsTheirOwnWeek() {
        let cal = calendar("en_US")   // Sunday start
        // Sunday 2026-11-01 IS the week-start day, so the completed week is the one before it: 10-25 … 10-31.
        let w = WeekStart.weekReviewWindow(today: date(2026, 11, 1, cal), day: 1, calendar: cal)
        XCTAssertEqual(w.thisStart, "2026-10-25")
        XCTAssertEqual(w.thisEnd, "2026-10-31")
    }

    func testTheTwoWindowsAreAdjacentSevenDayBlocks() {
        let cal = calendar("en_GB")
        let w = WeekStart.weekReviewWindow(today: date(2026, 11, 4, cal), day: 2, calendar: cal)
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let thisStart = f.date(from: w.thisStart)!
        let thisEnd = f.date(from: w.thisEnd)!
        let lastStart = f.date(from: w.lastStart)!
        let lastEnd = f.date(from: w.lastEnd)!
        XCTAssertEqual(cal.dateComponents([.day], from: thisStart, to: thisEnd).day, 6)
        XCTAssertEqual(cal.dateComponents([.day], from: lastStart, to: lastEnd).day, 6)
        XCTAssertEqual(cal.dateComponents([.day], from: lastEnd, to: thisStart).day, 1)
    }

    // MARK: - The user's own choice (D3: "user-visible and configurable")

    func testAnInstalledChoiceGovernsEveryWeeklySurface() throws {
        defer { WeekStart.install(WeekStart.locale) }
        let cal = calendar("en_GB")            // the device says Monday…
        WeekStart.install(1)                   // …the user picked Sunday
        XCTAssertEqual(WeekStart.day(calendar: cal), 1)
        XCTAssertEqual(WeekStart.day(stored: 1, calendar: cal), 1)
        // …and the review window moves with it: Wednesday 2026-11-04 → the week just ended starts Sun 10-25.
        let w = WeekStart.weekReviewWindow(today: date(2026, 11, 4, cal), day: 1, calendar: cal)
        XCTAssertEqual(w.thisStart, "2026-10-25")
        XCTAssertEqual(w.thisEnd, "2026-10-31")
    }

    func testFollowTheDeviceAndCorruptValuesFallBackToTheLocale() {
        defer { WeekStart.install(WeekStart.locale) }
        WeekStart.install(7)
        XCTAssertEqual(WeekStart.day(calendar: calendar("en_US")), 7)
        WeekStart.install(WeekStart.locale)
        XCTAssertEqual(WeekStart.day(calendar: calendar("en_US")), 1, "0 restores the device default")
        WeekStart.install(42)
        XCTAssertEqual(WeekStart.day(calendar: calendar("en_GB")), 2, "a corrupt value behaves as follow-the-device")
    }

    func testThePrefsStoreRoundTripsThroughDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "weekStartTests"))
        suite.removeObject(forKey: WeekStartPrefs.key)
        defer { suite.removeObject(forKey: WeekStartPrefs.key); WeekStart.install(WeekStart.locale) }

        XCTAssertEqual(WeekStartPrefs.stored(suite), WeekStart.locale, "unset means follow the device")
        WeekStartPrefs.install(3, defaults: suite)
        XCTAssertEqual(WeekStartPrefs.stored(suite), 3)
        XCTAssertEqual(WeekStartPrefs.installFromDefaults(suite), 3)
        XCTAssertEqual(WeekStart.day(calendar: calendar("en_GB")), 3, "the installed choice wins over the region")
        WeekStartPrefs.install(99, defaults: suite)   // corrupt: clamped to follow-the-device
        XCTAssertEqual(WeekStartPrefs.stored(suite), WeekStart.locale)
    }

    // MARK: - The metric-detail week window (item D gap #2, 2026-11-05)

    /// `.sevenDays` used to be `now − 7 × 24 h`, so the vitals chart and its readings list started on a different day
    /// from the activity chart's aligned week — and from Android. It is now the calendar week on the user's boundary.
    func testTheSevenDayMetricWindowStartsOnTheUsersWeekStart() throws {
        let cal = calendar("en_GB")
        let wednesday = date(2026, 10, 14, cal).addingTimeInterval(13 * 3600)   // a Wednesday, mid-week
        TestSupport.withClock("2026-10-14T13:00:00") {
            let cutoff = MetricsService.cutoff(for: .sevenDays)
            let resolved = WeekStart.day()
            XCTAssertEqual(cutoff, WeekStart.startOfWeek(wednesday, day: resolved, calendar: cal),
                           "the metric week starts on the resolved week-start day, not 7 days back")
            XCTAssertEqual(cal.component(.weekday, from: cutoff), resolved)
            XCTAssertEqual(cal.startOfDay(for: cutoff), cutoff, "and at local midnight")
            XCTAssertLessThan(cutoff, wednesday, "the window still contains now")
        }
    }

    /// The resolution order has to reach this window too: an installed Sunday must beat a Monday locale.
    func testAnInstalledSundayMovesTheMetricWindow() throws {
        let cal = calendar("en_GB")   // would otherwise start on Monday
        WeekStart.install(1)
        defer { WeekStart.install(WeekStart.locale) }
        let thursday = date(2026, 10, 15, cal).addingTimeInterval(9 * 3600)
        TestSupport.withClock("2026-10-15T09:00:00") {
            let cutoff = MetricsService.cutoff(for: .sevenDays)
            XCTAssertEqual(cutoff, WeekStart.startOfWeek(thursday, day: 1, calendar: cal),
                           "the stored Sunday start governs the vitals week, not the en_GB Monday")
            XCTAssertEqual(cal.component(.weekday, from: cutoff), 1, "Sunday")
            XCTAssertEqual(cal.startOfDay(for: cutoff), cutoff)
        }
    }
}
