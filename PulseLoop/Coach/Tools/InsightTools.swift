import Foundation
import SwiftData

/// Coach insights (owner 2026-10-22, `docs/process/plans/coach-insights.md`): evidence tools for the 12 use cases —
/// readiness, sleep patterns, stress and movement by time of day, personal baselines, pattern discovery, workout
/// response and habit experiments. The app computes the evidence (numbers, baselines, coverage); the model explains it.
/// No score is invented here, every output says how much data stood behind it, and nothing per-minute leaves
/// (daily / hourly aggregates only — contract §5). HRV, blood pressure and glucose are deliberately not used.
@MainActor
enum InsightTools {
    static var readTools: [AnyCoachTool] {
        [baselines, weekReview, readiness, sleepPatterns, timeOfDay, workoutResponse, findPatterns, getExperiments]
    }
    /// Writes a coach memory, so it rides with the other write tools (`flags.writeToolsEnabled`).
    static var writeTools: [AnyCoachTool] { [startExperiment] }

    // MARK: - Shared helpers

    private static let cal = Calendar.current
    static var today: Date { cal.startOfDay(for: AppClock.now) }
    static func day(_ offset: Int, from base: Date? = nil) -> String {
        let base = base ?? today
        return CoachDataAccess.localDateString(cal.date(byAdding: .day, value: offset, to: base) ?? base)
    }
    /// Inclusive start, inclusive end (the tools' date-range convention).
    static func values(_ metric: CoachChartMetric, _ start: String, _ end: String, _ ctx: ModelContext) -> [Double] {
        CoachDataAccess.dailySeries(metric: metric, start: start, end: end, context: ctx).map(\.value)
    }
    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func sd(_ v: [Double]) -> Double? {
        guard v.count > 1, let m = mean(v) else { return nil }
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }
    /// JSON-friendly number: rounded, or null.
    static func num(_ v: Double?, _ places: Int = 1) -> Any { v.map { $0.rounded(toPlaces: places) } as Any? ?? NSNull() }
    /// Display precision per metric (owner decision C, 2026-10-23): the coach shows whole numbers for heart rate, stress,
    /// scores, steps, minutes, SpO2 and energy, one decimal for breathing rate and distance. The tools round at source so
    /// the model never sees "67.7 bpm" to copy; the server prompt rounds as well, for older builds.
    static func places(_ metric: CoachChartMetric) -> Int {
        switch metric {
        case .respRate, .distance: return 1
        default: return 0
        }
    }
    static func num(_ v: Double?, _ metric: CoachChartMetric) -> Any { num(v, places(metric)) }
    /// Percent change, whole (the coach shows whole percentages).
    static func pct(_ now: Double?, _ base: Double?) -> Any {
        guard let now, let base, base != 0 else { return NSNull() }
        return ((now - base) / abs(base) * 100).rounded(toPlaces: 0)
    }
    static func clock(_ minutes: Double?) -> Any { minutes.map { CoachChartView.clock($0) } as Any? ?? NSNull() }
    static func coverage(_ c: CoachDataAccess.Coverage) -> [String: Any] {
        ["days_in_range": c.daysInRange, "days_with_data": c.daysWithData, "readings": c.readings, "sparse": c.sparse]
    }
    private static func metricArg(_ raw: String) -> CoachChartMetric? { CoachChartMetric.from(raw) }

    // MARK: - get_baselines (use cases 5, 10, 11)

    private struct BaselinesArg: Decodable { let metrics: [String] }

    private static var baselines: AnyCoachTool {
        .make(
            name: "get_baselines",
            label: "Checking your usual levels",
            description: "Personal baselines for metrics: the latest value, the 7-day and 28-day averages, the user's typical range (25th–75th percentile over 28 days), how far the latest value is from the 28-day average, how many of the last 7 days were above the typical range, and coverage. Use to say what is unusual FOR THIS USER.",
            parameters: JSONSchema.object(["metrics": JSONSchema.array(JSONSchema.enumString(CoachChartMetric.toolEnum))],
                                          required: ["metrics"]),
            argsType: BaselinesArg.self
        ) { args, ctx in
            var out: [[String: Any]] = []
            for raw in args.metrics.prefix(8) {
                guard let metric = metricArg(raw) else { return .error("unknown metric '\(raw)'") }
                out.append(baselineEntry(metric, ctx.modelContext))
            }
            return .object(["as_of": day(0), "baselines": out,
                            "note": "Baselines exclude the latest day. Clock metrics (bedtime, wake_time) are minutes from midnight, negative = the evening before."])
        }
    }

