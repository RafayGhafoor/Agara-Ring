import XCTest
import SwiftUI
@testable import PulseLoop

/// Time-to-full (`ChargeEstimator`), the Appearance defaults and resolution (`AppearanceDefaults`,
/// `AppearanceStore`), and the one-time hints (`CoachMarkStore`). Same cases as Android
/// `ChargeEstimatorTest` / `AppearanceStoreTest` / `CoachMarkTest`.
final class ChargeEstimatorTests: XCTestCase {
    private typealias R = ChargeEstimator.Reading
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// The real charge of 2026-09-25: 33 → 49 % from 18:17 to 18:27, one battery frame about every 37 s.
    private func realCharge() -> [R] {
        var readings: [R] = []
        var t: TimeInterval = 0
        while t < 600 {
            readings.append(R(date: start.addingTimeInterval(t), percent: 33 + Int(16 * t / 600)))
            t += 37
        }
        readings.append(R(date: start.addingTimeInterval(600), percent: 49))
        return readings
    }

    func testRealChargeIsAboutFiftyMinutes() {
        let readings = realCharge()
        XCTAssertEqual(readings.count, 18)
        // 1.6 %/min: 49 → 80 in ~19.4 min, 80 → 100 at 0.64 %/min in ~31.3 min → 50.6 → 50.
        XCTAssertEqual(ChargeEstimator.estimate(readings), .fullIn(minutes: 50))
        XCTAssertEqual(ChargeEstimator.estimate(readings).text, "Full in ~50 min")
        XCTAssertEqual(ChargeEstimator.minutesToFull(percent: 49, ratePerMinute: 1.6), 50.625, accuracy: 0.001)
    }

    func testSeriesFedFrameByFrameGivesTheSameEstimate() {
        var series = ChargeEstimator.Series()
        for r in realCharge() { series.add(percent: r.percent, at: r.date) }
        XCTAssertEqual(series.estimate, .fullIn(minutes: 50))
    }

    func testChargingUntilThreeReadingsOverThreeMinutes() {
        let two = [R(date: start, percent: 40), R(date: start.addingTimeInterval(600), percent: 50)]
        XCTAssertEqual(ChargeEstimator.estimate(two), .charging, "two readings are not enough, however far apart")
        let short = (0..<5).map { R(date: start.addingTimeInterval(Double($0) * 30), percent: 40 + $0) }
        XCTAssertEqual(ChargeEstimator.estimate(short), .charging, "5 readings over 2 min are too short a span")
        XCTAssertEqual(ChargeEstimator.estimate([]), .charging)
        XCTAssertEqual(ChargeEstimator.estimate(two).text, "Charging")
    }

    func testFlatOrFallingLevelStaysCharging() {
        let flat = (0..<6).map { R(date: start.addingTimeInterval(Double($0) * 60), percent: 60) }
        XCTAssertEqual(ChargeEstimator.estimate(flat), .charging)
    }

    func testFullAtHundred() {
        XCTAssertEqual(ChargeEstimator.estimate([R(date: start, percent: 100)]), .fullyCharged)
        XCTAssertEqual(ChargeEstimator.Estimate.fullyCharged.text, "Fully charged")
    }

    func testTaperAppliesOnlyAboveEighty() {
        // Below 80 all the way: 2 %/min from 50 → 80 = 15 min, then 20 % at 0.8 %/min = 25 min.
        XCTAssertEqual(ChargeEstimator.minutesToFull(percent: 50, ratePerMinute: 2), 40, accuracy: 0.001)
        // Starting past the knee: only the tapered part.
        XCTAssertEqual(ChargeEstimator.minutesToFull(percent: 90, ratePerMinute: 2), 12.5, accuracy: 0.001)
        // A rate measured above 80 % is already the slow one — not tapered twice.
        XCTAssertEqual(ChargeEstimator.minutesToFull(percent: 90, ratePerMinute: 0.5, alreadyTapered: true), 20, accuracy: 0.001)
        let high = (0..<5).map { R(date: start.addingTimeInterval(Double($0) * 120), percent: 86 + $0) }   // 0.5 %/min
        XCTAssertEqual(ChargeEstimator.estimate(high), .fullIn(minutes: 20))
    }

