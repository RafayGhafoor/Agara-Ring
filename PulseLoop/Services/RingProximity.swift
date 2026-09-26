import Foundation

/// Find ring: how near the ring is, from Bluetooth signal strength (plan `docs/process/plans/find-ring-proximity.md`).
///
/// Pure value type — no clock, no radio. `RingSignalSource` feeds raw dBm readings with a monotonic time in seconds;
/// `reading(at:)` turns them into a band, a trend and the smoothed value. Android's `RingProximity` does the same math
/// (Rule 2); the numbers come from `shared.yaml` (`ring_find_*`).
///
/// The math, exactly:
/// * **Valid reading:** −127 ≤ dBm ≤ 0. Anything else (CoreBluetooth's 127 "unavailable") is dropped.
/// * **Smoothing:** time-based exponential moving average, `α = 1 − e^(−Δt / smoothingS)`,
///   `smoothed += α · (raw − smoothed)`. The first reading — or the first after the signal was lost — seeds it.
/// * **Signal lost:** no valid reading for `signalLostS` → **Out of range** (and the smoothing restarts).
/// * **Bands** on the smoothed value: ≥ rightHere → Right here, ≥ veryClose → Very close, ≥ warmer → Getting warmer,
///   ≥ far → Far, else Out of range (`band(for:)`). The first reading (or the first after a loss) takes that band.
/// * **Hysteresis:** after that the shown band is sticky and re-evaluated on each reading, one step at a time: it moves
///   up while `smoothed ≥ lowerBound(band + 1) + hysteresis` and down while `smoothed < lowerBound(band) − hysteresis`
///   (`ring_find_band_hysteresis_db`), so ±jitter at a boundary does not flip bands.
/// * **Trend:** the smoothed value now minus the smoothed value at the latest reading at least `trendWindowS` older
///   (none yet → steady). ≥ +threshold → closer, ≤ −threshold → further, otherwise steady. A weak-but-present signal
///   (Out of range by value) still has a trend; a lost signal has none.
struct RingProximity: Equatable {

    enum Band: Int, CaseIterable, Comparable {
        case outOfRange = 0, far, warmer, veryClose, rightHere