    static func baselineEntry(_ metric: CoachChartMetric, _ ctx: ModelContext) -> [String: Any] {
        let all = CoachDataAccess.dailySeries(metric: metric, start: day(-29), end: day(0), context: ctx)
        guard let latest = all.last else {
            return ["metric": metric.rawValue, "latest": NSNull(), "coverage": coverage(
                CoachDataAccess.coverage(metric: metric, start: day(-28), end: day(-1), context: ctx))]
        }
        let latestDay = cal.startOfDay(for: latest.date)
        let allPrior = all.filter { cal.startOfDay(for: $0.date) < latestDay }
        // Sleep averages skip nap-only days and partial recordings (shared catalog value); they are counted instead.
        let minSleep = Double(AgaraConfig.Coach.sleepBaselineMinMinutes)
        let prior = metric == .sleep ? allPrior.filter { $0.value >= minSleep } : allPrior
        let last28 = prior.filter { $0.date >= (cal.date(byAdding: .day, value: -28, to: latestDay) ?? latestDay) }.map(\.value)
        let last7 = prior.filter { $0.date >= (cal.date(byAdding: .day, value: -7, to: latestDay) ?? latestDay) }.map(\.value)
        let low = last28.isEmpty ? nil : CoachSignalsBuilder.percentile(last28, 0.25)
        let high = last28.isEmpty ? nil : CoachSignalsBuilder.percentile(last28, 0.75)
        let avg28 = mean(last28)
        let recent7 = all.suffix(7).map(\.value)
        var entry: [String: Any] = [
            "metric": metric.rawValue,
            "latest": ["date": CoachDataAccess.localDateString(latest.date), "value": num(latest.value, metric),
                       "is_today": cal.isDate(latest.date, inSameDayAs: AppClock.now)],
            "avg_7d": num(mean(last7), metric), "avg_28d": num(avg28, metric),
            "typical_low": num(low, metric), "typical_high": num(high, metric),
            "latest_vs_28d": num(avg28.map { latest.value - $0 }, metric), "latest_vs_28d_pct": pct(latest.value, avg28),
            "days_above_typical_last_7": high.map { h in recent7.filter { $0 > h }.count } as Any? ?? NSNull(),
            "days_below_typical_last_7": low.map { l in recent7.filter { $0 < l }.count } as Any? ?? NSNull(),
            "coverage": coverage(CoachDataAccess.coverage(metric: metric, start: day(-28), end: day(-1), context: ctx)),
        ]
        if metric == .sleep { entry["short_days_excluded"] = allPrior.count - prior.count }
        if metric.isClockTime {
            entry["latest_clock"] = clock(latest.value)
            entry["avg_28d_clock"] = clock(avg28)
        }
        return entry
    }

    // MARK: - get_week_review (use cases 6, 10; fixes the 7-tool weekly review)

    static let weekMetrics: [CoachChartMetric] = [.steps, .activeMinutes, .intensityMinutes, .sleep, .sleepScore, .bedtime,
                                                  .restingHr, .stress, .respRate]

    private static var weekReview: AnyCoachTool {
        .make(
            name: "get_week_review",
            label: "Reviewing your week",
            description: "One call for 'this week vs last week': the last 7 complete days against the 7 before, for steps, active minutes, intensity minutes, sleep, sleep score, bedtime, resting heart rate, stress and respiration — averages, change, percent and days with data.",
            parameters: JSONSchema.empty,
            argsType: NoArgsInsight.self
        ) { _, ctx in
            .object(weekReviewObject(ctx.modelContext))
        }
    }

    struct NoArgsInsight: Decodable {}

    static func weekReviewObject(_ ctx: ModelContext) -> [String: Any] {
        // The last COMPLETE calendar week against the one before it (D14, option (a)); the week in progress is
        // excluded because it is incomplete — this used to be a rolling 7 days, which made "week start" meaningless.
        let window = WeekStart.weekReviewWindow(today: today)
        let thisStart = window.thisStart, thisEnd = window.thisEnd
        let lastStart = window.lastStart, lastEnd = window.lastEnd
        let rows: [[String: Any]] = weekMetrics.map { m in
            let a = values(m, thisStart, thisEnd, ctx), b = values(m, lastStart, lastEnd, ctx)
            let am = mean(a), bm = mean(b)
            var row: [String: Any] = ["metric": m.rawValue, "this_week": num(am, m), "last_week": num(bm, m),
                                      "change": num(am.flatMap { x in bm.map { x - $0 } }, m), "change_pct": m.isClockTime ? NSNull() : pct(am, bm),
                                      "days_this_week": a.count, "days_last_week": b.count,
                                      "sparse": CoachDataAccess.isSparse(daysWithData: min(a.count, b.count), daysInRange: 7)]
            if m.isClockTime { row["this_week_clock"] = clock(am); row["last_week_clock"] = clock(bm) }
            return row
        }
        return ["this_week": ["start": thisStart, "end": thisEnd], "last_week": ["start": lastStart, "end": lastEnd],
                "metrics": rows,
                "note": "this_week is the last COMPLETE calendar week (aligned to the user's week start), last_week the week before it; the week in progress is excluded (incomplete). Bedtime change is in minutes (positive = later)."]
    }