    func testRoundingToFiveNeverZero() {
        XCTAssertEqual(ChargeEstimator.roundToFive(50.6), 50)
        XCTAssertEqual(ChargeEstimator.roundToFive(52.5), 55)
        XCTAssertEqual(ChargeEstimator.roundToFive(1), 5)
        XCTAssertEqual(ChargeEstimator.roundToFive(.infinity), 5)
    }

    func testSeriesDropsDuplicatesRestartsOnADropAndStaysSmall() {
        var series = ChargeEstimator.Series()
        series.add(percent: 40, at: start)
        series.add(percent: 40, at: start)   // same frame seen twice
        XCTAssertEqual(series.readings.count, 1)
        series.add(percent: 41, at: start.addingTimeInterval(60))
        series.add(percent: 38, at: start.addingTimeInterval(120))   // level fell: a new charge
        XCTAssertEqual(series.readings.map(\.percent), [38])
        for i in 1...50 { series.add(percent: 38 + i / 3, at: start.addingTimeInterval(120 + Double(i) * 10)) }
        XCTAssertEqual(series.readings.count, ChargeEstimator.maxReadings)
        series.reset()
        XCTAssertTrue(series.readings.isEmpty)
    }

    /// The catalog numbers (shared.yaml `ring_charge_estimate_*`), identical on Android.
    func testRulesComeFromTheSharedCatalog() {
        XCTAssertEqual(ChargeEstimator.windowSpan, TimeInterval(AgaraConfig.Ring.chargeEstimateWindowMin * 60))
        XCTAssertEqual(ChargeEstimator.maxReadings, AgaraConfig.Ring.chargeEstimateMaxSamples)
        XCTAssertEqual(ChargeEstimator.minReadings, AgaraConfig.Ring.chargeEstimateMinSamples)
        XCTAssertEqual(ChargeEstimator.minSpan, TimeInterval(AgaraConfig.Ring.chargeEstimateMinSpanMin * 60))
        XCTAssertEqual(ChargeEstimator.taperStartPercent, AgaraConfig.Ring.chargeEstimateTaperStartPercent)
        XCTAssertEqual(ChargeEstimator.taperFactor, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ChargeEstimator.roundMinutes, AgaraConfig.Ring.chargeEstimateRoundMin)
    }

    /// Only the last 15 minutes count: an old, slow stretch must not drag the rate down.
    func testReadingsOlderThanTheWindowAreIgnored() {
        // 30 → 32 % over the first 20 minutes (slow), then 40 → 50 % over the last 10 (1 %/min).
        var readings = (0..<3).map { R(date: start.addingTimeInterval(Double($0) * 600), percent: 30 + $0) }
        readings += (0...10).map { R(date: start.addingTimeInterval(1_800 + Double($0) * 60), percent: 40 + $0) }
        XCTAssertEqual(ChargeEstimator.window(readings).first?.percent, 40, "only the last 15 min")
        // 50 → 80 at 1 %/min = 30 min, 80 → 100 at 0.4 %/min = 50 min → 80.
        XCTAssertEqual(ChargeEstimator.estimate(readings), .fullIn(minutes: 80))
        var series = ChargeEstimator.Series()
        for r in readings { series.add(percent: r.percent, at: r.date) }
        XCTAssertEqual(series.readings.first?.percent, 40, "the series keeps only the window too")
        XCTAssertEqual(series.estimate, .fullIn(minutes: 80))
    }

    /// The taper is skipped only when *every* reading in the window is already at or above 80 %.
    func testTaperSkippedOnlyWhenTheWholeWindowIsAboveTheKnee() {
        // 78 → 88 % in 10 min (1 %/min): part of the window is below 80, so the rest is tapered:
        // 12 % at 0.4 %/min = 30 min.
        let mixed = (0...10).map { R(date: start.addingTimeInterval(Double($0) * 60), percent: 78 + $0) }
        XCTAssertEqual(ChargeEstimator.estimate(mixed), .fullIn(minutes: 30))
        // 80 → 90 % in 10 min: all ≥ 80, the measured rate is already the slow one → 10 min.
        let high = (0...10).map { R(date: start.addingTimeInterval(Double($0) * 60), percent: 80 + $0) }
        XCTAssertEqual(ChargeEstimator.estimate(high), .fullIn(minutes: 10))
    }

