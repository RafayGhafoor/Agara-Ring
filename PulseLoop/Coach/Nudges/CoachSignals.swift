import Foundation
import SwiftData

/// One derived snapshot of everything the nudge rules need, built once per evaluation.
///
/// The rules and the policy read only this value: nothing below `CoachSignalsBuilder` touches SwiftData, and the
/// policy takes no clock of its own beyond the instant it is asked about. Numbers come from the app's existing
/// stores (`MetricsService.buildTodaySummary`, `SleepSession`, `SleepStageBlock`, `ActivityDaily`, `Measurement`,
/// `Device`) so a nudge can never disagree with the card the user is looking at.
struct CoachSignals: Equatable, Sendable {

    /// Medians over `AgaraConfig.Nudges.baselineDays`, with the night being judged excluded.
    struct Baseline: Equatable, Sendable {
        var nightsRecorded: Int = 0
        var sleepMinutes: Double = 0
        /// Minutes after local midnight; negative means the previous evening (bedtime before 00:00).
        var bedMinute: Int = 0
        var wakeMinute: Int = 0
        var restingHeartRate: Double = 0
        var eveningStress: Double = 0
        /// The user's own 80th percentile of stress readings — never an absolute score.
        var stressPercentile: Double = 0
    }

    /// The night being judged. `eveningStress` is the stress of the evening before that night.
    struct Night: Equatable, Sendable {
        var totalMinutes: Double
        var asleepMinutes: Double
        /// Percent of the night the ring actually recorded.
        var dataPercent: Double
        var restingHeartRate: Double
        var bedMinute: Int
        var wakeMinute: Int
        var eveningStress: Double?
    }

    /// A sleep night used by the drift window (E1).
    struct NightPoint: Equatable, Sendable {
        var bedMinute: Int
        var wakeMinute: Int
        var sleepMinutes: Double
    }

    /// A 15-minute block with at least `b3BlockSteps` steps counts as an active block (B3).
    struct StepBlock: Equatable, Sendable {
        var startMinute: Int
        var steps: Int
        var endMinute: Int { startMinute + AgaraConfig.Nudges.b3BlockMinutes }
    }

    struct Today: Equatable, Sendable {
        var steps: Int = 0
        /// Today's step blocks, in local-minute order.
        var blocks: [StepBlock] = []
        var inWorkout: Bool = false
        var awake: Bool = true
        /// Percent of the day that has been recorded so far.
        var dataPercent: Double = 100
        var activeMinutes: Int = 0
    }

    /// One completed day used by the 7/14-day windows (E2, F1, F2).
    struct DayPoint: Equatable, Sendable {
        var steps: Int
        var sleepMinutes: Double
        var activeMinutes: Int
        var stepGoalMet: Bool
        /// A day counts as good data when both sleep and steps were recorded.
        var hasGoodData: Bool { sleepMinutes > 0 && steps > 0 }
    }

    struct Ring: Equatable, Sendable {
        var paired: Bool = false
        var name: String = AgaraCopy.ringDisplayName
        var lastSync: Date?
    }

    struct Goals: Equatable, Sendable {
        var steps: Int = 8000
        var sleepMinutes: Double = 8 * 60
        /// Today's "lighter" override: the step goal is lowered by this percent for today only (`DailyGoalOverrideStore`).
        var stepGoalLowerPercent: Int = 0
    }

    /// A current run of high stress readings, with the steps taken during it (C1).
    struct StressRun: Equatable, Sendable {
        var minutes: Int
        var steps: Int
        /// The peak reading in the run. Kept because the percentile alone is not a reading: a user whose 80th percentile
        /// is 30 must not be nudged about nothing (catalog `nudge_c1_min_score`).
        var score: Int = 0
    }

    var now: Date
    var baseline = Baseline()
    var lastNight: Night?
    /// The last `e1WindowNights` nights, most recent last.
    var nights: [NightPoint] = []
    var today = Today()
    /// Completed days, most recent first. `days[0]` is yesterday.
    var days: [DayPoint] = []
    var ring = Ring()
    var goals = Goals()
    var stressRun: StressRun?

    // MARK: - Derived readings the rules compare against

    var isLearningBaseline: Bool {
        baseline.nightsRecorded < AgaraConfig.Nudges.baselineMinNights
    }

    var minuteOfDay: Int { Self.minuteOfDay(now) }

    /// Resting heart rate last night against the user's median, in percent. Nil without a usable baseline.
    var restingHeartRateDeltaPercent: Double? {
        guard let night = lastNight, baseline.restingHeartRate > 0, night.restingHeartRate > 0 else { return nil }
        return (night.restingHeartRate - baseline.restingHeartRate) / baseline.restingHeartRate * 100
    }

