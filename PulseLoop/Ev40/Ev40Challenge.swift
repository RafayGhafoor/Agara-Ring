import Foundation

/// Which day of the 40-day EV40 challenge today is.
///
/// **Derived, not stored.** The day number comes from the earliest day that carries at least one tick — the same rule
/// the history log uses (`Ev40Repo.log` skips an all-zero day, which is a day someone opened the screen on and did
/// nothing with). Deriving it means the number follows the cloud-synced `ev40_days` history, so two devices show the
/// same "Day N of 40" once they have synced; a stored counter would have to be synced itself and could disagree.
///
/// The denominator is the shared catalog value (`AgaraConfig.Ev40.challengeDays`, `docs/config/shared.yaml`) so both
/// platforms change it together (Rule 5).
enum Ev40Challenge {
    /// Length of the challenge in days ("Day 14 of 40").
    static let totalDays = AgaraConfig.Ev40.challengeDays

    /// The day's own key for a date, in the same local-date form the rows are stored under.
    nonisolated static func key(_ date: Date, calendar: Calendar = .current) -> String {
        Ev40Repo.dayKey(date, calendar: calendar)
    }

    /// Day number for `today`, 1-based — or nil when the challenge has not started (no ticked day at all).
    ///
    /// `trackedKeys` are `ev40_days` date keys; rows with no ticks must be filtered out by the caller, or an empty day
    /// someone merely visited would start the challenge.
    nonisolated static func dayNumber(trackedKeys: [String], today: String,
                                     calendar: Calendar = .current) -> Int? {
        guard let startKey = trackedKeys.min(), let start = Ev40Repo.date(startKey, calendar: calendar),
              let now = Ev40Repo.date(today, calendar: calendar) else { return nil }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: start),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return max(1, days + 1)
    }

    /// "Day 14 of 40", or nil when the challenge has not started or has run past its length.
    nonisolated static func label(dayNumber: Int?) -> String? {
        guard let day = dayNumber, day >= 1, day <= totalDays else { return nil }
        return "Day \(day) of \(totalDays)"
    }

    /// Convenience for the screens: today's number straight from a fetched history (`[Ev40Day]`, any order).
    static func todayDayNumber(_ days: [Ev40Day], now: Date = AppClock.now, calendar: Calendar = .current) -> Int? {
        dayNumber(trackedKeys: days.filter { Ev40Disciplines.count($0.mask) > 0 }.map(\.dateKey),
                  today: key(now, calendar: calendar), calendar: calendar)
    }
}