    // MARK: - get_readiness (use cases 1, 5, 11)

    private static var readiness: AnyCoachTool {
        .make(
            name: "get_readiness",
            label: "Checking how recovered you are",
            description: "Evidence for 'am I recovered / should I train hard today': last night's sleep vs the 28-day average, bedtime consistency over 7 nights, resting heart rate vs its 28-day baseline (and mornings above the typical range), the last 3 days' activity load vs usual, recent workouts, yesterday's stress vs usual, and which pieces are missing. No score: weigh the evidence and recommend go / easy / rest.",
            parameters: JSONSchema.empty,
            argsType: NoArgsInsight.self
        ) { _, ctx in
            .object(readinessObject(ctx.modelContext))
        }
    }

    static func readinessObject(_ ctx: ModelContext) -> [String: Any] {
        var missing: [String] = []
        // Sleep: the most recent sleep day within the last 2 days.
        let nights = CoachDataAccess.sleepDays(start: day(-29), end: day(0), context: ctx)
        var sleepPart: [String: Any] = [:]
        if let last = nights.last, last.date >= (cal.date(byAdding: .day, value: -1, to: today) ?? today) {
            // Readiness is about the NIGHT (main sleep, REM included), never the day total: a long nap must not make a
            // short night look recovered, and it must not inflate the 28-day baseline it is compared against.
            let nightSummary = SleepService.summary(for: last.main, context: ctx)
            let night = Double(nightSummary.asleepMinutes)
            let allPrior = nights.dropLast().map { Double(SleepService.summary(for: $0.main, context: ctx).asleepMinutes) }
            // Nap-only days and partial recordings are not nights to average against (shared catalog value).
            let prior = allPrior.filter { $0 >= Double(AgaraConfig.Coach.sleepBaselineMinMinutes) }
            let dayTotal = CoachDataAccess.sleepDayValue(.sleep, last, context: ctx)
            let napMin = Double(last.naps.reduce(0) { $0 + max(0, $1.totalMinutes) })
            // Compare both totals with the user's own goal, so advice can weigh the short night against a nap-filled day
            // instead of recommending more sleep on the day total alone (or ignoring the nap on the night alone).
            let goalMin = Double(MetricsRepository.goals(context: ctx)?.sleepMinutes ?? 8 * 60)
            let bedtimes = nights.suffix(7).compactMap { CoachDataAccess.sleepDayValue(.bedtime, $0, context: ctx) }
            sleepPart = ["night": last.night, "night_min": num(night, 0), "rem_min": num(Double(nightSummary.remMinutes), 0),
                         "day_total_min": num(dayTotal, 0), "nap_min": num(napMin, 0),
                         "goal_min": num(goalMin, 0),
                         "night_vs_goal_min": num(night - goalMin, 0),
                         "day_total_vs_goal_min": num((dayTotal ?? 0) - goalMin, 0),
                         "score": num(CoachDataAccess.sleepDayValue(.sleepScore, last, context: ctx), 0),
                         "bedtime": clock(CoachDataAccess.sleepDayValue(.bedtime, last, context: ctx)),
                         "avg_28d_min": num(mean(prior), 0), "vs_avg_min": num(mean(prior).map { night - $0 }, 0),
                         "bedtime_spread_7_nights_min": num(sd(bedtimes), 0), "nights_in_baseline": prior.count,
                         "short_days_excluded": allPrior.count - prior.count]
        } else {
            missing.append("last night's sleep (no recent sleep record)")
        }
        // Resting heart rate.
        let rhr = CoachDataAccess.dailySeries(metric: .restingHr, start: day(-29), end: day(0), context: ctx)
        var rhrPart: [String: Any] = [:]
        if let last = rhr.last, last.date >= (cal.date(byAdding: .day, value: -1, to: today) ?? today) {
            let base = rhr.dropLast().map(\.value)
            let high = base.isEmpty ? nil : CoachSignalsBuilder.percentile(base, 0.75)
            rhrPart = ["last_night": num(last.value, 0), "baseline_28d": num(mean(base), 0), "typical_high": num(high, 0),
                       "vs_baseline": num(mean(base).map { last.value - $0 }, 0),
                       "mornings_above_typical_last_3": high.map { h in rhr.suffix(3).filter { $0.value > h }.count } as Any? ?? NSNull(),
                       "nights_in_baseline": base.count]
        } else {
            missing.append("resting heart rate (no heart-rate readings during last night's sleep)")
        }
        // Load: last 3 complete days vs the 28-day daily average.
        let load3 = values(.intensityMinutes, day(-3), day(-1), ctx), load28 = values(.intensityMinutes, day(-28), day(-1), ctx)
        let active3 = values(.activeMinutes, day(-3), day(-1), ctx), active28 = values(.activeMinutes, day(-28), day(-1), ctx)
        let loadPart: [String: Any] = [
            "intensity_minutes_last_3_days": num(load3.reduce(0, +), 0), "intensity_minutes_usual_3_days": num(mean(load28).map { $0 * 3 }, 0),
            "active_minutes_last_3_days": num(active3.reduce(0, +), 0), "active_minutes_usual_3_days": num(mean(active28).map { $0 * 3 }, 0),
        ]
        if load3.isEmpty && active3.isEmpty { missing.append("recent activity load") }
        let workouts = CoachDataAccess.activitySessions(start: day(-2), end: day(0), context: ctx).compactMap { s -> [String: Any]? in
            guard let end = s.endedAt else { return nil }
            return ["type": s.type, "start": CoachDataAccess.isoString(s.startedAt),
                    "duration_min": num((end.timeIntervalSince(s.startedAt) - s.totalPauseSeconds) / 60, 0),
                    "avg_hr": num(s.avgHeartRate, 0), "hours_since_end": num(AppClock.now.timeIntervalSince(end) / 3600, 0)]
        }
        // Stress yesterday vs usual.
        let stressY = values(.stress, day(-1), day(-1), ctx), stress28 = values(.stress, day(-28), day(-2), ctx)
        var stressPart: [String: Any] = [:]
        if let y = stressY.first {
            stressPart = ["yesterday_mean": num(y, 0), "usual_mean": num(mean(stress28), 0), "vs_usual": num(mean(stress28).map { y - $0 }, 0)]
        } else {
            missing.append("stress readings yesterday")
        }
        return ["sleep": sleepPart.isEmpty ? NSNull() : sleepPart, "resting_hr": rhrPart.isEmpty ? NSNull() : rhrPart,
                "load": loadPart, "recent_workouts": workouts, "stress": stressPart.isEmpty ? NSNull() : stressPart,
                "missing": missing,
                "not_used": ["hrv (the ring's HRV decoding is not validated yet)"],
                "note": "No readiness score: weigh these against each other and the user's goals. Resting HR is the lowest reading during the main sleep. Sleep: night_min is the main sleep (deep + light + REM, awake excluded) and avg_28d_min/vs_avg_min are the same measure over prior nights; day_total_min adds the waking day's naps and is not \"last night\". goal_min is the user's sleep goal; night_vs_goal_min and day_total_vs_goal_min compare last night and the day to it. A short night with a nap that brings day_total to or above the goal is not a reason to recommend more total sleep today; the night's length and timing are."]
    }