    var sleepTotalMinutes: Double? { lastNight?.totalMinutes }

    var sleepGoalMinutes: Double { goals.sleepMinutes }

    /// How far short of the sleep goal last night fell. Never negative.
    var sleepShortMinutes: Double? {
        guard let total = lastNight?.totalMinutes else { return nil }
        return max(0, goals.sleepMinutes - total)
    }

    var sleepGoalPercent: Double? {
        guard let total = lastNight?.totalMinutes, goals.sleepMinutes > 0 else { return nil }
        return total / goals.sleepMinutes * 100
    }

    /// Last evening's stress above the user's own normal.
    var stressAboveNormal: Bool {
        guard let stress = lastNight?.eveningStress, baseline.eveningStress > 0 else { return false }
        return stress > baseline.eveningStress
    }

    var nightHasEnoughData: Bool {
        guard let night = lastNight else { return false }
        return night.dataPercent >= Double(AgaraConfig.Nudges.minDataPercent)
    }

    var dayHasEnoughData: Bool {
        today.dataPercent >= Double(AgaraConfig.Nudges.minDataPercent)
    }

    /// The step goal for today — the user's normal goal unless they chose a lighter day.
    var stepGoal: Int {
        let lowered = Double(goals.steps) * Double(100 - goals.stepGoalLowerPercent) / 100
        return Int(lowered.rounded())
    }

    var stepGoalPercent: Double {
        guard stepGoal > 0 else { return 0 }
        return Double(today.steps) / Double(stepGoal) * 100
    }

    var stepsLeft: Int { max(0, stepGoal - today.steps) }

    /// Minutes since the last active block ended, or since midnight when there was none today.
    var minutesSinceActiveBlock: Int {
        let active = today.blocks.filter { $0.steps >= AgaraConfig.Nudges.b3BlockSteps }
        guard let last = active.map(\.endMinute).max() else { return minuteOfDay }
        return max(0, minuteOfDay - last)
    }

    var hoursSinceSync: Double? {
        guard let last = ring.lastSync else { return nil }
        return now.timeIntervalSince(last) / 3600
    }

