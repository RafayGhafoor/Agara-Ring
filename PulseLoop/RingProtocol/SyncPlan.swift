import Foundation

/// Which history days a refresh asks the ring for, and from which record — the one sync-plan block (AGENTS.md
/// Rule 10; owner feedback 2026-09-26 in `docs/process/plans/consistency-framework.md`). Mirrors Android's
/// `SyncPlan`.
///
/// A past day (offset ≥ 1) doesn't change once the ring has closed it, so re-downloading days 1–6 on every
/// refresh is wasted air time (a full past day is hundreds of DF frames). The rule, per ring and per date:
///
/// * a **past day** is *complete* once its transfer (from position 1) ended on the `DF FF FF` end marker and the
///   unbroken run of stored records from record 1 reached the DF header's `total_blocks`; a complete day is
///   skipped from then on;
/// * **day 0** is always requested — from `storedThrough + 1`, the record after the unbroken run from record 1
///   (position 1 when nothing of today is stored). A record missing mid-day is therefore asked for again rather
///   than left as a gap — Android's rule, identical here (Rule 2);
/// * a ring with no ledger (new pairing, another ring) or a date not yet complete is fetched in full.
///
/// Sleep (`E0 <day>`) keeps its rule: a day in the plan is asked for its sleep as before; a skipped day is
/// skipped whole (its night was stored when the day was fetched in full).
struct SyncPlan: Equatable {
    /// One day of the pass: the ring's day offset (0 = today) and the 1-based DF record position to start from.
    struct Day: Equatable {
        let offset: Int
        let position: Int
    }

    let days: [Day]

    var offsets: [Int] { days.map(\.offset) }

    /// What the app knows about one date of one ring.
    struct DayState: Codable, Equatable {
        /// Every record `1…storedThrough` of the date is stored — a contiguous watermark over record numbers (the
        /// DF record index, 1-based LE of bytes 1–2), so a record lost mid-transfer is asked for again.
        var storedThrough: Int = 0
        /// The DF header's `total_blocks` (bytes 4–5, LE) — the ring's own record count for the day.
        var totalBlocks: Int = 0
        /// The day's sleep (`E0` transfer) reached storage — or the ring genuinely answered no-data for it.
        /// BUG-203: "complete" used to be a statement about the DF records alone, so a day whose sleep
        /// transfer produced nothing was closed for good and its night could never be recovered. Decoded
        /// with a default, so a ledger written before this field reads as "no sleep stored".
        var sleepStored: Bool = false
        /// The day is closed and fully received: skip it from now on.
        var complete: Bool = false
    }

    /// How many days back a *complete* day whose sleep never reached storage is still asked for its sleep —
    /// the ring keeps about three, so this is the window in which the heal can succeed (BUG-203).
    static let healWindowDays = 3

    /// Day `offset`'s date, counted back from `today` (midnight). A DF record is dated by it (BUG-102).
    static func date(offset: Int, today: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }

    /// The `yyyy-MM-dd` key of day `offset` counted back from `today`.
    static func dateKey(offset: Int, today: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: today)
        let date = calendar.date(byAdding: .day, value: -offset, to: start) ?? start
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Plan a pass over `historyDays` days. `ledger` is the ring's date → state map; nil when the link has no
    /// identity to key it by, which means every day in full (tests' writers, a link without a peripheral).
    static func make(historyDays: Int, today: Date, calendar: Calendar, ledger: [String: DayState]?) -> SyncPlan {
        let count = max(1, historyDays)
        guard let ledger else {
            return SyncPlan(days: (0..<count).map { Day(offset: $0, position: 1) })
        }
        var days: [Day] = []
        for offset in 0..<count {
            let state = ledger[dateKey(offset: offset, today: today, calendar: calendar)]
            if offset == 0 {
                days.append(Day(offset: 0, position: (state?.storedThrough ?? 0) + 1))
            } else if state?.complete != true {
                days.append(Day(offset: offset, position: 1))
            } else if state?.sleepStored == false, offset <= healWindowDays {
                // BUG-203 heal: the day's records are stored but its night never arrived, and days already
                // marked complete in the field have the same hole. Ask for it once more while the ring still
                // holds it, resuming after the watermark so the DF half answers the end marker at once.
                days.append(Day(offset: offset, position: (state?.storedThrough ?? 0) + 1))
            }
        }
        return SyncPlan(days: days)
    }

