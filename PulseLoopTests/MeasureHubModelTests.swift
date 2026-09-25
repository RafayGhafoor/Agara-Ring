import XCTest
@testable import PulseLoop

/// Feature-flag store, blood-component reference ranges / abnormal count and the measure-hub list
/// (measure-hub-spec §0, §3, §5). Pure — no ring, no store.
@MainActor
final class MeasureHubModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "MeasureHubModelTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: AgaraFeatureStore

    func testParseAcceptsTheLaunchArgumentShape() {
        let parsed = AgaraFeatureStore.parse("blood_components=on, measure_glucose = OFF,vitals_met=true,profile_sync=0")
        XCTAssertEqual(parsed[.bloodComponents], true)
        XCTAssertEqual(parsed[.measureGlucose], false)
        XCTAssertEqual(parsed[.vitalsMet], true)
        XCTAssertEqual(parsed[.profileSync], false)
        XCTAssertEqual(parsed.count, 4)
    }

    func testParseSkipsUnknownFlagsAndMalformedPairs() {
        let parsed = AgaraFeatureStore.parse("nope=on,find_ring,charging_state=maybe,,measure_stress=off")
        XCTAssertEqual(parsed, [.measureStress: false])
        XCTAssertTrue(AgaraFeatureStore.parse("").isEmpty)
    }

    func testDefaultsComeFromTheCatalog() {
        let store = AgaraFeatureStore(defaults: defaults)
        for feature in AgaraFeature.allCases {
            XCTAssertEqual(store.isOn(feature), feature.defaultOn, feature.rawValue)
        }
        XCTAssertTrue(store.isOn(.capabilityProbe))
        XCTAssertFalse(store.isOn(.bloodComponents))
    }

    func testOverridesWinAndPersist() {
        let store = AgaraFeatureStore(defaults: defaults)
        store.applyLaunchOverrides("blood_components=on,capability_probe=off")
        XCTAssertTrue(store.isOn(.bloodComponents))
        XCTAssertFalse(store.isOn(.capabilityProbe))
        // A fresh store (next launch) reads the persisted overrides.
        let reloaded = AgaraFeatureStore(defaults: defaults)
        XCTAssertTrue(reloaded.isOn(.bloodComponents))
        XCTAssertEqual(reloaded.override(for: .capabilityProbe), false)
        reloaded.setOverride(.bloodComponents, nil)
        XCTAssertFalse(reloaded.isOn(.bloodComponents))
        reloaded.resetAll()
        XCTAssertTrue(AgaraFeatureStore(defaults: defaults).overrides.isEmpty)
    }

    func testEmptyLaunchSpecChangesNothing() {
        let store = AgaraFeatureStore(defaults: defaults)
        store.applyLaunchOverrides(nil)
        store.applyLaunchOverrides("")
        XCTAssertTrue(store.overrides.isEmpty)
    }

    // MARK: Reference ranges

    func testHealthRangeParsesTheCatalogShapes() {
        XCTAssertEqual(HealthRange("0.96-1.15", scale: 100), HealthRange(lower: 96, upper: 115))
        XCTAssertEqual(HealthRange("-3.1", scale: 100), HealthRange(lower: nil, upper: 310))
        XCTAssertEqual(HealthRange("150-420", scale: 1), HealthRange(lower: 150, upper: 420))
        XCTAssertNil(HealthRange("garbage", scale: 100))
        let hdl = HealthRange(lower: 96, upper: 115)
        XCTAssertTrue(hdl.contains(raw: 96), "lower inclusive")
        XCTAssertFalse(hdl.contains(raw: 115), "upper exclusive")
        XCTAssertTrue(HealthRange(lower: nil, upper: 310).contains(raw: 0))
    }

    /// Every one of the 43 real C2 records scores 0 abnormal for either sex — including 06:00, whose HDL
    /// of 0.96 the vendor's float compare flags for men. A sample of them, as raw integers.
    func testRealRecordsScoreZeroAbnormal() {
        let records: [(Int, Int, Int, Int, Int)] = [   // TCHO, TG, HDL, LDL (×100), UA (×10)
            (429, 145, 97, 246, 2233),   // 09-24 14:00
            (411, 134, 100, 231, 2111),  // 09-25 00:00
            (445, 153, 96, 268, 2164),   // 09-25 06:00 — HDL exactly on the male lower bound
            (415, 138, 100, 238, 2182),  // 09-25 08:00
            (426, 142, 98, 249, 2413),   // 09-25 14:00
            (436, 148, 98, 254, 2342),   // 09-25 15:30
        ]
        for r in records {
            let reading = BloodComponentsReading(totalCholesterolRaw: r.0, triglyceridesRaw: r.1, hdlRaw: r.2,
                                                 ldlRaw: r.3, uricAcidRaw: r.4)
            for sex in [BiologicalSex.male, .female, .unspecified] {
                XCTAssertEqual(BloodComponents.abnormalCount(reading, sex: sex), 0, "\(r) \(sex)")
                let values = Dictionary(uniqueKeysWithValues: reading.measurements.compactMap { kind, value in
                    MetricKind.bloodComponents.first { $0.measurementKind == kind }.map { ($0, value) }
                })
                XCTAssertEqual(BloodComponentsSummary(values: values, updatedAt: nil, sex: sex).abnormalCount, 0, "\(r) \(sex)")
            }
        }
    }

    func testAbnormalCountAtTheBoundaries() {
        // TCHO exactly 5.17 (upper exclusive) and HDL 1.15 for a man (upper exclusive) → 2 abnormal.
        let male = BloodComponentsReading(totalCholesterolRaw: 517, triglyceridesRaw: 140, hdlRaw: 115,
                                          ldlRaw: 250, uricAcidRaw: 2200)
        XCTAssertEqual(BloodComponents.abnormalCount(male, sex: .male), 2)
        // The same HDL is in range for a woman (0.90–1.55); uric acid 360 µmol/L is out for her (90–360).
        let female = BloodComponentsReading(totalCholesterolRaw: 420, triglyceridesRaw: 140, hdlRaw: 115,
                                            ldlRaw: 250, uricAcidRaw: 3600)
        XCTAssertEqual(BloodComponents.abnormalCount(female, sex: .female), 1)
        XCTAssertEqual(BloodComponents.abnormalCount(female, sex: .male), 1, "HDL 1.15 is out for a man")
        // LDL has no lower bound; 3.10 is out.
        XCTAssertTrue(BloodComponents.isAbnormal(3.10, metric: .ldl, sex: .male))
        XCTAssertFalse(BloodComponents.isAbnormal(0.10, metric: .ldl, sex: .male))
        // Uric acid rounds to whole µmol/L before comparing (vendor): 149.5 → 150 is in range for men.
        XCTAssertFalse(BloodComponents.isAbnormal(149.5, metric: .uricAcid, sex: .male))
        XCTAssertTrue(BloodComponents.isAbnormal(149.4, metric: .uricAcid, sex: .male))
    }

    func testDisplayUnits() {
        XCTAssertEqual(BloodComponents.format(4.36, metric: .totalCholesterol, unit: .mmol), "4.36")
        XCTAssertEqual(BloodComponents.format(4.36, metric: .totalCholesterol, unit: .mgdl), "169")   // ×38.67
        XCTAssertEqual(BloodComponents.format(1.48, metric: .triglycerides, unit: .mgdl), "131")      // ×88.57
        XCTAssertEqual(BloodComponents.format(234.2, metric: .uricAcid, unit: .mmol), "234")
        XCTAssertEqual(BloodComponents.format(234.2, metric: .uricAcid, unit: .mgdl), "3.9")          // ÷59.48
        XCTAssertEqual(BloodComponents.displayUnit(metric: .uricAcid, unit: .mmol), "µmol/L")
        XCTAssertEqual(BloodComponents.displayUnit(metric: .hdl, unit: .mmol), "mmol/L")
        XCTAssertEqual(BloodComponents.displayUnit(metric: .hdl, unit: .mgdl), "mg/dL")
        let back = BloodComponents.canonicalValue(BloodComponents.displayValue(2.54, metric: .ldl, unit: .mgdl),
                                                  metric: .ldl, unit: .mgdl)
        XCTAssertEqual(back, 2.54, accuracy: 1e-9)
    }

    // MARK: Measure hub list

    private func caps(_ list: [WearableCapability]) -> Set<WearableCapability> { Set(list) }

    func testHubOrderAndIdsMatchTheSpec() {
        XCTAssertEqual(MeasureKind.all.map(\.id), ["heartRate", "spo2", "bloodPressure", "stress", "glucose", "bloodComponents"])
    }

    func testStaticCapabilityFallbackWhenNoProbeData() {
        let all = VeepooCoordinator().capabilities
        let defaultsOnly: (AgaraFeature) -> Bool = { $0.defaultOn }
        XCTAssertEqual(MeasureKind.available(capabilities: all, ring: nil, isOn: defaultsOnly).map(\.id),
                       ["heartRate", "spo2", "bloodPressure", "stress"], "glucose/lipids are off by default")
        let everything: (AgaraFeature) -> Bool = { _ in true }
        XCTAssertEqual(MeasureKind.available(capabilities: all, ring: nil, isOn: everything).count, 6)
        XCTAssertEqual(MeasureKind.available(capabilities: caps([.manualHeartRate]), ring: nil, isOn: everything).map(\.id),
                       ["heartRate"])
    }

    func testRingCapabilitiesDecideWhenTheProbeHasRun() {
        var ring = RingCapabilities()
        ring.heartRate = true
        ring.spo2 = true
        ring.stress = false
        ring.bloodGlucose = true
        let all = VeepooCoordinator().capabilities
        let everything: (AgaraFeature) -> Bool = { _ in true }
        XCTAssertEqual(MeasureKind.available(capabilities: all, ring: ring, isOn: everything).map(\.id),
                       ["heartRate", "spo2", "glucose"])
        // Probe flag off → back to the static list, whatever the packets said.
        let probeOff: (AgaraFeature) -> Bool = { $0 != .capabilityProbe }
        XCTAssertEqual(MeasureKind.available(capabilities: all, ring: ring, isOn: probeOff).count, 6)
    }

    func testLipidsNeedBothFlags() {
        let all = VeepooCoordinator().capabilities
        let lipidsOnly: (AgaraFeature) -> Bool = { $0 == .measureLipids }
        XCTAssertFalse(MeasureKind.available(capabilities: all, ring: nil, isOn: lipidsOnly).contains { $0.id == "bloodComponents" })
        let both: (AgaraFeature) -> Bool = { $0 == .measureLipids || $0 == .bloodComponents }
        XCTAssertTrue(MeasureKind.available(capabilities: all, ring: nil, isOn: both).contains { $0.id == "bloodComponents" })
    }

    // MARK: Charging glyph

    func testChargingSweepRunsFromTheLevelToFull() {
        XCTAssertEqual(RingBatteryGlyph.chargingFill(level: 0.4, time: 0), 0.4, accuracy: 1e-9)
        XCTAssertEqual(RingBatteryGlyph.chargingFill(level: 0.4, time: 0.8), 0.7, accuracy: 1e-9)   // half-way
        XCTAssertEqual(RingBatteryGlyph.chargingFill(level: 0.4, time: 1.6), 0.4, accuracy: 1e-9)   // loops
        XCTAssertLessThan(RingBatteryGlyph.chargingFill(level: 0.4, time: 1.59), 1.0 + 1e-9)
    }
}
