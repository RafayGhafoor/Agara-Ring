import XCTest
import SwiftUI
@testable import PulseLoop

/// Themes come from docs/config/palette.yaml; the Activity tab's "Steps by hour" groups the ring's 5-minute
/// slots. Same cases as Android `ThemeStoreTest` / `HourRecordTest`.
final class ThemeAndHourlyTests: XCTestCase {
    override func tearDown() { ThemeStore.current = .dark }

    func testCatalogDefaultAndUniqueNames() {
        XCTAssertEqual(AgaraTheme.all.first?.name, "dark")
        XCTAssertEqual(Set(AgaraTheme.all.map(\.name)).count, AgaraTheme.all.count)
    }

    func testSelectingAThemeIsWhatAgaraColorsReads() {
        ThemeStore.select("light")
        XCTAssertEqual(ThemeStore.current.name, "light")
        ThemeStore.select("no-such-theme")
        XCTAssertEqual(ThemeStore.current.name, "light", "an unknown name leaves the theme alone")
        ThemeStore.select(nil)
        XCTAssertEqual(ThemeStore.current.name, "light")
    }

    func testHourlyGroupingKeepsOnlyHoursWithStepsNewestFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Karachi")!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: h, minute: m))! }
        let rows: [(timestamp: Date, steps: Int, distanceMeters: Double)] = [
            (at(8, 0), 30, 21), (at(8, 5), 6, 4), (at(8, 10), 0, 0), (at(9, 0), 0, 0), (at(9, 55), 53, 37), (at(10, 0), 0, 0),
        ]
        let out = StepsByHourCard.HourRecord.group(rows, calendar: cal)
        XCTAssertEqual(out.map(\.start), [at(9, 0), at(8, 0)])
        XCTAssertEqual(out.map(\.steps), [53, 36])
        XCTAssertTrue(StepsByHourCard.HourRecord.group((0..<190).map { (at($0 / 12, ($0 % 12) * 5), 0, 0) }, calendar: cal).isEmpty)
    }
}
