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

    // MARK: The numbers the share card adds (plan ev40-share-card-v2, A1/A2/A3)

    /// Consecutive local dates carrying at least one tick, ending **today** — or **yesterday** when today has had no tick
    /// yet, so the card does not read "0-day streak" at breakfast (plan D4.2). A gap of one day breaks the run, and a
    /// history with no ticks at all is 0.
    nonisolated static func streak(tickedKeys: Set<String>, today: String,
                                  calendar: Calendar = .current) -> Int {
        guard let todayDate = Ev40Repo.date(today, calendar: calendar) else { return 0 }
        var cursor = calendar.startOfDay(for: todayDate)
        if !tickedKeys.contains(today) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  tickedKeys.contains(key(yesterday, calendar: calendar)) else { return 0 }
            cursor = yesterday
        }
        var days = 0
        while tickedKeys.contains(key(cursor, calendar: calendar)) {
            days += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return days
    }

    /// Days from the challenge's first ticked day through **today** that ended with all eight ticked (A2, and the
    /// perfect-day state A4). Days after today are ignored: the card describes the journey so far.
    nonisolated static func perfectDays(masksByKey: [String: Int], today: String,
                                       calendar: Calendar = .current) -> Int {
        daysThroughToday(masksByKey: masksByKey, today: today, calendar: calendar) { Ev40Disciplines.isComplete($0) }
    }

    /// Days from the challenge's first ticked day through **today** that carried at least one tick (A2).
    nonisolated static func daysActive(masksByKey: [String: Int], today: String,
                                      calendar: Calendar = .current) -> Int {
        daysThroughToday(masksByKey: masksByKey, today: today, calendar: calendar) { $0 != 0 }
    }

    /// A day's mask as a heat level: 0 none, 1 one or two ticks, 2 three or four, 3 five to seven, 4 all eight (A3).
    /// The share card's grid and both platforms' shading come from this one table.
    nonisolated static func level(mask: Int) -> Int {
        switch Ev40Disciplines.count(mask) {
        case 0: 0
        case 1...2: 1
        case 3...4: 2
        case 5...7: 3
        default: 4
        }
    }

    /// Count the local days from the challenge's start (`dayNumber`'s own rule: the earliest ticked day) through `today`
    /// whose mask `matches` accepts.
    private nonisolated static func daysThroughToday(masksByKey: [String: Int], today: String, calendar: Calendar,
                                                     matches: (Int) -> Bool) -> Int {
        guard let startKey = masksByKey.filter({ Ev40Disciplines.count($0.value) > 0 }).keys.min(),
              let start = Ev40Repo.date(startKey, calendar: calendar),
              let end = Ev40Repo.date(today, calendar: calendar) else { return 0 }
        let last = calendar.startOfDay(for: end)
        var days = 0
        var cursor = calendar.startOfDay(for: start)
        while cursor <= last {
            if matches(masksByKey[key(cursor, calendar: calendar)] ?? 0) { days += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}
