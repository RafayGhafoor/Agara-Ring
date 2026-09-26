import XCTest
@testable import PulseLoop

/// Find ring proximity math (plan `find-ring-proximity.md`): EMA smoothing, five bands, signal lost, trend.
/// Android's `RingProximityTest` runs the same cases on the same numbers (Rule 2).
final class RingProximityTests: XCTestCase {
    private let th = RingProximity.Thresholds.catalog

    /// Feed `values` at `hz` starting at `t0`; returns the reading after each one.
    private func feed(_ p: inout RingProximity, _ values: [Int], hz: Double = 2, t0: Double = 0) -> [RingProximity.Reading] {
        values.enumerated().map { i, v in
            let t = t0 + Double(i) / hz
            p.add(rssi: v, at: t)
            return p.reading(at: t)
        }
    }

    /// Consecutive duplicates removed.
    private func collapsed<T: Equatable>(_ xs: [T]) -> [T] {
        xs.reduce(into: []) { acc, x in if acc.last != x { acc.append(x) } }
    }

    /// A walk like the emulator's `--rssi-walk` (−95 ↔ −45 dBm over `seconds`, then held) at 2 Hz, with a fixed
    /// ±4 dB body/hand jitter pattern — the shape of a recorded series without depending on a random generator.
    private func walk(farToNear: Bool, seconds: Double = 20, hold: Double = 4) -> [Int] {
        let jitter = [3, -4, 1, -2, 4, 0, -3, 2, -1, 4, -4, 1]
        let n = Int((seconds + hold) * 2)
        return (0..<n).map { i in
            let t = min(1, Double(i) / 2 / seconds)
            let v = farToNear ? -95 + 50 * t : -45 - 50 * t
            return Int(v.rounded()) + jitter[i % jitter.count]
        }
    }

    // MARK: - Catalog + bands

    func testCatalogThresholdsComeFromSharedConfig() {
        XCTAssertEqual(th.rightHereDbm, -55)
        XCTAssertEqual(th.veryCloseDbm, -67)
        XCTAssertEqual(th.warmerDbm, -78)
        XCTAssertEqual(th.farDbm, -88)
        XCTAssertEqual(th.signalLostS, 5)
        XCTAssertEqual(th.smoothingS, 2)
        XCTAssertEqual(th.trendWindowS, 4)
        XCTAssertEqual(th.trendThresholdDb, 3)
    }

    func testBandBoundariesAreInclusiveAtTheThreshold() {
        XCTAssertEqual(RingProximity.band(for: -40), .rightHere)
        XCTAssertEqual(RingProximity.band(for: -55), .rightHere)
        XCTAssertEqual(RingProximity.band(for: -55.1), .veryClose)
        XCTAssertEqual(RingProximity.band(for: -67), .veryClose)
        XCTAssertEqual(RingProximity.band(for: -67.1), .warmer)
        XCTAssertEqual(RingProximity.band(for: -78), .warmer)
        XCTAssertEqual(RingProximity.band(for: -78.1), .far)
        XCTAssertEqual(RingProximity.band(for: -88), .far)
        XCTAssertEqual(RingProximity.band(for: -88.1), .outOfRange)
        XCTAssertEqual(RingProximity.band(for: -110), .outOfRange)
    }

    func testBandLabelsCirclesAndPulseFollowTheOrder() {
        XCTAssertEqual(RingProximity.Band.rightHere.label, "Right here")
        XCTAssertEqual(RingProximity.Band.veryClose.label, "Very close")
        XCTAssertEqual(RingProximity.Band.warmer.label, "Getting warmer")
        XCTAssertEqual(RingProximity.Band.far.label, "Far")
        XCTAssertEqual(RingProximity.Band.outOfRange.label, "Out of range — walk around")
        let bands = RingProximity.Band.allCases
        XCTAssertEqual(bands.map(\.filledCircles), [0, 1, 2, 3, 4])
        let periods = bands.map(\.pulsePeriod)
        XCTAssertEqual(periods, periods.sorted(by: >), "the pulse must speed up as the band rises")
    }

    // MARK: - Smoothing

    func testFirstReadingSeedsTheAverage() {
        var p = RingProximity()
        XCTAssertEqual(p.reading(at: 0), .noSignal)
        p.add(rssi: -70, at: 100)
        XCTAssertEqual(p.reading(at: 100), .init(band: .warmer, trend: .steady, smoothedDbm: -70, rawDbm: -70))
    }

    func testTimeBasedExponentialMovingAverage() {
        var p = RingProximity()
        p.add(rssi: -60, at: 0)
        p.add(rssi: -80, at: 2)   // Δt = τ → α = 1 − e⁻¹ ≈ 0.632 → −72.64
        XCTAssertEqual(p.smoothed ?? 0, -60 - 20 * (1 - exp(-1)), accuracy: 1e-9)
        XCTAssertEqual(p.reading(at: 2).smoothedDbm, -73)
        XCTAssertEqual(p.reading(at: 2).rawDbm, -80)
        p.add(rssi: -80, at: 2.5) // Δt = 0.5 → α = 1 − e^−0.25
        let expected = (-60 - 20 * (1 - exp(-1))) + (1 - exp(-0.25)) * (-80 - (-60 - 20 * (1 - exp(-1))))
        XCTAssertEqual(p.smoothed ?? 0, expected, accuracy: 1e-9)
    }