    // MARK: - get_sleep_patterns (use cases 2, 10)

    private struct RangeArg: Decodable { let start: String; let end: String }

    private static var sleepPatterns: AnyCoachTool {
        .make(
            name: "get_sleep_patterns",
            label: "Looking at your sleep patterns",
            description: "Night by night: bedtime, wake time, total, awake minutes, stages (estimates), naps and score — plus consistency (bedtime and wake spread), the nights that were short, late or fragmented for this user, and how bedtime relates to duration. Separates too little sleep from irregular timing and broken sleep. A night is labelled by the evening it started and the morning it ended.",
            parameters: JSONSchema.object(["start": JSONSchema.string, "end": JSONSchema.string], required: ["start", "end"]),
            argsType: RangeArg.self
        ) { args, ctx in
            .object(sleepPatternsObject(start: args.start, end: args.end, ctx.modelContext))
        }
    }

    static func sleepPatternsObject(start: String, end: String, _ ctx: ModelContext) -> [String: Any] {
        let days = CoachDataAccess.sleepDays(start: start, end: end, context: ctx).suffix(31)
        struct Night { let label: String; let night, dayTotal, bed, wake, awake: Double; let score: Double?; let naps: Double
            let deep, light, rem: Int }
        let nights: [Night] = days.map { d in
            let summary = SleepService.summary(for: d.main, context: ctx)
            let naps = Double(d.naps.reduce(0) { $0 + max(0, $1.totalMinutes) })
            let dayTotal = CoachDataAccess.sleepDayValue(.sleep, d, context: ctx) ?? 0
            return Night(label: d.night,
                         night: Double(summary.asleepMinutes),
                         dayTotal: dayTotal,
                         bed: CoachDataAccess.sleepDayValue(.bedtime, d, context: ctx) ?? 0,
                         wake: CoachDataAccess.sleepDayValue(.wakeTime, d, context: ctx) ?? 0,
                         awake: CoachDataAccess.sleepDayValue(.sleepAwake, d, context: ctx) ?? 0,
                         score: CoachDataAccess.sleepDayValue(.sleepScore, d, context: ctx),
                         naps: naps,
                         deep: summary.deepMinutes, light: summary.lightMinutes, rem: summary.remMinutes)
        }
        guard !nights.isEmpty else {
            return ["nights": [], "summary": NSNull(), "note": "No sleep recorded in this range."]
        }
        // "Short"/"late" are judged on the NIGHT (deep + light + REM), not on a day total inflated by naps.
        let medianTotal = CoachSignalsBuilder.median(nights.map(\.night))
        let medianBed = CoachSignalsBuilder.median(nights.map(\.bed))
        let awakeHigh = max(30, CoachSignalsBuilder.percentile(nights.map(\.awake), 0.75))
        let pairs = nights.map { ($0.bed, $0.night) }
        return [
            "nights": nights.map { n in
                ["night": n.label, "bedtime": clock(n.bed), "wake": clock(n.wake),
                 "night_min": num(n.night, 0), "day_total_min": num(n.dayTotal, 0),
                 "awake_min": num(n.awake, 0), "deep_min": n.deep, "light_min": n.light, "rem_min": n.rem,
                 "naps_min": num(n.naps, 0), "score": num(n.score, 0),
                 "short": n.night < medianTotal - 45, "late": n.bed > medianBed + 45, "fragmented": n.awake > awakeHigh] as [String: Any]
            },
            "summary": [
                "nights": nights.count, "avg_night_min": num(mean(nights.map(\.night)), 0),
                "avg_day_total_min": num(mean(nights.map(\.dayTotal)), 0),
                "median_bedtime": clock(medianBed), "median_wake": clock(CoachSignalsBuilder.median(nights.map(\.wake))),
                "bedtime_spread_min": num(sd(nights.map(\.bed)), 0), "wake_spread_min": num(sd(nights.map(\.wake)), 0),
                "short_nights": nights.filter { $0.night < medianTotal - 45 }.count,
                "late_nights": nights.filter { $0.bed > medianBed + 45 }.count,
                "fragmented_nights": nights.filter { $0.awake > awakeHigh }.count,
                "bedtime_vs_duration": nights.count >= 5 ? AnalysisEngine.correlation(pairs).asDictionary : NSNull(),
            ] as [String: Any],
            "coverage": coverage(CoachDataAccess.coverage(metric: .sleep, start: start, end: end, context: ctx)),
            "note": "night_min is the main sleep (deep + light + REM, awake excluded) — the number behind \"last night\". day_total_min adds any naps the ring recorded that waking day; naps_min is that addition. Stages are the ring's estimates. 'short' = 45+ min under this user's median night, 'late' = bedtime 45+ min after the median, 'fragmented' = awake above max(30 min, this user's 75th percentile). A negative bedtime_vs_duration r means later bedtimes went with shorter nights.",
        ]
    }

