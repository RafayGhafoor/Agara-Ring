import Foundation

/// Time left to a full charge, from the ring's live battery readings while it sits on the charger.
///
/// `battery_samples` is throttled (30 min) and carries no charging flag, so the estimate is built from the
/// live battery frames instead (~every 37–60 s while connected), kept in a small in-memory `Series`.
/// Pure and deterministic; Android `ChargeEstimator` implements the same rules:
///
/// * only readings from the last `windowSpan` minutes count, at most `maxReadings` (the newest);
/// * rate = percent gained ÷ minutes, first → last of that window, and only once there are at least
///   `minReadings` readings spanning at least `minSpan`; a level drop starts a fresh series (`Series`);
/// * minutes to 100 % = up to 80 % at that rate, then 80 → 100 % at `rate × taperFactor` (Li-ion charging
///   slows near full). When every reading in the window is already at or above 80 %, the measured rate *is*
///   the tapered one and is not tapered again;
/// * shown rounded to the nearest 5 min, never below 5: "Full in ~N min"; "Charging" until there is enough
///   data; "Fully charged" at 100 %.
enum ChargeEstimator {
    struct Reading: Equatable {
        let date: Date
        let percent: Int
    }

    enum Estimate: Equatable {
        /// On the charger, not enough readings yet for a rate (or the level isn't rising).
        case charging
        /// Minutes until 100 %, already rounded to 5.
        case fullIn(minutes: Int)
        case fullyCharged

        /// "Charging" / "Full in ~50 min" / "Fully charged".
        var text: String {
            switch self {
            case .charging: return "Charging"
            case let .fullIn(minutes): return "Full in ~\(minutes) min"
            case .fullyCharged: return "Fully charged"
            }
        }

        /// For VoiceOver: "full in about 50 minutes" (nil while there is no estimate yet).
        var spokenText: String? {
            switch self {
            case .charging: return nil
            case let .fullIn(minutes): return "full in about \(minutes) minutes"
            case .fullyCharged: return "fully charged"
            }
        }
    }

    /// The charging status line on the Settings ring card and Wearable screen:
    /// "Charging · 49 %", "Charging · 49 % · Full in ~50 min", "Fully charged · 100 %".
    static func statusLine(percent: Int?, estimate: Estimate?) -> String {
        let level = percent.map { " · \(max(0, min(100, $0))) %" } ?? ""
        switch estimate {
        case .fullyCharged?: return "Fully charged" + level
        case let .fullIn(minutes)?: return "Charging" + level + " · " + Estimate.fullIn(minutes: minutes).text
        case .charging?, nil: return "Charging" + level
        }
    }

    // All numbers come from the shared catalog (`docs/config/shared.yaml` → `AgaraConfig.Ring`), so both
    // apps agree on every rule.
    static let minReadings = AgaraConfig.Ring.chargeEstimateMinSamples
    static let minSpan: TimeInterval = TimeInterval(AgaraConfig.Ring.chargeEstimateMinSpanMin * 60)
    /// Only readings within this long of the newest one count.
    static let windowSpan: TimeInterval = TimeInterval(AgaraConfig.Ring.chargeEstimateWindowMin * 60)
    static let taperStartPercent = AgaraConfig.Ring.chargeEstimateTaperStartPercent
    static let taperFactor = Double(AgaraConfig.Ring.chargeEstimateTaperFactor) ?? 0.4
    /// At most this many (the newest) readings set the rate.
    static let maxReadings = AgaraConfig.Ring.chargeEstimateMaxSamples
    static let roundMinutes = AgaraConfig.Ring.chargeEstimateRoundMin

    /// The readings that set the rate: within `windowSpan` of the newest, the newest `maxReadings`, oldest first.
    static func window(_ readings: [Reading]) -> [Reading] {
        let sorted = readings.sorted { $0.date < $1.date }
        guard let last = sorted.last else { return [] }
        return Array(sorted.filter { last.date.timeIntervalSince($0.date) <= windowSpan }.suffix(maxReadings))
    }

    static func estimate(_ readings: [Reading]) -> Estimate {
        let readings = window(readings)
        guard let last = readings.last else { return .charging }
        if last.percent >= 100 { return .fullyCharged }
        guard readings.count >= minReadings, let first = readings.first else { return .charging }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= minSpan else { return .charging }
        let ratePerMinute = Double(last.percent - first.percent) / (span / 60)
        guard ratePerMinute > 0 else { return .charging }
        // Every reading already in the taper: the measured rate is the slow one — don't taper it again.
        let alreadyTapered = readings.allSatisfy { $0.percent >= taperStartPercent }
        let minutes = minutesToFull(percent: last.percent, ratePerMinute: ratePerMinute, alreadyTapered: alreadyTapered)
        return .fullIn(minutes: roundToFive(minutes))
    }

    /// Raw minutes from `percent` to 100 % at `ratePerMinute` (percent per minute), with the taper above
    /// `taperStartPercent`.
    static func minutesToFull(percent: Int, ratePerMinute: Double, alreadyTapered: Bool = false) -> Double {
        guard ratePerMinute > 0 else { return .infinity }
        let p = Double(max(0, min(100, percent)))
        if alreadyTapered { return (100 - p) / ratePerMinute }
        let knee = Double(taperStartPercent)
        let toKnee = max(0, knee - p) / ratePerMinute
        let taperedRate = ratePerMinute * taperFactor
        let afterKnee = (100 - max(p, knee)) / taperedRate
        return toKnee + afterKnee
    }

    /// Nearest `roundMinutes` (5), never below it (a sub-5-minute estimate still reads "~5 min", not "~0 min").
    static func roundToFive(_ minutes: Double) -> Int {
        let step = Double(roundMinutes)
        guard minutes.isFinite else { return roundMinutes }
        return max(roundMinutes, Int((minutes / step).rounded()) * roundMinutes)
    }

    /// The readings of the current charge. Starts empty when the ring goes on the charger; cleared when it
    /// comes off or the link drops.
    struct Series: Equatable {
        private(set) var readings: [Reading] = []

        mutating func add(percent: Int, at date: Date) {
            // One frame yields one reading; a repeat of the same instant is ignored.
            if let last = readings.last, last.date == date { return }
            // A level that drops (a glitch, or the ring left the charger unseen) restarts the series.
            if let last = readings.last, percent < last.percent { readings.removeAll() }
            readings.append(Reading(date: date, percent: percent))
            // Keep only what the estimator can use: the last `windowSpan` minutes, at most `maxReadings`.
            readings.removeAll { date.timeIntervalSince($0.date) > ChargeEstimator.windowSpan }
            if readings.count > ChargeEstimator.maxReadings {
                readings.removeFirst(readings.count - ChargeEstimator.maxReadings)
            }
        }

        mutating func reset() { readings.removeAll() }

        var estimate: Estimate { ChargeEstimator.estimate(readings) }
    }
}