    /// Consecutive days up to today on which the step goal was met. `days[0]` is yesterday.
    var stepGoalStreakDays: Int {
        let metToday = stepGoalPercent >= Double(AgaraConfig.Nudges.b4FractionPercent) ? 1 : 0
        return days.prefix { $0.stepGoalMet }.count + metToday
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "HH:mm" from `AgaraConfig` as minutes after midnight.
    static func minuteOfDay(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - Builder

/// Reads the app's stores once and produces the snapshot. The only place in the nudge engine that touches SwiftData.
enum CoachSignalsBuilder {
    /// A bedtime as minutes from midnight on a circle centred on it: 23:00 → -60, 00:30 → +30. Bedtimes straddle
    /// midnight, so a plain median or difference of 0…1439 values mixes 1380 (23:00) with 30 (00:30) — a "drift" of
    /// 22 h for a 90-minute change, and a median that is no time anyone went to bed.
    static func centeredBedMinute(_ minute: Int) -> Double {
        let m = ((minute % 1440) + 1440) % 1440
        return Double(m >= 720 ? m - 1440 : m)
    }


    static func build(context: ModelContext, now: Date = AppClock.now, calendar: Calendar = .current) -> CoachSignals {
        typealias N = AgaraConfig.Nudges
        var signals = CoachSignals(now: now)
        let summary = MetricsService.buildTodaySummary(context: context)
        let goal = (try? context.fetch(FetchDescriptor<UserGoal>()))?.first
        let window = N.baselineDays

        // Sleep nights, newest first, with the coverage each one actually recorded.
        let allSessions = ((try? context.fetch(FetchDescriptor<SleepSession>(
            sortBy: [SortDescriptor(\.startAt, order: .reverse)]
        ))) ?? []).filter { $0.startAt <= now }
        // One night per waking day: its main sleep by the app's one sleep-day rule (`SleepDayRule`, the longest
        // session; the rest are naps). Every session used to count as a "night", so a 2 pm nap entered the bedtime
        // median and the baseline — the demo store's naps produced "Drift 12 h 5 min" on the Patterns card.
        let byWakingDay = Dictionary(grouping: allSessions) { calendar.startOfDay(for: $0.endAt) }
        let sessions = byWakingDay.values
            .compactMap { SleepDayRule.split($0, minutes: \.totalMinutes, start: \.startAt)?.main }
            .sorted { $0.startAt > $1.startAt }
            .prefix(window * 2).map { $0 }
        let nights: [NightPointSnapshot] = sessions.map { session in
            let sessionID = session.id
            let blocks = ((try? context.fetch(FetchDescriptor<SleepStageBlock>(
                predicate: #Predicate { $0.sessionId == sessionID }
            ))) ?? [])
            let recorded = Double(blocks.reduce(0) { $0 + $1.durationMinutes })
            let inBed = max(1, session.endAt.timeIntervalSince(session.startAt) / 60)
            return NightPointSnapshot(
                startAt: session.startAt,
                sleepMinutes: Double(session.totalMinutes),
                asleepMinutes: Double(session.totalMinutes),
                dataPercent: min(100, recorded / inBed * 100),
                bedMinute: minuteOfDay(session.startAt, calendar: calendar),
                wakeMinute: minuteOfDay(session.endAt, calendar: calendar)
            )
        }

        let stressReadings = stressReadings(context: context, days: window, now: now)
        let heartRates = heartRateReadings(context: context, now: now)

        // The night being judged is excluded (`nights.first`): a baseline that contains it damps every deviation it is
        // then used to measure — the spec says "28-day median excluding the night being judged".
        let baselineNights = Array(nights.dropFirst().prefix(window))
        signals.baseline = CoachSignals.Baseline(
            nightsRecorded: baselineNights.count,
            sleepMinutes: median(baselineNights.map(\.sleepMinutes)),
            bedMinute: Int(median(baselineNights.map { centeredBedMinute($0.bedMinute) }).rounded()),
            wakeMinute: Int(median(baselineNights.map { Double($0.wakeMinute) })),
            restingHeartRate: median(baselineNights.map { restingHeartRate(for: $0, in: heartRates) }.filter { $0 > 0 }),
            eveningStress: median(baselineNights.compactMap { eveningStress(before: $0.startAt, readings: stressReadings) }.filter { $0 > 0 }),
            stressPercentile: percentile(stressReadings.map(\.value), 0.8)
        )

        if let last = nights.first {
            signals.lastNight = CoachSignals.Night(
                totalMinutes: last.sleepMinutes,
                asleepMinutes: last.asleepMinutes,
                dataPercent: last.dataPercent,
                restingHeartRate: restingHeartRate(for: last, in: heartRates),
                bedMinute: last.bedMinute,
                wakeMinute: last.wakeMinute,
                eveningStress: eveningStress(before: last.startAt, readings: stressReadings)
            )
        }
        signals.nights = nights.prefix(N.e1WindowNights).map {
            CoachSignals.NightPoint(bedMinute: $0.bedMinute, wakeMinute: $0.wakeMinute, sleepMinutes: $0.sleepMinutes)
        }

        signals.goals = CoachSignals.Goals(
            steps: goal?.steps ?? 8000,
            sleepMinutes: Double(goal?.sleepMinutes ?? 8 * 60),
            stepGoalLowerPercent: DailyGoalOverrideStore.shared.active(now: now)?.percent ?? 0
        )

        signals.today = CoachSignals.Today(
            steps: summary.steps ?? 0,
            blocks: stepBlocks(context: context, on: now, calendar: calendar),
            inWorkout: inWorkout(context: context, now: now),
            awake: summary.deviceState == .connected,
            dataPercent: summary.steps == nil ? 0 : 100,
            activeMinutes: summary.activeMinutes ?? 0
        )
        signals.days = dayPoints(
            context: context,
            stepGoal: signals.goals.steps,
            before: now,
            count: N.e2WindowDays * 2,
            calendar: calendar
        )

        if let device = (try? context.fetch(FetchDescriptor<Device>()))?.first {
            signals.ring = CoachSignals.Ring(
                paired: true,
                name: device.name.isEmpty ? AgaraCopy.ringDisplayName : device.name,
                lastSync: device.lastFullSyncAt ?? device.lastSyncAt
            )
        }

        signals.stressRun = stressRun(context: context, now: now)
        return signals
    }

    // MARK: Store reads

    private struct NightPointSnapshot {
        var startAt: Date
        var sleepMinutes: Double
        var asleepMinutes: Double
        var dataPercent: Double
        var bedMinute: Int
        var wakeMinute: Int
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // A bedtime after noon belongs to the previous evening: keep it negative so a 23:30 and a 00:30 bedtime
        // are 60 minutes apart, not 23 hours.
        return minute > 12 * 60 ? minute - 24 * 60 : minute
    }

    private static func stressReadings(context: ModelContext, days: Int, now: Date) -> [(at: Date, value: Double)] {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        let predicate = #Predicate<Measurement> { $0.kindRaw == "stress" && $0.timestamp >= from }
        let rows = (try? context.fetch(FetchDescriptor<Measurement>(predicate: predicate))) ?? []
        return rows.map { (at: $0.timestamp, value: $0.value) }
    }

    private static func heartRateReadings(context: ModelContext, now: Date) -> [(at: Date, value: Double)] {
        let from = now.addingTimeInterval(-Double(AgaraConfig.Nudges.baselineDays) * 86_400)
        let predicate = #Predicate<Measurement> { $0.kindRaw == "hr" && $0.timestamp >= from }
        let rows = (try? context.fetch(FetchDescriptor<Measurement>(predicate: predicate))) ?? []
        return rows.map { (at: $0.timestamp, value: $0.value) }
    }

    /// The lowest heart rate recorded during the night — the store's closest honest resting-HR estimate for that night.
    private static func restingHeartRate(for night: NightPointSnapshot, in readings: [(at: Date, value: Double)]) -> Double {
        let values = readings.filter { $0.at >= night.startAt && $0.at <= night.startAt.addingTimeInterval(night.sleepMinutes * 60) }
        return values.map(\.value).min() ?? 0
    }

    private static func eveningStress(before startAt: Date, readings: [(at: Date, value: Double)]) -> Double? {
        let from = startAt.addingTimeInterval(-6 * 3600)
        let values = readings.filter { $0.at >= from && $0.at <= startAt }.map(\.value)
        return values.isEmpty ? nil : median(values)
    }

    private static func inWorkout(context: ModelContext, now: Date) -> Bool {
        let predicate = #Predicate<ActivitySession> { $0.endedAt == nil }
        return ((try? context.fetch(FetchDescriptor<ActivitySession>(predicate: predicate))) ?? []).contains { $0.startedAt <= now }
    }

    private static func stressRun(context: ModelContext, now: Date) -> CoachSignals.StressRun? {
        let from = now.addingTimeInterval(-6 * 3600)
        let predicate = #Predicate<Measurement> { $0.kindRaw == "stress" && $0.timestamp >= from }
        let rows = ((try? context.fetch(FetchDescriptor<Measurement>(
            predicate: predicate, sortBy: [SortDescriptor(\.timestamp)]
        ))) ?? [])
        guard rows.count > 1 else { return nil }
        let threshold = max(
            percentile(rows.map(\.value), Double(AgaraConfig.Nudges.c1Percentile) / 100),
            Double(AgaraConfig.Nudges.c1MinScore)
        )
        guard let lastHigh = rows.lastIndex(where: { $0.value >= threshold }) else { return nil }
        let run = rows.prefix(lastHigh + 1).reversed().prefix { $0.value >= threshold }
        guard let first = run.last else { return nil }
        let minutes = Int(now.timeIntervalSince(first.timestamp) / 60)
        let steps = stepBlocks(context: context, on: now, calendar: .current)
            .filter { $0.startMinute >= CoachSignals.minuteOfDay(first.timestamp) }
            .reduce(0) { $0 + $1.steps }
        return CoachSignals.StressRun(minutes: minutes, steps: steps)
    }

    private static func stepBlocks(context: ModelContext, on date: Date, calendar: Calendar) -> [CoachSignals.StepBlock] {
        let start = calendar.startOfDay(for: date)
        let predicate = #Predicate<ActivityBucketSample> { $0.date == start }
        let rows = ((try? context.fetch(FetchDescriptor<ActivityBucketSample>(
            predicate: predicate, sortBy: [SortDescriptor(\.timestamp)]
        ))) ?? [])
        return rows.filter { $0.timestamp <= date }.map {
            CoachSignals.StepBlock(
                startMinute: Int($0.timestamp.timeIntervalSince(start) / 60),
                steps: $0.steps
            )
        }
    }

    private static func dayPoints(context: ModelContext, stepGoal: Int, before now: Date, count: Int, calendar: Calendar) -> [CoachSignals.DayPoint] {
        let from = calendar.startOfDay(for: now.addingTimeInterval(-Double(count + 1) * 86_400))
        let today = calendar.startOfDay(for: now)
        let activityPredicate = #Predicate<ActivityDaily> { $0.date >= from && $0.date < today }
        let activities = ((try? context.fetch(FetchDescriptor<ActivityDaily>(
            predicate: activityPredicate, sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))) ?? [])
        let sleepPredicate = #Predicate<SleepSession> { $0.startAt >= from && $0.startAt < today }
        let sleeps = ((try? context.fetch(FetchDescriptor<SleepSession>(predicate: sleepPredicate))) ?? [])
        return activities.prefix(count).map { day in
            let sleep = sleeps.filter { calendar.isDate($0.date, inSameDayAs: day.date) }
                .reduce(0.0) { $0 + Double($1.totalMinutes) }
            return CoachSignals.DayPoint(
                steps: day.steps,
                sleepMinutes: sleep,
                activeMinutes: day.activeMinutes,
                stepGoalMet: day.steps >= stepGoal
            )
        }
    }

    // MARK: Small maths

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The value at `fraction` through the sorted readings (0.8 = the user's own 80th percentile).
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}
