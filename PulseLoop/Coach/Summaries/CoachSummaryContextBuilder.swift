import Foundation
import SwiftData

/// Builds the per-kind context packet (+ a stable `dataSignature` to detect new
/// data) and the deterministic scripted fallback (reusing the existing
/// `TodayInsights` / `SleepInsights` producers) for each coach summary.
@MainActor
enum CoachSummaryContextBuilder {
    struct Built {
        let scopeKey: String
        let json: String
        let signature: String
        let fallback: CoachSummaryContent
        /// The end of the night this summary describes (sleepDay only); nil for
        /// today/sleepRange. Drives the sleep-sync gate in `CoachSummaryService`.
        var sleepSessionEnd: Date? = nil
    }

    // MARK: Today

    static func today(context: ModelContext, now: Date = AppClock.now,
                      environment: CoachContextPacket.EnvironmentContext? = nil) -> Built {
        let summary = MetricsService.buildTodaySummary(context: context)
        let packet = CoachContextBuilder.build(context: context, now: now)
        let hero = TodayInsights.deriveHero(summary)

        struct Packet: Encodable {
            let today: CoachContextPacket.DayContext
            let goals: CoachContextPacket.GoalContext
            let latestVitals: CoachContextPacket.VitalsContext
            let latestSleep: CoachContextPacket.SleepContext?
            let memories: [CoachContextPacket.MemoryContext]
            let dataQualityWarnings: [String]
            let environment: CoachContextPacket.EnvironmentContext?
        }
        let p = Packet(today: packet.today, goals: packet.goals, latestVitals: packet.latestVitals,
                       latestSleep: packet.latestSleep, memories: packet.memories,
                       dataQualityWarnings: packet.dataQualityWarnings, environment: environment)

        let sig = signature([
            packet.today.steps.map(String.init), packet.today.calories.map { String(Int($0)) },
            packet.today.activeMinutes.map(String.init), packet.today.distanceKm.map { String($0) },
            packet.latestVitals.latestHr.map { String(Int($0)) },
            packet.latestVitals.latestSpo2.map { String(Int($0)) },
            packet.latestSleep.map { "\($0.nightMin):\($0.dayTotalMin):\($0.remMin)" }, packet.today.dataConfidence,
        ])
        return Built(
            scopeKey: CoachDataAccess.localDateString(now),
            json: encode(p), signature: sig,
            fallback: CoachSummaryContent(title: hero.title, body: hero.summary, chips: hero.chips.map(\.label))
        )
    }

    // MARK: Sleep — nightly

    static func sleepDay(context: ModelContext, now: Date = AppClock.now,
                         environment: CoachContextPacket.EnvironmentContext? = nil) -> Built? {
        let range = SleepService.sleepRange(.day, context: context, now: now)
        // `SleepDayRule`: the main sleep is the day's longest session (a nap after the night used to be `.last`);
        // naps count toward the total.
        guard let day = SleepDay(sessions: SleepInsights.validSessions(range.sessions)) else { return nil }
        let night = day.main
        // The day's score (night + naps), the number the Today tile and the Sleep tab show — the coach must quote it.
        let score = day.score
        // **That night's date's** activity, not the newest row: the card is about this date, and handing the model
        // another day's steps (or today's) is what let a summary about 14 Oct say "steps for that day aren't
        // available" while the app held them, or quote a number from a different day
        // (plan `coach-summary-vs-data-2026-11-11.md`, H1).
        let stepsThatDay = MetricsRepository.activity(on: night.session.date, context: context)?.steps
        // The store-wide coverage line is about "now" and does not describe this date (H3), so it is left out here.
        let packet = CoachContextBuilder.build(context: context, now: now, reportsActivityCoverage: false)
        let memories = packet.memories

        struct Packet: Encodable {
            let date: String, dayTotalMin: Int, nightMin: Int, remMin: Int, napMin: Int?, deepMin: Int, lightMin: Int, awakeMin: Int
            let score: Int, scoreLabel: String, awakePct: Int?, deepPct: Int, stepsThatDay: Int?
            let memories: [CoachContextPacket.MemoryContext]
            let environment: CoachContextPacket.EnvironmentContext?
        }
        let p = Packet(
            date: CoachDataAccess.localDateString(night.session.date),
            dayTotalMin: day.totalMinutes, nightMin: night.deepMinutes + night.lightMinutes + night.remMinutes,
            remMin: night.remMinutes, napMin: day.naps.isEmpty ? nil : day.napMinutes, deepMin: night.deepMinutes,
            lightMin: night.lightMinutes, awakeMin: night.awakeMinutes,
            score: score.score, scoreLabel: score.label.rawValue, awakePct: score.awakePct,
            deepPct: score.deepPct, stepsThatDay: stepsThatDay, memories: memories,
            environment: environment
        )
        let sig = signature([
            String(day.totalMinutes), String(night.deepMinutes), String(night.remMinutes),
            String(night.lightMinutes), String(night.awakeMinutes), String(score.score),
        ])
        let coach = SleepInsights.dayCoach(night, score: score.score, awakePct: score.awakePct,
                                           deepPct: score.deepPct, activitySteps: stepsThatDay)
        return Built(
            scopeKey: CoachDataAccess.localDateString(night.session.date),
            json: encode(p), signature: sig,
            fallback: CoachSummaryContent(title: coach.headline, body: coach.body, chips: coach.chips),
            sleepSessionEnd: night.session.endAt
        )
    }

    // MARK: Sleep — aggregate

    static func sleepRange(_ range: SleepRangeKey, context: ModelContext, now: Date = AppClock.now) -> Built {
        let summary = SleepService.sleepRange(range, context: context, now: now)
        let valid = SleepInsights.validSessions(summary.sessions)
        let avgMin = SleepInsights.averageDuration(valid)
        let avgScore = SleepInsights.averageScore(valid)
        let stages = SleepInsights.averageStages(valid)
        let goalMin = MetricsRepository.goals(context: context)?.sleepMinutes
        let memories = CoachContextBuilder.build(context: context, now: now).memories

        struct Packet: Encodable {
            let range: String, nightsTracked: Int, expectedNights: Int
            let avgTotalMin: Int?, avgScore: Int?
            let avgDeepMin: Int?, avgLightMin: Int?, avgAwakeMin: Int?, goalMin: Int?
            let memories: [CoachContextPacket.MemoryContext]
        }
        let p = Packet(
            range: range.rawValue, nightsTracked: valid.count, expectedNights: summary.expectedNights,
            avgTotalMin: avgMin, avgScore: avgScore,
            avgDeepMin: stages?.deep, avgLightMin: stages?.light, avgAwakeMin: stages?.awake,
            goalMin: goalMin, memories: memories
        )
        let sig = signature([
            range.rawValue, String(valid.count), avgMin.map(String.init), avgScore.map(String.init),
            stages.map { "\($0.deep)/\($0.light)/\($0.awake)" },
            CoachDataAccess.localDateString(summary.end),
        ])
        let coach = SleepInsights.aggregateCoach(range: range, sessions: summary.sessions,
                                                 expectedNights: summary.expectedNights, goalMin: goalMin)
        return Built(
            scopeKey: CoachSummaryKind.sleepRange(range).rawValue,
            json: encode(p), signature: sig,
            fallback: CoachSummaryContent(title: coach.headline, body: coach.body, chips: coach.chips)
        )
    }

    // MARK: - Helpers

    private static func signature(_ parts: [String?]) -> String {
        parts.map { $0 ?? "·" }.joined(separator: "|")
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
