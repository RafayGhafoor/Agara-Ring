import Foundation

/// The week boundary every weekly surface uses (plan `asana-heart-bugs-2026-11-01`, item D / owner D3).
///
/// Why this exists: the week was hardcoded where it was not consistent — `AgaraServices.alignedWeekActivity` aligned
/// the activity chart to **Monday**, the weekly review compared a **rolling** 7 days against the previous 7, and the
/// notifications screen called the review's delivery day "Week starts". Users in different countries also start the
/// week on a different day (CLDR: Monday for most of the world, Sunday in the US/Canada/Japan, Saturday in much of the
/// Middle East), so a fixed day is wrong for most of the install base.
///
/// Numbering is the one the catalog and `Calendar` already use, so nothing converts at the boundary:
/// **1 = Sunday … 7 = Saturday**. Resolution order: the user's stored choice, else the **device locale**.
enum WeekStart {
    /// A stored value of `locale` means "follow the device" — the default for every install.
    static let locale = 0

    /// The device locale's first day of the week (1 = Sunday … 7 = Saturday).
    static func localeDay(_ calendar: Calendar = .current) -> Int { calendar.firstWeekday }

    /// The effective day: an explicit 1...7 wins, anything else (including `locale`) follows the device.
    static func day(stored: Int = locale, calendar: Calendar = .current) -> Int {
        (1...7).contains(stored) ? stored : localeDay(calendar)
    }

    /// The **last complete calendar week** and the week before it, as the `yyyy-MM-dd` strings the coach tools use
    /// (owner decision D14, option (a), 2026-11-01: Fitbit/Google Health's model — the week in progress is excluded
    /// because it is incomplete). Delivered on the week-start day, so "this week" is the one that just ended.
    struct Window {
        let thisStart: String, thisEnd: String, lastStart: String, lastEnd: String
    }

    static func weekReviewWindow(today: Date, day: Int = day(), calendar: Calendar = .current) -> Window {
        let currentWeekStart = startOfWeek(today, day: day, calendar: calendar)
        func shift(_ base: Date, _ days: Int) -> String {
            CoachDataAccess.localDateString(calendar.date(byAdding: .day, value: days, to: base) ?? base)
        }
        let thisStart = calendar.date(byAdding: .day, value: -7, to: currentWeekStart) ?? currentWeekStart
        let lastStart = calendar.date(byAdding: .day, value: -14, to: currentWeekStart) ?? currentWeekStart
        return Window(thisStart: shift(thisStart, 0), thisEnd: shift(thisStart, 6),
                      lastStart: shift(lastStart, 0), lastEnd: shift(lastStart, 6))
    }

    /// The first day of the week that contains `date` — idempotent, so a date that already IS the start returns
    /// itself and a second pass never walks back another week.
    static func startOfWeek(_ date: Date, day: Int = day(), calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = day
        let start = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: start)
        let back = (weekday - day + 7) % 7
        return cal.date(byAdding: .day, value: -back, to: start) ?? start
    }
}