    func testStatusLines() {
        XCTAssertEqual(ChargeEstimator.statusLine(percent: 49, estimate: .fullIn(minutes: 50)), "Charging · 49 % · Full in ~50 min")
        XCTAssertEqual(ChargeEstimator.statusLine(percent: 49, estimate: .charging), "Charging · 49 %")
        XCTAssertEqual(ChargeEstimator.statusLine(percent: nil, estimate: nil), "Charging")
        XCTAssertEqual(ChargeEstimator.statusLine(percent: 100, estimate: .fullyCharged), "Fully charged · 100 %")
    }

    func testHeaderChipAndSettingsCardCarryTheEstimate() {
        XCTAssertEqual(
            RingStatusChip.accessibilityLabel(ringName: "Spare", statusLabel: "Connected", battery: 49, charging: true,
                                              chargeEstimate: .fullIn(minutes: 50)),
            "Spare charging, battery 49 percent, full in about 50 minutes"
        )
        XCTAssertEqual(
            RingStatusChip.accessibilityLabel(ringName: "Spare", statusLabel: "Connected", battery: 49, charging: true,
                                              chargeEstimate: .charging),
            "Spare charging, battery 49 percent"
        )
        let status = DeviceHeroStatus.make(state: .connected, connectedName: "Agara Ring", knownName: "Agara Ring",
                                           batteryPercent: 49, lastSync: nil, now: start, isCharging: true,
                                           chargeEstimate: .fullIn(minutes: 50))
        XCTAssertEqual(status.statusLine, "Charging · 49 % · Full in ~50 min")
    }

    /// The live pipeline: a battery frame (level, then charging flag) seeds the series; leaving the charger clears it.
    func testClientCollectsReadingsOnlyWhileCharging() {
        let client = RingBLEClient(startManager: false)
        client.emit(.battery(percent: 40))
        client.emit(.chargingState(isCharging: false))
        XCTAssertTrue(client.chargeSeries.readings.isEmpty)
        XCTAssertNil(client.chargeEstimate)

        client.emit(.battery(percent: 41))
        client.emit(.chargingState(isCharging: true))
        XCTAssertEqual(client.chargeSeries.readings.map(\.percent), [41])
        XCTAssertEqual(client.chargeEstimate, .charging)

        client.emit(.battery(percent: 42))
        client.emit(.chargingState(isCharging: true))
        XCTAssertEqual(client.chargeSeries.readings.map(\.percent), [41, 42], "one reading per frame")

        client.emit(.battery(percent: 42))
        client.emit(.chargingState(isCharging: false))
        XCTAssertTrue(client.chargeSeries.readings.isEmpty)
        XCTAssertNil(client.chargeEstimate)
    }
}