    // MARK: - get_time_of_day_profile (use cases 3, 4)

    private struct TimeOfDayArg: Decodable { let metric: String; let start: String; let end: String }

    private static var timeOfDay: AnyCoachTool {
        .make(
            name: "get_time_of_day_profile",
            label: "Looking at your day by the hour",
            description: "When in the day a metric happens, averaged over a date range, hour by hour: steps or intensity minutes (when the user moves; share in the evening), stress or heart rate (when it rises and whether it settles). Returns per-hour averages with the number of days behind each hour, the peak and the quietest waking hours.",
            parameters: JSONSchema.object([
                "metric": JSONSchema.enumString(["steps", "intensity_minutes", "stress", "hr"]),
                "start": JSONSchema.string, "end": JSONSchema.string,
            ], required: ["metric", "start", "end"]),
            argsType: TimeOfDayArg.self
        ) { args, ctx in
            guard let metric = metricArg(args.metric) else { return .error("unknown metric '\(args.metric)'") }
            return .object(timeOfDayObject(metric, start: args.start, end: args.end, ctx.modelContext))
        }
    }

    static func timeOfDayObject(_ metric: CoachChartMetric, start: String, end: String, _ ctx: ModelContext) -> [String: Any] {
        guard let bounds = CoachDataAccess.dayBounds(start, end) else { return ["error": "bad date range"] }
        // (hour, day) → value: summed for movement, averaged for stress/HR.
        var cells: [Int: [Date: [Double]]] = [:]
        func add(_ at: Date, _ v: Double) {
            cells[cal.component(.hour, from: at), default: [:]][cal.startOfDay(for: at), default: []].append(v)
        }
        let summed: Bool
        switch metric {
        case .steps:
            summed = true
            let lo = bounds.start, hi = bounds.end
            let rows = (try? ctx.fetch(FetchDescriptor<ActivityBucketSample>(
                predicate: #Predicate { $0.timestamp >= lo && $0.timestamp < hi }))) ?? []
            rows.forEach { add($0.timestamp, Double($0.steps)) }
        case .intensityMinutes:
            summed = true
            CoachDataAccess.measurements(kind: .met, start: start, end: end, context: ctx).forEach { add($0.timestamp, $0.value >= 3 ? 5 : 0) }
        default:
            summed = false
            guard let kind = CoachDataAccess.measurementKind(metric) else { return ["error": "unsupported metric"] }
            CoachDataAccess.measurements(kind: kind, start: start, end: end, context: ctx).forEach { add($0.timestamp, $0.value) }
        }
        let allDays = Set(cells.values.flatMap(\.keys)).count
        let hours: [[String: Any]] = (0..<24).compactMap { h in
            guard let byDay = cells[h], !byDay.isEmpty else { return nil }
            let perDay = byDay.values.map { summed ? $0.reduce(0, +) : $0.reduce(0, +) / Double($0.count) }
            return ["hour": h, "value": num(mean(perDay), metric), "days": byDay.count]
        }
        let valued = hours.compactMap { h -> (Int, Double)? in
            guard let v = h["value"] as? Double, let hour = h["hour"] as? Int else { return nil }
            return (hour, v)
        }
        let waking = valued.filter { (8...21).contains($0.0) }
        var result: [String: Any] = [
            "metric": metric.rawValue, "hours": hours, "days_with_data": allDays,
            "peak_hours": valued.sorted { $0.1 > $1.1 }.prefix(3).map(\.0),
            "quietest_waking_hours": waking.sorted { $0.1 < $1.1 }.prefix(3).map(\.0),
            "sparse": CoachDataAccess.isSparse(daysWithData: allDays,
                                                daysInRange: max(1, cal.dateComponents([.day], from: bounds.start, to: bounds.end).day ?? 1)),
        ]
        if summed {
            let total = valued.map(\.1).reduce(0, +)
            result["share_evening_18_23"] = total > 0 ? num(valued.filter { $0.0 >= 18 }.map(\.1).reduce(0, +) / total * 100, 0) : NSNull()
            result["share_morning_6_11"] = total > 0 ? num(valued.filter { (6...11).contains($0.0) }.map(\.1).reduce(0, +) / total * 100, 0) : NSNull()
        }
        result["note"] = summed ? "Values are the average amount in that hour on days with data." :
            "Values are the average reading in that hour; ring readings are sampled, so few readings per hour is normal."
        return result
    }

    // MARK: - get_workout_response (use case 8)

    private static var workoutResponse: AnyCoachTool {
        .make(
            name: "get_workout_response",
            label: "Seeing how workouts affect you",
            description: "For each finished workout in a range: type, start, duration, average heart rate, how many hours before that night's bedtime it ended, the following night's sleep and score, and the next morning's resting heart rate against the user's averages — plus nights after workouts vs nights without.",
            parameters: JSONSchema.object(["start": JSONSchema.string, "end": JSONSchema.string], required: ["start", "end"]),
            argsType: RangeArg.self
        ) { args, ctx in
            .object(workoutResponseObject(start: args.start, end: args.end, ctx.modelContext))
        }
    }

    static func workoutResponseObject(start: String, end: String, _ ctx: ModelContext) -> [String: Any] {
        let sessions = CoachDataAccess.activitySessions(start: start, end: end, context: ctx).filter { $0.endedAt != nil }
            .sorted { $0.startedAt < $1.startedAt }
        let nights = CoachDataAccess.sleepDays(start: start, end: day(1, from: CoachDataAccess.parseLocalDate(end) ?? today), context: ctx)
        let sleepAvg = mean(nights.compactMap { CoachDataAccess.sleepDayValue(.sleep, $0, context: ctx) })
        let rhrAvg = mean(nights.compactMap { CoachDataAccess.sleepDayValue(.restingHr, $0, context: ctx) })
        var afterWorkout = Set<Date>()
        let rows: [[String: Any]] = sessions.map { s in
            let end = s.endedAt!
            let next = nights.first { $0.main.startAt > end && $0.main.startAt < end.addingTimeInterval(18 * 3600) }
            if let next { afterWorkout.insert(next.date) }
            let total = next.flatMap { CoachDataAccess.sleepDayValue(.sleep, $0, context: ctx) }
            let rhr = next.flatMap { CoachDataAccess.sleepDayValue(.restingHr, $0, context: ctx) }
            return [
                "type": s.type, "start": CoachDataAccess.isoString(s.startedAt),
                "duration_min": num((end.timeIntervalSince(s.startedAt) - s.totalPauseSeconds) / 60, 0),
                "avg_hr": num(s.avgHeartRate, 0),
                "hours_before_bedtime": num(next.map { $0.main.startAt.timeIntervalSince(end) / 3600 }),
                "next_night": next.map { $0.night } as Any? ?? NSNull(),
                "next_night_total_min": num(total, 0), "next_night_vs_avg_min": num(total.flatMap { t in sleepAvg.map { t - $0 } }, 0),
                "next_night_score": num(next.flatMap { CoachDataAccess.sleepDayValue(.sleepScore, $0, context: ctx) }, 0),
                "next_morning_resting_hr": num(rhr, 0), "next_morning_rhr_vs_avg": num(rhr.flatMap { r in rhrAvg.map { r - $0 } }, 0),
            ]
        }
        let after = nights.filter { afterWorkout.contains($0.date) }.compactMap { CoachDataAccess.sleepDayValue(.sleep, $0, context: ctx) }
        let without = nights.filter { !afterWorkout.contains($0.date) }.compactMap { CoachDataAccess.sleepDayValue(.sleep, $0, context: ctx) }
        return ["workouts": rows,
                "summary": ["workouts": rows.count, "nights_after_workouts": after.count, "avg_sleep_after_workouts_min": num(mean(after), 0),
                            "nights_without_workouts": without.count, "avg_sleep_without_workouts_min": num(mean(without), 0),
                            "avg_sleep_all_min": num(sleepAvg, 0), "avg_resting_hr": num(rhrAvg, 0)] as [String: Any],
                "note": "Associations in this user's data, not causes. Few workouts → say the comparison is thin."]
    }

    // MARK: - find_patterns (use cases 6, 10)

    private struct PatternArg: Decodable { let target: String; let start: String; let end: String }

    private static var findPatterns: AnyCoachTool {
        .make(
            name: "find_patterns",
            label: "Looking for patterns",
            description: "What tends to come before this user's best vs worst days for a target (sleep duration, sleep score or resting heart rate): compares the best and worst quarter of days on the day before — steps, intensity minutes, late-evening steps, stress, a workout, and that night's bedtime. Needs at least 8 days. Associations only.",
            parameters: JSONSchema.object([
                "target": JSONSchema.enumString(["sleep", "sleep_score", "resting_hr"]),
                "start": JSONSchema.string, "end": JSONSchema.string,
            ], required: ["target", "start", "end"]),
            argsType: PatternArg.self
        ) { args, ctx in
            guard let target = metricArg(args.target) else { return .error("unknown target '\(args.target)'") }
            return .object(findPatternsObject(target, start: args.start, end: args.end, ctx.modelContext))
        }
    }

    static func findPatternsObject(_ target: CoachChartMetric, start: String, end: String, _ ctx: ModelContext) -> [String: Any] {
        let days = CoachDataAccess.sleepDays(start: start, end: end, context: ctx)
        let scored: [(CoachDataAccess.CoachSleepDay, Double)] = days.compactMap { d in
            CoachDataAccess.sleepDayValue(target, d, context: ctx).map { (d, $0) }
        }
        guard scored.count >= 8 else {
            return ["target": target.rawValue, "days": scored.count, "enough_data": false,
                    "note": "Fewer than 8 days with this target — not enough to compare best and worst days."]
        }
        let lowerIsBetter = target == .restingHr
        let sorted = scored.sorted { lowerIsBetter ? $0.1 < $1.1 : $0.1 > $1.1 }
        let quarter = max(2, sorted.count / 4)
        let best = Array(sorted.prefix(quarter)), worst = Array(sorted.suffix(quarter))
        func dayBefore(_ d: CoachDataAccess.CoachSleepDay) -> String { day(-1, from: d.date) }
        func feature(_ name: String, _ f: (CoachDataAccess.CoachSleepDay) -> Double?) -> [String: Any] {
            let b = best.compactMap { f($0.0) }, w = worst.compactMap { f($0.0) }
            return ["feature": name, "best_days_avg": num(mean(b)), "worst_days_avg": num(mean(w)),
                    "difference": num(mean(b).flatMap { x in mean(w).map { x - $0 } }), "n_best": b.count, "n_worst": w.count]
        }
        let lateSteps: (CoachDataAccess.CoachSleepDay) -> Double? = { d in
            let eve = self.cal.date(byAdding: .hour, value: -4, to: d.main.startAt) ?? d.main.startAt
            let hi = d.main.startAt
            let rows = (try? ctx.fetch(FetchDescriptor<ActivityBucketSample>(predicate: #Predicate { $0.timestamp >= eve && $0.timestamp < hi }))) ?? []
            return rows.isEmpty ? nil : Double(rows.reduce(0) { $0 + $1.steps })
        }
        let workoutDay: (CoachDataAccess.CoachSleepDay) -> Double? = { d in
            CoachDataAccess.activitySessions(start: dayBefore(d), end: dayBefore(d), context: ctx).isEmpty ? 0 : 1
        }
        let features: [[String: Any]] = [
            feature("steps_day_before") { values(.steps, dayBefore($0), dayBefore($0), ctx).first },
            feature("intensity_minutes_day_before") { values(.intensityMinutes, dayBefore($0), dayBefore($0), ctx).first },
            feature("steps_in_4h_before_bed", lateSteps),
            feature("stress_day_before") { values(.stress, dayBefore($0), dayBefore($0), ctx).first },
            feature("workout_day_before (share)", workoutDay),
            feature("bedtime_min_from_midnight") { CoachDataAccess.sleepDayValue(.bedtime, $0, context: ctx) },
        ]
        return ["target": target.rawValue, "better_is": lowerIsBetter ? "lower" : "higher", "days": scored.count,
                "enough_data": true, "best_days": best.map { [$0.0.night, num($0.1, 0)] as [Any] },
                "worst_days": worst.map { [$0.0.night, num($0.1, 0)] as [Any] }, "features": features,
                "note": "Associations in this user's data, not causes; each feature's n says how many days had it. Bedtime is minutes from midnight (negative = before midnight)."]
    }

    // MARK: - Experiments (use case 9) — stored as typed coach memories (no schema change)

    private struct StartExperimentArg: Decodable {
        let name: String, change: String, metric: String, days: Int
    }

    private static var startExperiment: AnyCoachTool {
        .make(
            name: "start_experiment",
            label: "Starting your experiment",
            description: "Start a personal habit experiment the user asked for (e.g. 'lights out by 22:45 for 14 days and see if I sleep longer'): records the change, the metric to judge it by and its length from today. get_experiments compares the experiment days with the same number of days before it.",
            parameters: JSONSchema.object([
                "name": JSONSchema.string, "change": JSONSchema.string,
                "metric": JSONSchema.enumString(CoachChartMetric.toolEnum),
                "days": ["type": "number", "minimum": 3, "maximum": 42],
            ], required: ["name", "change", "metric", "days"]),
            argsType: StartExperimentArg.self
        ) { args, ctx in
            guard CoachChartMetric.from(args.metric) != nil else { return .error("unknown metric '\(args.metric)'") }
            let payload: [String: Any] = ["change": args.change, "metric": args.metric, "start_date": day(0),
                                          "days": max(3, min(42, args.days))]
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else {
                return .error("could not record the experiment")
            }
            let mem = MemoryTools.save(context: ctx.modelContext, memoryType: "experiment", key: args.name, value: json,
                                       importance: 4, expiresInDays: max(3, min(42, args.days)) + 30)
            return .object(["ok": true, "experiment_id": mem.id.uuidString, "starts": day(0), "days": payload["days"]!,
                            "compares_with": "the same number of days before \(day(0))"])
        }
    }

    private static var getExperiments: AnyCoachTool {
        .make(
            name: "get_experiments",
            label: "Checking your experiments",
            description: "The user's habit experiments with their progress: the metric's average during the experiment vs the same number of days before it, the change, days elapsed, coverage, and whether it is running or finished.",
            parameters: JSONSchema.empty,
            argsType: NoArgsInsight.self
        ) { _, ctx in
            .object(["experiments": experimentsObject(ctx.modelContext)])
        }
    }

    static func experimentsObject(_ ctx: ModelContext) -> [[String: Any]] {
        let rows = (try? ctx.fetch(FetchDescriptor<CoachMemory>(predicate: #Predicate { $0.memoryType == "experiment" }))) ?? []
        return rows.sorted { $0.createdAt > $1.createdAt }.compactMap { mem in
            guard let data = mem.value.data(using: .utf8),
                  let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let metricRaw = v["metric"] as? String, let metric = CoachChartMetric.from(metricRaw),
                  let startRaw = v["start_date"] as? String, let start = CoachDataAccess.parseLocalDate(startRaw),
                  let days = v["days"] as? Int else { return nil }
            let elapsed = max(0, (cal.dateComponents([.day], from: start, to: today).day ?? 0))
            let duringEnd = day(min(days, elapsed + 1) - 1, from: start)
            let during = values(metric, startRaw, duringEnd, ctx), before = values(metric, day(-days, from: start), day(-1, from: start), ctx)
            return ["name": mem.key, "change": v["change"] as? String ?? "", "metric": metricRaw, "start": startRaw, "days": days,
                    "days_elapsed": min(elapsed, days), "status": elapsed >= days ? "finished" : "running",
                    "during_avg": num(mean(during), metric), "before_avg": num(mean(before), metric),
                    "change_value": num(mean(during).flatMap { d in mean(before).map { d - $0 } }, metric), "change_pct": pct(mean(during), mean(before)),
                    "days_with_data_during": during.count, "days_with_data_before": before.count,
                    "sparse": CoachDataAccess.isSparse(daysWithData: min(during.count, before.count), daysInRange: max(1, min(days, elapsed)))]
        }
    }
}

extension AnalysisEngine.CorrelationResult {
    var asDictionary: [String: Any] {
        ["pairs": pairs, "pearson": pearson.map { $0.rounded(toPlaces: 2) } as Any? ?? NSNull(), "strength": strength, "note": note]
    }
}