    /// The date's state after one transfer of day `offset` from `position`.
    ///
    /// - `records`: record numbers received intact this transfer.
    /// - `totalBlocks`: the DF header's day record count, nil when no header arrived (an empty day, or a
    ///   resume past the last record).
    /// - `endMarker`: the transfer ended on `DF FF FF` (false when the stall watchdog closed it).
    ///
    /// A full transfer (position 1) starts the watermark over; a resume continues it from the records stored
    /// before `position`. The watermark then extends over every consecutive record received. Only a past day
    /// fetched whole can become complete (today keeps growing); without a header nothing says how many records
    /// the day holds — unless nothing came at all: a day the ring kept nothing for answers the end marker alone.
    /// Same as Android's `SyncPlan.afterDay`.
    static func record(_ prior: DayState?, offset: Int, position: Int, records: Set<Int>,
                       totalBlocks: Int?, endMarker: Bool, sleepStored: Bool = false) -> DayState {
        var through = position <= 1 ? 0 : min(prior?.storedThrough ?? 0, position - 1)
        while records.contains(through + 1) { through += 1 }
        let total = totalBlocks ?? (position <= 1 ? 0 : prior?.totalBlocks ?? 0)
        // BUG-203: the day is complete only when its **sleep** is in storage too (or the ring said it kept
        // none). A heal request (`position > 1`) never re-completes a day by itself: it only refreshes the
        // sleep flag, so the day leaves the walk once a night (or a no-data answer) arrives.
        let receivedAll = position <= 1 && endMarker && (totalBlocks != nil || records.isEmpty) && through >= total
        let complete = offset >= 1 && receivedAll && sleepStored
        return DayState(storedThrough: through, totalBlocks: total, sleepStored: sleepStored, complete: complete)
    }
}

/// The per-ring, per-date ledger behind `SyncPlan`, kept in `UserDefaults` (a few hundred bytes).
///
/// Cleared for a ring when it is paired again, and entirely when the ring is forgotten or the app's data is
/// wiped — "stored" must stay true, or a skipped day would never come back.
@MainActor
final class SyncPlanStore {
    static let shared = SyncPlanStore()

    /// New key, not install-bound upstream state — so it takes the `agara.` prefix.
    static let key = "agara.syncPlan.v1"
    /// Dates older than this are dropped on write (the ring holds ~3 days; the loop walks 7 by default).
    static let keepDays = 60

    private let defaults: UserDefaults
    private var cache: [String: [String: SyncPlan.DayState]]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: [String: SyncPlan.DayState]] {
        if let cache { return cache }
        let decoded = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: [String: SyncPlan.DayState]].self, from: $0) } ?? [:]
        cache = decoded
        return decoded
    }

    private func save(_ value: [String: [String: SyncPlan.DayState]]) {
        cache = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
    }

    func ledger(ring: String) -> [String: SyncPlan.DayState] { all[ring] ?? [:] }

    func state(ring: String, date: String) -> SyncPlan.DayState? { all[ring]?[date] }

    func set(_ state: SyncPlan.DayState, ring: String, date: String, today: Date = AppClock.now, calendar: Calendar = .current) {
        var value = all
        var dates = value[ring] ?? [:]
        dates[date] = state
        let oldest = SyncPlan.dateKey(offset: Self.keepDays, today: today, calendar: calendar)
        dates = dates.filter { $0.key >= oldest }
        value[ring] = dates
        save(value)
    }

    /// A new pairing of `ring`: its next pass downloads every day in full.
    func reset(ring: String) {
        var value = all
        value[ring] = nil
        save(value)
    }

    /// The ring was forgotten or the data wiped.
    func resetAll() {
        cache = [:]
        defaults.removeObject(forKey: Self.key)
    }
}