    func testJitterDoesNotFlipTheBand() {
        var p = RingProximity()
        // ±5 dB around −62 (Very close) for 10 s: a raw reading dips to −67/−68 but the band holds.
        let readings = feed(&p, (0..<20).map { $0 % 2 == 0 ? -57 : -67 } + [-68, -56, -68, -57])
        XCTAssertEqual(Set(readings.map(\.band)), [.veryClose])
    }

    func testInvalidReadingsAreIgnored() {
        var p = RingProximity()
        p.add(rssi: 127, at: 0)   // CoreBluetooth "not available"
        p.add(rssi: 1, at: 0.5)
        p.add(rssi: -128, at: 1)
        XCTAssertEqual(p.reading(at: 1), .noSignal)
        p.add(rssi: -60, at: 1.5)
        p.add(rssi: 127, at: 2)
        XCTAssertEqual(p.reading(at: 2).rawDbm, -60)
    }

    // MARK: - Signal lost

    func testNoSignalForFiveSecondsIsOutOfRangeAndRestartsTheAverage() {
        var p = RingProximity()
        p.add(rssi: -50, at: 10)
        XCTAssertEqual(p.reading(at: 14.9).band, .rightHere)
        XCTAssertEqual(p.reading(at: 15), .noSignal)
        // A reading after the gap seeds a fresh average rather than blending with the stale one.
        p.add(rssi: -85, at: 16)
        XCTAssertEqual(p.reading(at: 16), .init(band: .far, trend: .steady, smoothedDbm: -85, rawDbm: -85))
    }