        static func < (lhs: Band, rhs: Band) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .rightHere:  return AgaraCopy.findRingBandRightHere
            case .veryClose:  return AgaraCopy.findRingBandVeryClose
            case .warmer:     return AgaraCopy.findRingBandWarmer
            case .far:        return AgaraCopy.findRingBandFar
            case .outOfRange: return AgaraCopy.findRingBandOutOfRange
            }
        }

        /// How many of the four concentric circles are lit (0 … 4).
        var filledCircles: Int { rawValue }

        /// Seconds per pulse — faster as you get closer (both apps use these values).
        var pulsePeriod: Double {
            switch self {
            case .rightHere:  return 0.55
            case .veryClose:  return 0.85
            case .warmer:     return 1.2
            case .far:        return 1.6
            case .outOfRange: return 2.0
            }
        }
    }

    enum Trend: Equatable { case closer, further, steady }

    struct Thresholds: Equatable {
        var rightHereDbm: Double
        var veryCloseDbm: Double
        var warmerDbm: Double
        var farDbm: Double
        var signalLostS: Double
        var smoothingS: Double
        var trendWindowS: Double
        var trendThresholdDb: Double
        var bandHysteresisDb: Double

        /// The shipped values (`shared.yaml` → `AgaraConfig.Ring.find*`).
        static let catalog = Thresholds(
            rightHereDbm: Double(AgaraConfig.Ring.findRssiRightHereDbm) ?? -55,
            veryCloseDbm: Double(AgaraConfig.Ring.findRssiVeryCloseDbm) ?? -67,
            warmerDbm: Double(AgaraConfig.Ring.findRssiWarmerDbm) ?? -78,
            farDbm: Double(AgaraConfig.Ring.findRssiFarDbm) ?? -88,
            signalLostS: Double(AgaraConfig.Ring.findSignalLostS),
            smoothingS: Double(AgaraConfig.Ring.findSmoothingS),
            trendWindowS: Double(AgaraConfig.Ring.findTrendWindowS),
            trendThresholdDb: Double(AgaraConfig.Ring.findTrendThresholdDb),
            bandHysteresisDb: Double(AgaraConfig.Ring.findBandHysteresisDb)
        )
    }

    /// What the screen shows at one instant.
    struct Reading: Equatable {
        var band: Band
        var trend: Trend
        /// The smoothed signal, rounded; nil when out of range for lack of signal.
        var smoothedDbm: Int?
        /// The last raw reading (for the small live dBm text); nil when the signal is lost.
        var rawDbm: Int?

        static let noSignal = Reading(band: .outOfRange, trend: .steady, smoothedDbm: nil, rawDbm: nil)
    }

    let thresholds: Thresholds
    private(set) var smoothed: Double?
    /// The sticky band (hysteresis applied); nil until the first reading after a start or a loss.
    private(set) var band: Band?
    private(set) var lastRaw: Int?
    private(set) var lastAt: Double?
    private var history: [Sample] = []

    private struct Sample: Equatable { let t: Double; let value: Double }

    init(thresholds: Thresholds = .catalog) { self.thresholds = thresholds }

    static func isValid(_ dbm: Int) -> Bool { dbm <= 0 && dbm >= -127 }

    /// Band for a smoothed value.
    static func band(for dbm: Double, thresholds: Thresholds = .catalog) -> Band {
        if dbm >= thresholds.rightHereDbm { return .rightHere }
        if dbm >= thresholds.veryCloseDbm { return .veryClose }
        if dbm >= thresholds.warmerDbm { return .warmer }
        if dbm >= thresholds.farDbm { return .far }
        return .outOfRange
    }

    /// The lower bound (dBm) of `band`; Out of range has none.
    private func lowerBound(_ band: Band) -> Double {
        switch band {
        case .rightHere:  return thresholds.rightHereDbm
        case .veryClose:  return thresholds.veryCloseDbm
        case .warmer:     return thresholds.warmerDbm
        case .far:        return thresholds.farDbm
        case .outOfRange: return -.infinity
        }
    }

    /// Step `from` up/down only while `value` clears the boundary by the hysteresis.
    private func stickyBand(from: Band, value: Double) -> Band {
        var b = from
        while let up = Band(rawValue: b.rawValue + 1), value >= lowerBound(up) + thresholds.bandHysteresisDb { b = up }
        while let down = Band(rawValue: b.rawValue - 1), value < lowerBound(b) - thresholds.bandHysteresisDb { b = down }
        return b
    }

    /// Add one reading taken at `t` (monotonic seconds).
    mutating func add(rssi dbm: Int, at t: Double) {
        guard Self.isValid(dbm) else { return }
        let raw = Double(dbm)
        let next: Double
        let fresh: Bool
        if let previous = smoothed, let last = lastAt, t - last < thresholds.signalLostS {
            let dt = max(0, t - last)
            let alpha = thresholds.smoothingS > 0 ? 1 - exp(-dt / thresholds.smoothingS) : 1
            next = previous + alpha * (raw - previous)
            fresh = false
        } else {
            next = raw
            fresh = true
            history.removeAll()
        }
        smoothed = next
        band = fresh ? Self.band(for: next, thresholds: thresholds)
                     : stickyBand(from: band ?? Self.band(for: next, thresholds: thresholds), value: next)
        lastAt = t
        lastRaw = dbm
        history.append(Sample(t: t, value: smoothed ?? raw))
        // Keep exactly one entry at or before (t − window): the trend's reference point.
        while history.count >= 2, history[1].t <= t - thresholds.trendWindowS { history.removeFirst() }
    }

    /// The state at `now` (the same monotonic clock as `add`).
    func reading(at now: Double) -> Reading {
        guard let smoothed, let lastAt, now - lastAt < thresholds.signalLostS else { return .noSignal }
        let band = self.band ?? Self.band(for: smoothed, thresholds: thresholds)
        var trend = Trend.steady
        if let reference = history.first, reference.t <= lastAt - thresholds.trendWindowS {
            let change = smoothed - reference.value
            if change >= thresholds.trendThresholdDb { trend = .closer }
            else if change <= -thresholds.trendThresholdDb { trend = .further }
        }
        return Reading(band: band, trend: trend, smoothedDbm: Int(smoothed.rounded()), rawDbm: lastRaw)
    }
}

/// When the "moved up a band" haptic fires (identical on Android): only once a new band has held for `holdS`
/// (`ring_find_haptic_hold_ms`), and only if it is nearer than the last band that held. A brief band-up that falls back
/// within `holdS` fires nothing. The first band seen (opening the screen) is taken as held, silently.
/// Pure: feed it the shown band on every evaluation (readings and ticks) with a monotonic clock.
struct FindRingHapticGate: Equatable {
    let holdS: Double
    private var held: RingProximity.Band?
    private var pending: RingProximity.Band?
    private var pendingSince: Double = 0

    init(holdS: Double = Double(AgaraConfig.Ring.findHapticHoldMs) / 1000) { self.holdS = holdS }

    /// True when the haptic should fire now.
    mutating func update(_ band: RingProximity.Band, at now: Double) -> Bool {
        guard let settled = held else {
            held = band
            pending = band
            pendingSince = now
            return false
        }
        if band != pending {
            pending = band
            pendingSince = now
        }
        if band == settled || now - pendingSince < holdS { return false }
        held = band
        return band > settled
    }

    mutating func reset() {
        held = nil
        pending = nil
    }
}
