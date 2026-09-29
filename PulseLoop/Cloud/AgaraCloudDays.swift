import Foundation
import SwiftData

/// Day rows (`health_days`: steps, distance, calories and the night's sleep summary) — the part of the sync that is not
/// blocks. Building them from the store, and turning pulled ones back into the events the persistence path understands.
enum AgaraCloudDays {
    /// Aggregate the sleeping-day's stage blocks into the durations the cloud record carries. Only the displayed
    /// sessions count (the paired ring's night, `SleepSourcePolicy`), and `quality` is the stored score — the one the
    /// Sleep tab shows (D1).
    ///
    /// `SleepDayRule` (same as Android): the night window and score are the **main sleep's** (the longest session); the
    /// stage minutes are summed over the main sleep **and its naps**, so the record's total carries the naps too.
    @MainActor
    static func sleepSummary(for day: Date, context: ModelContext, calendar: Calendar = .current)
        -> (startAt: Date, endAt: Date, deep: Int, light: Int, awake: Int, other: Int, quality: Int)? {
        let sessions = SleepRepository.sessions(context: context).filter { calendar.isDate($0.date, inSameDayAs: day) }
        let blocks = (try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []
        return summarise(sessions: sessions, blocks: blocks)
    }

    @MainActor
    private static func summarise(sessions: [SleepSession], blocks: [SleepStageBlock])
        -> (startAt: Date, endAt: Date, deep: Int, light: Int, awake: Int, other: Int, quality: Int)? {
        guard let split = SleepDayRule.split(sessions, minutes: { $0.totalMinutes }, start: { $0.startAt }) else { return nil }
        let session = split.main
        let ids = Set(sessions.map(\.id))
        var deep = 0, light = 0, awake = 0, other = 0
        for block in blocks where ids.contains(block.sessionId) {
            switch block.stage {
            case .deep: deep += block.durationMinutes
            case .light: light += block.durationMinutes
            case .awake: awake += block.durationMinutes
            case .rem, .unknown: other += block.durationMinutes
            }
        }
        return (session.startAt, session.endAt, deep, light, awake, other, session.score ?? 0)
    }

    /// `yyyy-MM-dd` in the calendar's zone — the server's `date`.
    nonisolated static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// `yyyy-MM-dd` → the start of that day in `calendar`, or nil for anything that is not a date.
    nonisolated static func parseDay(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Every local day that has activity or a night, as day rows, oldest first. Computed with one fetch of each table.
    @MainActor
    static func dayRows(context: ModelContext, calendar: Calendar = .current) -> [WireDay] {
        let activity = (try? context.fetch(FetchDescriptor<ActivityDaily>())) ?? []
        // A defensive fold by day: the app can hold more than one ActivityDaily row per date and the server keys on the date.
        // Sample / demo days (`mock`) are never uploaded, nor is the night of such a day.
        var byDay: [String: ActivityDaily] = [:]
        var mockDays = Set<String>()
        for row in activity {
            let key = dayString(row.date, calendar: calendar)
            if isMockSource(row.source) { mockDays.insert(key); continue }
            byDay[key] = row
        }
        let sessions = SleepRepository.sessions(context: context).filter { !mockDays.contains(dayString($0.date, calendar: calendar)) }
        let sessionsByDay = Dictionary(grouping: sessions) { dayString($0.date, calendar: calendar) }
        let blocks = sessions.isEmpty ? [] : ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])

        var rows: [WireDay] = []
        for key in Set(byDay.keys).union(sessionsByDay.keys).sorted() {
            let day = byDay[key]
            let sleep = sessionsByDay[key].flatMap { summarise(sessions: $0, blocks: blocks) }
            let steps = day?.steps ?? 0
            let distanceKm = (day?.distanceMeters ?? 0) / 1000
            let calories = day?.calories ?? 0
            if steps == 0, distanceKm == 0, calories == 0, sleep == nil { continue }   // nothing to say about this day
            rows.append(WireDay(
                date: key, steps: steps, distanceKm: (distanceKm * 1000).rounded() / 1000, calories: (calories * 10).rounded() / 10,
                sleepStart: sleep.map { WireCodec.rfc3339($0.startAt) }, sleepEnd: sleep.map { WireCodec.rfc3339($0.endAt) },
                deep: sleep?.deep ?? 0, light: sleep?.light ?? 0, awake: sleep?.awake ?? 0, other: sleep?.other ?? 0,
                sleepMinutes: sleep.map { max(0, Int($0.endAt.timeIntervalSince($0.startAt) / 60)) } ?? 0,
                sleepScore: sleep?.quality ?? 0))
        }
        return rows
    }

    /// `mock` (sample data) and `demo` rows are never synced.
    nonisolated static func isMockSource(_ source: String) -> Bool { ["mock", "demo"].contains(source.lowercased()) }

    /// Stable fingerprint of a day row (SHA-256 of its canonical JSON), so an unchanged day is not sent again.
    nonisolated static func fingerprint(_ day: WireDay) -> String {
        AGB.hex(AGB.sha256(Data(WireBlockBuilder.json(day).utf8)))
    }

    // MARK: Pull

    /// Pulled day rows → ring events (the same persistence path a BLE sync and the backfill use). Activity is applied only
    /// when the server's steps exceed the local ones (the server's own rule is "maximum"); a night only when no session
    /// exists locally for that day — the cloud never replaces a night the ring wrote.
    static func events(days: [WireDay], localSteps: [String: Int], localSleepDays: Set<String>, calendar: Calendar = .current)
        -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for day in days {
            guard let date = parseDay(day.date, calendar: calendar) else { continue }
            if day.steps > (localSteps[day.date] ?? 0) {
                events.append(.activityUpdate(timestamp: date, steps: day.steps,
                                              distanceMeters: max(0, day.distanceKm) * 1000, calories: max(0, day.calories)))
            }
            if !localSleepDays.contains(day.date),
               let startText = day.sleepStart, let endText = day.sleepEnd,
               let start = WireCodec.parseDate(startText), let end = WireCodec.parseDate(endText), end > start {
                func clamp(_ v: Int) -> Int { min(max(v, 0), 24 * 60) }   // a negative count would trap `Array(repeating:count:)`
                let stages = [SleepStage](repeating: .deep, count: clamp(day.deep))
                    + [SleepStage](repeating: .light, count: clamp(day.light))
                    + [SleepStage](repeating: .awake, count: clamp(day.awake))
                    + [SleepStage](repeating: .unknown, count: clamp(day.other))
                events.append(.sleepTimeline(timestamp: start, stages: stages, source: SleepSource.cloud))
            }
        }
        return events
    }

    /// Local steps and sleep days, for `events(days:…)`.
    @MainActor
    static func localState(context: ModelContext, calendar: Calendar = .current) -> (steps: [String: Int], sleepDays: Set<String>) {
        var steps: [String: Int] = [:]
        for row in (try? context.fetch(FetchDescriptor<ActivityDaily>())) ?? [] {
            let key = dayString(row.date, calendar: calendar)
            steps[key] = max(steps[key] ?? 0, row.steps)
        }
        let sleepDays = Set(SleepRepository.allSessions(context: context).map { dayString($0.date, calendar: calendar) })
        return (steps, sleepDays)
    }
}