    func testWeakSignalIsOutOfRangeWithItsValue() {
        var p = RingProximity()
        p.add(rssi: -95, at: 0)
        let r = p.reading(at: 0)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.rawDbm, -95)
        XCTAssertEqual(r.trend, .steady)
        // Still a signal, so a climb inside Out of range reads "closer" (same as Android).
        var q = RingProximity()
        let readings = feed(&q, (0..<10).map { -110 + 2 * $0 })
        XCTAssertEqual(readings.last?.band, .outOfRange)
        XCTAssertEqual(readings.last?.trend, .closer)
    }

    func testTrendNeedsAFullWindowOfHistory() {
        var p = RingProximity()
        // A fast climb, but only 3.5 s of readings: no reference ≥ 4 s old yet → steady.
        let readings = feed(&p, (0..<8).map { -90 + 4 * $0 })
        XCTAssertEqual(readings.last?.trend, .steady)
        p.add(rssi: -58, at: 4)   // now the t = 0 reading is exactly one window old
        XCTAssertEqual(p.reading(at: 4).trend, .closer)
    }

    // MARK: - Trend

    func testTrendOverTheWindow() {
        var steady = RingProximity()
        XCTAssertEqual(feed(&steady, Array(repeating: -70, count: 12)).last?.trend, .steady)

        var rising = RingProximity()   // +2 dB per 0.5 s
        XCTAssertEqual(feed(&rising, (0..<12).map { -80 + 2 * $0 }).last?.trend, .closer)

        var falling = RingProximity()
        XCTAssertEqual(feed(&falling, (0..<12).map { -56 - 2 * $0 }).last?.trend, .further)

        var creeping = RingProximity() // +1 dB over the whole window: below the 3 dB threshold
        XCTAssertEqual(feed(&creeping, [-70, -70, -70, -70, -70, -70, -69, -69, -69, -69, -69, -69]).last?.trend, .steady)
    }

    func testTrendOnlyLooksAtTheLastWindow() {
        var p = RingProximity()
        // A climb 10 s ago, then 6 s flat: the old climb has left the 4 s window.
        let readings = feed(&p, (0..<8).map { -85 + 3 * $0 } + Array(repeating: -64, count: 24))
        XCTAssertEqual(readings.last?.trend, .steady)
    }

    // MARK: - Hysteresis

    /// Catalog thresholds with (almost) no smoothing, so smoothed == raw and the band rule is visible directly.
    private func raw(hysteresis: Double = 3) -> RingProximity {
        var t = RingProximity.Thresholds.catalog
        t.smoothingS = 0.0001
        t.bandHysteresisDb = hysteresis
        return RingProximity(thresholds: t)
    }

    func testHysteresisCatalogValue() {
        XCTAssertEqual(th.bandHysteresisDb, 3)
    }

    func testBandMovesOnlyWhenTheBoundaryIsClearedByThreeDb() {
        var p = raw()
        // Boundary −67: −68/−69/−70 stay Very close (dropping needs < −70).
        XCTAssertEqual(feed(&p, [-60, -68, -69, -70]).map(\.band), [.veryClose, .veryClose, .veryClose, .veryClose])
        var q = raw()
        let down = feed(&q, [-60, -71, -66, -65, -64])
        // −71 < −70 → Getting warmer; −66/−65 stay (need ≥ −64 to rise); −64 → Very close.
        XCTAssertEqual(down.map(\.band), [.veryClose, .warmer, .warmer, .warmer, .veryClose])
    }

    func testJitterAtABoundaryDoesNotFlipTheBand() {
        // Raw ±3 dB around the −67 boundary with the real smoothing: without hysteresis it flips, with it it holds.
        let series = [-66] + (0..<30).map { $0 % 2 == 0 ? -70 : -64 }
        var with = RingProximity()
        XCTAssertEqual(Set(feed(&with, series).map(\.band)).count, 1)
        var t = RingProximity.Thresholds.catalog
        t.bandHysteresisDb = 0
        var without = RingProximity(thresholds: t)
        XCTAssertGreaterThan(Set(feed(&without, series).map(\.band)).count, 1, "the series must cross the boundary")
    }

    func testABigJumpStepsThroughSeveralBandsAtOnce() {
        var p = raw()
        XCTAssertEqual(feed(&p, [-95, -40]).map(\.band), [.outOfRange, .rightHere])
        XCTAssertEqual(feed(&p, [-100], t0: 1).map(\.band), [.outOfRange])
    }

    func testFirstReadingAfterALossTakesItsBandWithoutHysteresis() {
        var p = raw()
        _ = feed(&p, [-60])                     // Very close
        p.add(rssi: -69, at: 10)                // after a 10 s gap: fresh → Getting warmer straight away
        XCTAssertEqual(p.reading(at: 10).band, .warmer)
    }

    // MARK: - Haptic gate

    func testHapticHoldCatalogValue() {
        XCTAssertEqual(FindRingHapticGate().holdS, 1)
    }

    func testHapticFiresOnceANearerBandHasHeldOneSecond() {
        var g = FindRingHapticGate(holdS: 1)
        XCTAssertFalse(g.update(.far, at: 0), "opening the screen is silent")
        XCTAssertFalse(g.update(.warmer, at: 1))
        XCTAssertFalse(g.update(.warmer, at: 1.9))
        XCTAssertTrue(g.update(.warmer, at: 2.0))
        XCTAssertFalse(g.update(.warmer, at: 2.5), "fires once per band")
    }

    func testNoHapticOnABriefBandChange() {
        var g = FindRingHapticGate(holdS: 1)
        _ = g.update(.far, at: 0)
        XCTAssertFalse(g.update(.warmer, at: 1))
        XCTAssertFalse(g.update(.warmer, at: 1.5))
        XCTAssertFalse(g.update(.far, at: 1.8), "fell back within the hold")
        XCTAssertFalse(g.update(.far, at: 5))
        // Up again: the hold restarts from this change.
        XCTAssertFalse(g.update(.warmer, at: 6))
        XCTAssertFalse(g.update(.warmer, at: 6.9))
        XCTAssertTrue(g.update(.warmer, at: 7))
    }

    func testNoHapticMovingAwayAndAgainWhenComingBack() {
        var g = FindRingHapticGate(holdS: 1)
        _ = g.update(.veryClose, at: 0)
        XCTAssertFalse(g.update(.far, at: 1))
        XCTAssertFalse(g.update(.far, at: 2), "a held move away is silent")
        XCTAssertFalse(g.update(.warmer, at: 3))
        XCTAssertTrue(g.update(.warmer, at: 4), "nearer than the last held band (Far)")
        g.reset()
        XCTAssertFalse(g.update(.rightHere, at: 10), "after reset the first band is silent again")
    }

    // MARK: - Walks (the E2E shape)

    func testFarToNearWalkRisesThroughEveryBandGettingCloser() {
        var p = RingProximity()
        let readings = feed(&p, walk(farToNear: true))
        let firstSeen = collapsed(readings.map(\.band)).reduce(into: [RingProximity.Band]()) { acc, b in
            if !acc.contains(b) { acc.append(b) }
        }
        XCTAssertEqual(firstSeen, [.outOfRange, .far, .warmer, .veryClose, .rightHere])
        XCTAssertEqual(readings.last?.band, .rightHere)
        XCTAssertTrue(readings.contains { $0.trend == .closer })
        XCTAssertFalse(readings.contains { $0.trend == .further }, "a steady approach never reads 'further'")
    }

    func testNearToFarWalkFallsGettingFurther() {
        var p = RingProximity()
        let readings = feed(&p, walk(farToNear: false))
        XCTAssertEqual(readings.first?.band, .rightHere)
        XCTAssertEqual(readings.last?.band, .outOfRange)
        XCTAssertTrue(readings.contains { $0.trend == .further })
        XCTAssertFalse(readings.contains { $0.trend == .closer })
    }

    #if DEBUG
    func testEmulatorReplyParses() {
        XCTAssertEqual(VirtualRingLink.parseRSSI("RSSI -63"), -63)
        XCTAssertEqual(VirtualRingLink.parseRSSI("RSSI -100"), -100)
        XCTAssertNil(VirtualRingLink.parseRSSI("N 0000fee3 b50a01"))
        XCTAssertNil(VirtualRingLink.parseRSSI("RSSI"))
        XCTAssertNil(VirtualRingLink.parseRSSI("RSSI x"))
    }
    #endif
}
