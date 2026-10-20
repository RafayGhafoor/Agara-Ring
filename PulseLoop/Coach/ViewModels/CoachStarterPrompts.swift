import Foundation

/// The empty conversation's opening chips, built from what the ring actually delivered — "I'm at 4,210 steps today —
/// how am I doing?" instead of a fixed list that reads the same on a phone with no data at all.
///
/// Pure and packet-in: `CoachView` builds a `CoachContextPacket` once when the thread is empty and renders what this
/// returns, and `CoachFollowUpChips.balanced` draws from the same list when an answer carries fewer than three
/// follow-ups (the wire contract says three; a bring-your-own-key provider can send two).
enum CoachStarterPrompts {
    /// Up to `limit` prompts, most relevant first. With no data at all it degrades to "what data is missing?" plus the
    /// week summary, which are useful on a bare install.
    static func make(packet: CoachContextPacket, limit: Int = 4) -> [String] {
        var prompts: [String] = []

        if let sleep = packet.latestSleep {
            if let score = sleep.score {
                prompts.append(CoachCopy.starterSleepScore(score))
            } else if sleep.totalMin > 0 {
                prompts.append(CoachCopy.starterSleepDuration(SleepFormat.duration(sleep.totalMin)))
            }
        }

        if let steps = packet.today.steps, steps > 0 {
            prompts.append(CoachCopy.starterSteps(Self.stepsFormatter.string(from: NSNumber(value: steps)) ?? "\(steps)"))
        }

        if let resting = packet.latestVitals.restingHrEstimate ?? packet.latestVitals.latestHr {
            prompts.append(CoachCopy.starterRestingHR("\(Int(resting.rounded()))"))
        }

        if let spo2 = packet.latestVitals.latestSpo2 {
            prompts.append(CoachCopy.starterVital("SpO₂", "\(Int(spo2.rounded()))%"))
        }

        // No data delivered yet (a fresh install, or the ring has not synced today): say so first.
        if packet.today.steps == nil, packet.latestSleep == nil, packet.latestVitals.latestHr == nil {
            prompts.insert(CoachCopy.starterNoData, at: 0)
        }
        prompts.append(CoachCopy.starterWeek)

        var seen = Set<String>()
        return prompts.filter { seen.insert($0).inserted }.prefix(max(1, limit)).map { $0 }
    }

    private static let stepsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}
