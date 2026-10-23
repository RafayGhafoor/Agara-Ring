import Foundation
import SwiftData

/// One tappable starter on the empty coach screen.
struct CoachStarter: Identifiable, Equatable {
    /// Stable per slot, so the list does not reorder itself between renders.
    let id: String
    let text: String
}

/// Builds the three starter prompts shown before the first turn of a conversation.
///
/// Every starter quotes a number the app actually holds — last night's sleep against the goal, today's
/// step count, the week's activity — so the first tap already asks about the user's own data. A starter
/// is only offered when the number behind it exists: with an empty store the three are generic
/// questions with no figures in them, and with partial data the slots that can be grounded are grounded
/// while the rest fall back. There are always exactly three (`count`), because the empty screen is laid
/// out as three chips.
@MainActor
enum CoachStarterBuilder {
    static let count = 3

    static func build(context: ModelContext, now: Date = AppClock.now) -> [CoachStarter] {
        let summary = MetricsService.buildTodaySummary(context: context)
        var starters: [CoachStarter] = []

        if let sleep = sleepStarter(summary) { starters.append(sleep) }
        if let steps = stepsStarter(summary) { starters.append(steps) }
        if let activity = activityStarter(summary) { starters.append(activity) }
        if let heart = heartStarter(summary) { starters.append(heart) }

        // Top up with generic questions so there are always exactly three, and keep them distinct.
        for fallback in fallbacks {
            if starters.count >= count { break }
            if !starters.contains(where: { $0.text == fallback.text }) { starters.append(fallback) }
        }
        return Array(starters.prefix(count))
    }

    // MARK: - Grounded starters

    /// Last night against the sleep goal — the example the plan calls out.
    private static func sleepStarter(_ summary: TodaySummary) -> CoachStarter? {
        guard let sleep = summary.sleepDay else { return nil }
        // "I slept X" is last night's main sleep (deep + light + REM); the day total would add any nap.
        let slept = hoursMinutes(sleep.main.asleepMinutes)
        let goal = hoursMinutes(Int((summary.goals.sleepHours * 60).rounded()))
        if sleep.main.asleepMinutes < Int((summary.goals.sleepHours * 60).rounded()) {
            return CoachStarter(
                id: "sleep-vs-goal",
                text: "I slept \(slept) against a \(goal) goal — what would have helped?"
            )
        }
        return CoachStarter(
            id: "sleep-vs-goal",
            text: "I slept \(slept) versus a \(goal) goal — was the quality good?"
        )
    }

    private static func stepsStarter(_ summary: TodaySummary) -> CoachStarter? {
        guard let steps = summary.steps, steps > 0 else { return nil }
        let goal = summary.goals.stepsDaily
        if steps < goal {
            return CoachStarter(id: "steps-gap", text: "How do I close the \(goal - steps) steps left to today's goal?")
        }
        return CoachStarter(id: "steps-done", text: "I'm at \(steps) steps today — how does that compare with my week?")
    }

    private static func activityStarter(_ summary: TodaySummary) -> CoachStarter? {
        let days = summary.trends.steps7d.filter { $0.value > 0 }
        guard days.count >= 2 else { return nil }
        let total = days.reduce(0) { $0 + Int($1.value) }
        return CoachStarter(
            id: "week-steps",
            text: "I've walked \(total) steps over \(days.count) days — how is that trending?"
        )
    }

    private static func heartStarter(_ summary: TodaySummary) -> CoachStarter? {
        if let resting = summary.restingHeartRateEstimate {
            return CoachStarter(
                id: "resting-hr",
                text: "My resting heart rate is about \(Int(resting.rounded())) bpm — is it moving?"
            )
        }
        guard let latest = summary.latestHeartRate else { return nil }
        return CoachStarter(
            id: "latest-hr",
            text: "My last heart rate reading was \(Int(latest.value.rounded())) bpm — is that normal for me?"
        )
    }

    // MARK: - Fallbacks (no data behind them)

    private static var fallbacks: [CoachStarter] {
        [
            CoachStarter(id: "fallback-data", text: "What can you tell me from my ring data so far?"),
            CoachStarter(id: "fallback-sleep", text: "How do I improve my sleep with the ring?"),
            CoachStarter(id: "fallback-measure", text: "Which measurement should I take next?"),
        ]
    }

    /// "7h 24m" from a minute count.
    private static func hoursMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