final class AppearanceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AppearanceTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        ThemeStore.current = .dark
    }

    func testDefaultsBySex() {
        XCTAssertEqual(AppearanceDefaults.flavour(for: "male"), "ember")
        XCTAssertEqual(AppearanceDefaults.flavour(for: "female"), "rose")
        XCTAssertEqual(AppearanceDefaults.flavour(for: "Female"), "rose")
        XCTAssertEqual(AppearanceDefaults.flavour(for: "other"), "ember")
        XCTAssertEqual(AppearanceDefaults.flavour(for: nil), "ember")
        XCTAssertEqual(AppearanceDefaults.mode, .system)
    }

    func testFourFlavoursEachWithADarkAndALightTheme() {
        let flavours = AppearanceFlavour.all
        XCTAssertEqual(flavours.map(\.id), ["ember", "midnight", "forest", "rose"])
        XCTAssertEqual(flavours.map(\.name), ["Ember", "Midnight", "Forest", "Rose"])
        for f in flavours {
            XCTAssertFalse(f.dark.isLight)
            XCTAssertTrue(f.light.isLight)
        }
    }

    func testResolutionModeTimesSystemTimesFlavour() {
        let cases: [(AppearanceMode, Bool, String, String)] = [
            (.system, true, "ember", "dark"),
            (.system, false, "ember", "light"),
            (.dark, false, "ember", "dark"),
            (.light, true, "ember", "light"),
            (.system, true, "rose", "rose_dark"),
            (.system, false, "rose", "rose_light"),
            (.dark, false, "midnight", "midnight_dark"),
            (.light, true, "forest", "forest_light"),
            (.light, true, "no-such-flavour", "light"),
        ]
        for (mode, systemDark, flavour, expected) in cases {
            XCTAssertEqual(AppearanceStore.resolve(mode: mode, systemIsDark: systemDark, flavour: flavour).name, expected,
                           "\(mode) / systemDark=\(systemDark) / \(flavour)")
        }
    }

    func testUnchosenFollowsProfileThenTheChoicePersists() {
        let store = AppearanceStore(defaults: defaults)
        XCTAssertNil(store.storedFlavour)
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.resolvedTheme(systemIsDark: true, sex: "female").name, "rose_dark")
        XCTAssertEqual(store.resolvedTheme(systemIsDark: false, sex: "male").name, "light")

        store.setFlavour("forest")
        store.setMode(.dark)
        XCTAssertEqual(store.resolvedTheme(systemIsDark: false, sex: "female").name, "forest_dark",
                       "a choice beats the profile default and the system setting")

        let reloaded = AppearanceStore(defaults: defaults)
        XCTAssertEqual(reloaded.storedFlavour, "forest")
        XCTAssertEqual(reloaded.mode, .dark)
        XCTAssertEqual(reloaded.resolvedTheme(systemIsDark: false, sex: nil).name, "forest_dark")

        reloaded.setFlavour("no-such-flavour")
        XCTAssertEqual(reloaded.storedFlavour, "forest", "an unknown flavour is ignored")
    }

    func testDebugThemeOverrideWins() {
        let store = AppearanceStore(defaults: defaults)
        store.setMode(.dark)
        store.debugThemeOverride = "rose_light"
        XCTAssertEqual(store.resolvedTheme(systemIsDark: true, sex: nil).name, "rose_light")
        store.debugThemeOverride = "bogus"
        XCTAssertEqual(store.resolvedTheme(systemIsDark: true, sex: nil).name, "dark")
    }

    func testThemeStoreIsWhatPulseColorsReads() {
        ThemeStore.current = AppearanceStore.resolve(mode: .light, systemIsDark: true, flavour: "rose")
        XCTAssertEqual(ThemeStore.shared.theme.name, "rose_light")
        XCTAssertEqual(PulseColors.accent, AgaraTheme.roseLight.accent)
    }
}

final class CoachMarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "CoachMarkStoreTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testShownOnceInOrderAndRemembered() {
        // Android's order: the Measure button first, then the ring chip.
        XCTAssertEqual(CoachMarkStore.order, [CoachMarkStore.measure, CoachMarkStore.ringChip])
        let store = CoachMarkStore(defaults: defaults, suppressed: false)
        XCTAssertTrue(store.shouldShow(CoachMarkStore.measure))
        XCTAssertFalse(store.shouldShow(CoachMarkStore.ringChip), "waits for the Measure hint")

        store.markSeen(CoachMarkStore.measure)
        XCTAssertFalse(store.shouldShow(CoachMarkStore.measure))
        XCTAssertTrue(store.shouldShow(CoachMarkStore.ringChip))

        store.markSeen(CoachMarkStore.ringChip)
        let reloaded = CoachMarkStore(defaults: defaults, suppressed: false)
        XCTAssertTrue(reloaded.isSeen(CoachMarkStore.measure))
        XCTAssertFalse(reloaded.shouldShow(CoachMarkStore.ringChip), "seen flags survive a relaunch")

        // Settings › Developer › "Show tips again".
        reloaded.resetAll()
        XCTAssertTrue(reloaded.shouldShow(CoachMarkStore.measure))
        XCTAssertFalse(reloaded.shouldShow(CoachMarkStore.ringChip))
        XCTAssertFalse(CoachMarkStore(defaults: defaults, suppressed: false).isSeen(CoachMarkStore.measure))
    }

    func testSuppressedNeverShows() {
        let store = CoachMarkStore(defaults: defaults, suppressed: true)
        XCTAssertFalse(store.shouldShow(CoachMarkStore.ringChip))
    }
}
