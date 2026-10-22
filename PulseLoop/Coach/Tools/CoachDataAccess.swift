import Foundation
import SwiftData

/// Date-range reads over the existing repositories, shared by retrieval,
/// charting, and analysis tools. The LLM never queries SwiftData directly — it
/// only ever reaches data through these deterministic helpers (the iOS analogue
/// of the web app's tool data layer).
@MainActor
enum CoachDataAccess {
    /// Inclusive local-date bounds parsed from "YYYY-MM-DD" (time component ignored).
    static func dayBounds(_ start: String, _ end: String) -> (start: Date, end: Date)? {
        guard let s = parseLocalDate(start), let e = parseLocalDate(end) else { return nil }
        let cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e)) ?? e
        return (cal.startOfDay(for: s), endOfDay)
    }

    static func parseLocalDate(_ value: String) -> Date? {
        let trimmed = String(value.prefix(10))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        if let d = f.date(from: trimmed) { return d }
        // Fall back to ISO datetime.
        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }

    static func localDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    static func localTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f.string(from: date)
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Reads

    static func measurements(
        kind: MeasurementKind, start: String, end: String, context: ModelContext
    ) -> [Measurement] {
        guard let bounds = dayBounds(start, end) else { return [] }
        // Windowed DB query (predicate + limit) instead of fetching the whole table and filtering.
        return MetricsRepository.measurements(kind: kind, start: bounds.start, end: bounds.end, limit: 5000, context: context)
            .sorted { $0.timestamp < $1.timestamp }
    }

    static func activityRows(start: String, end: String, context: ModelContext) -> [ActivityDaily] {
        guard let bounds = dayBounds(start, end) else { return [] }
        return MetricsRepository.activityRows(context: context)
            .filter { $0.date >= bounds.start && $0.date < bounds.end }
            .sorted { $0.date < $1.date }
    }

    static func activityRow(on date: String, context: ModelContext) -> ActivityDaily? {
        guard let day = parseLocalDate(date) else { return nil }
        return MetricsRepository.activity(on: day, context: context)
    }

    static func sleepSessions(start: String, end: String, context: ModelContext) -> [SleepSession] {
        guard let bounds = dayBounds(start, end) else { return [] }
        return SleepRepository.sessions(context: context)
            .filter { $0.date >= bounds.start && $0.date < bounds.end }
            .sorted { $0.date < $1.date }
    }

    static func activitySessions(start: String, end: String, context: ModelContext) -> [ActivitySession] {
        guard let bounds = dayBounds(start, end) else { return [] }
        return ActivityRepository.sessions(context: context)
            .filter { $0.startedAt >= bounds.start && $0.startedAt < bounds.end }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Stats

    struct Stats: Encodable {
        var count: Int
        var avg: Double?
        var min: Double?
        var max: Double?
    }

    static func stats(_ values: [Double]) -> Stats {
        guard !values.isEmpty else { return Stats(count: 0, avg: nil, min: nil, max: nil) }
        let avg = (values.reduce(0, +) / Double(values.count)).rounded(toPlaces: 1)
        return Stats(count: values.count, avg: avg, min: values.min(), max: values.max())
    }

    /// Daily-aligned value series for a metric over a range, used by analysis +
    /// charts. Activity metrics come from daily rollups; hr/spo2 are averaged per
    /// day; sleep uses total minutes per night.
    static func dailySeries(
        metric: CoachChartMetric, start: String, end: String, context: ModelContext
    ) -> [(date: Date, value: Double)] {
        switch metric {
        case .steps, .calories, .distance, .activeMinutes:
            return activityRows(start: start, end: end, context: context).map { row in
                let v: Double
                switch metric {
                case .steps: v = Double(row.steps)
                case .calories: v = row.calories
                case .distance: v = row.distanceMeters / 1000
                case .activeMinutes: v = Double(row.activeMinutes)
                default: v = 0
                }
                return (row.date, v)
            }
        case .hr, .spo2, .stress, .respRate:
            let rows = measurements(kind: measurementKind(metric)!, start: start, end: end, context: context)
            let cal = Calendar.current
            let grouped = Dictionary(grouping: rows) { cal.startOfDay(for: $0.timestamp) }
            return grouped.map { day, ms in
                (day, (ms.map(\.value).reduce(0, +) / Double(ms.count)).rounded(toPlaces: 1))
            }.sorted { $0.date < $1.date }
        case .intensityMinutes:
            // One MET value per 5-minute record; MET ≥ 3 is moderate-or-harder activity. A day with records but no
            // intense minutes is a real 0, so every day with MET data is kept.
            let rows = measurements(kind: .met, start: start, end: end, context: context)
            let cal = Calendar.current
            return Dictionary(grouping: rows) { cal.startOfDay(for: $0.timestamp) }
                .map { day, ms in (day, Double(ms.filter { $0.value >= 3 }.count * 5)) }
                .sorted { $0.date < $1.date }
        case .sleep, .restingHr, .sleepScore, .bedtime, .wakeTime, .sleepAwake:
            return sleepDays(start: start, end: end, context: context).compactMap { day in
                sleepDayValue(metric, day, context: context).map { (day.date, $0) }
            }
        }
    }

    /// The stored measurement kind behind a sampled metric (nil for rollup / sleep metrics).
    static func measurementKind(_ metric: CoachChartMetric) -> MeasurementKind? {
        switch metric {
        case .hr: return .heartRate
        case .spo2: return .spo2
        case .stress: return .stress
        case .respRate: return .respiratoryRate
        case .intensityMinutes: return .met
        default: return nil
        }
    }

    // MARK: - Sleep days (coach insights, 2026-10-22)

    /// One waking day's sleep: the main sleep (longest session) and its naps (`SleepDayRule`), dated by the day the
    /// night ENDS (a night starting Sat 23:00 belongs to Sunday) — `night` spells it out for the model.
    struct CoachSleepDay {
        let date: Date
        let main: SleepSession
        let naps: [SleepSession]
        var night: String { CoachDataAccess.nightLabel(main) }
    }

    static func sleepDays(start: String, end: String, context: ModelContext) -> [CoachSleepDay] {
        let cal = Calendar.current
        return Dictionary(grouping: sleepSessions(start: start, end: end, context: context)) { cal.startOfDay(for: $0.date) }
            .compactMap { date, sessions in
                SleepDayRule.split(sessions, minutes: { $0.totalMinutes }, start: { $0.startAt })
                    .map { CoachSleepDay(date: date, main: $0.main, naps: $0.naps) }
            }
            .sorted { $0.date < $1.date }
    }

    /// "Sat 17 → Sun 18 Oct": the evening the main sleep started and the morning it ended.
    static func nightLabel(_ session: SleepSession) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d"
        let evening = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: session.date)) ?? session.date
        let m = DateFormatter()
        m.locale = Locale(identifier: "en_GB")
        m.dateFormat = "EEE d MMM"
        return "\(f.string(from: evening)) → \(m.string(from: session.date))"
    }

    static func sleepDayValue(_ metric: CoachChartMetric, _ day: CoachSleepDay, context: ModelContext) -> Double? {
        switch metric {
        case .sleep:
            return Double(([day.main] + day.naps).reduce(0) { $0 + max(0, $1.totalMinutes) })
        case .bedtime:
            return CoachSignalsBuilder.centeredBedMinute(CoachSignals.minuteOfDay(day.main.startAt))
        case .wakeTime:
            return Double(CoachSignals.minuteOfDay(day.main.endAt))
        case .sleepScore:
            let main = SleepService.summary(for: day.main, context: context)
            let naps = day.naps.map { SleepService.summary(for: $0, context: context) }
            return Double(SleepDay(main: main, naps: naps).score.score)
        case .sleepAwake:
            return Double(([day.main] + day.naps).reduce(0) { $0 + SleepService.summary(for: $1, context: context).awakeMinutes })
        case .restingHr:
            // The nudge engine's rule: the lowest heart rate recorded during the main sleep. No reading → no value.
            let hr = MetricsRepository.measurements(kind: .heartRate, start: day.main.startAt, end: day.main.endAt,
                                                    limit: 2000, context: context)
            return hr.map(\.value).filter { $0 > 0 }.min()
        default:
            return nil
        }
    }

    // MARK: - Coverage (use case 12: know when the evidence is too thin)

    /// How much data stands behind a metric over a range. Attached to every analysis result, so the coach can say
    /// "too few readings" instead of concluding from three samples.
    struct Coverage: Encodable {
        let daysInRange: Int
        let daysWithData: Int
        /// Underlying samples: readings for sampled metrics, days/nights for rollups.
        let readings: Int
        let sparse: Bool
    }

    static func coverage(metric: CoachChartMetric, start: String, end: String, context: ModelContext) -> Coverage {
        guard let bounds = dayBounds(start, end) else { return Coverage(daysInRange: 0, daysWithData: 0, readings: 0, sparse: true) }
        let daysInRange = max(1, Calendar.current.dateComponents([.day], from: bounds.start, to: bounds.end).day ?? 1)
        let days = dailySeries(metric: metric, start: start, end: end, context: context).count
        let readings = measurementKind(metric).map { measurements(kind: $0, start: start, end: end, context: context).count } ?? days
        return Coverage(daysInRange: daysInRange, daysWithData: days, readings: readings,
                        sparse: isSparse(daysWithData: days, daysInRange: daysInRange))
    }

    /// Fewer than `coach_sparse_min_days` days, or under `coach_sparse_min_percent` of the range, is sparse.
    static func isSparse(daysWithData: Int, daysInRange: Int) -> Bool {
        daysWithData < AgaraConfig.Coach.sparseMinDays
            || daysWithData * 100 < daysInRange * AgaraConfig.Coach.sparseMinPercent
    }

    /// Granularity-aware series for charts/series tools. For hr/spo2, "raw" yields
    /// the individual timestamped samples (intraday trend), "hour" averages per
    /// hour, "day" averages per day. Activity/sleep metrics are daily rollups and
    /// always return one point per day. Capped to 300 points (even downsample).
    static func seriesPoints(
        metric: CoachChartMetric, start: String, end: String, granularity: String, context: ModelContext
    ) -> [(x: String, y: Double)] {
        let dated: [(Date, Double)]
        let labeler: (Date) -> String

        switch metric {
        case .hr, .spo2, .stress, .respRate:
            let rows = measurements(kind: measurementKind(metric)!, start: start, end: end, context: context)
            // Contract §5: only hr/spo2 keep a "raw" (individual readings) option; the newer series are hourly at finest.
            let granularity = (metric == .stress || metric == .respRate) && granularity == "raw" ? "hour" : granularity
            switch granularity {
            case "hour":
                let cal = Calendar.current
                let grouped = Dictionary(grouping: rows) { row -> Date in
                    cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: row.timestamp)) ?? row.timestamp
                }
                dated = grouped
                    .map { ($0.key, ($0.value.map(\.value).reduce(0, +) / Double($0.value.count)).rounded(toPlaces: 1)) }
                    .sorted { $0.0 < $1.0 }
                labeler = hourLabel
            case "day":
                dated = dailySeries(metric: metric, start: start, end: end, context: context).map { ($0.date, $0.value) }
                labeler = localDateString
            default:  // "raw" / "minute" → individual samples
                dated = rows.map { ($0.timestamp, $0.value) }
                labeler = isoString
            }
        default:  // activity/sleep are daily rollups
            dated = dailySeries(metric: metric, start: start, end: end, context: context).map { ($0.date, $0.value) }
            labeler = localDateString
        }

        return downsample(dated, max: 300).map { (x: labeler($0.0), y: $0.1) }
    }

    private static func downsample(_ points: [(Date, Double)], max: Int) -> [(Date, Double)] {
        guard points.count > max else { return points }
        let step = Double(points.count) / Double(max)
        return (0..<max).map { points[Int(Double($0) * step)] }
    }

    private static func hourLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:00"
        f.timeZone = .current
        return f.string(from: date)
    }
}
