import XCTest
import SwiftData
@testable import PulseLoop

/// The product UI gates metric cards on the active device's capabilities. For the Agara ring that means
/// the metrics the Veepoo/TK20 protocol actually delivers, and nothing else: a card for a metric the
/// ring never records would render permanently empty.
@MainActor
final class CapabilityGatingTests: XCTestCase {

    private var agara: Set<WearableCapability> { VeepooCoordinator().capabilities }

    func testTheAgaraRingSurfacesTheMetricsItRecords() throws {
        let context = try TestSupport.makeContext()
        context.insert(Device(deviceType: .veepoo, capabilities: agara))
        try context.save()

        for metric: MetricKey in [.heartRate, .spo2, .hrv, .stress] {
            XCTAssertTrue(MetricsService.supports(metric, context: context), metric.rawValue)
        }
    }

    /// Store launch (owner, 2026-09-29): blood pressure and blood sugar are off by flag even though the ring
    /// records them. Nothing shows for them until `vitals_bp` / `vitals_glucose` are on.
    func testBloodPressureAndGlucoseAreHiddenWhileTheirFlagsAreOff() throws {
        let store = AgaraFeatureStore.shared
        let saved = (store.override(for: .vitalsBp), store.override(for: .vitalsGlucose))
        defer { store.setOverride(.vitalsBp, saved.0); store.setOverride(.vitalsGlucose, saved.1) }
        store.setOverride(.vitalsBp, nil)
        store.setOverride(.vitalsGlucose, nil)
        XCTAssertFalse(AgaraFeature.vitalsBp.defaultOn)
        XCTAssertFalse(AgaraFeature.vitalsGlucose.defaultOn)

        let context = try TestSupport.makeContext()
        context.insert(Device(deviceType: .veepoo, capabilities: agara))
        try context.save()
        for metric: MetricKey in [.bloodPressureSystolic, .bloodPressureDiastolic, .bloodSugar] {
            XCTAssertFalse(MetricsService.supports(metric, context: context), metric.rawValue)
        }

        // The debug override brings the (still-working) hidden code back, so e2e runs keep covering it.
        store.setOverride(.vitalsBp, true)
        store.setOverride(.vitalsGlucose, true)
        for metric: MetricKey in [.bloodPressureSystolic, .bloodPressureDiastolic, .bloodSugar] {
            XCTAssertTrue(MetricsService.supports(metric, context: context), metric.rawValue)
        }
    }

    /// The measure hub offers no BP or glucose tile (or the auto-measure rows) with the flags at their defaults.
    func testMeasureHubOffersNoBloodPressureOrGlucoseByDefault() {
        let defaults: (AgaraFeature) -> Bool = { $0.defaultOn }
        let ring = Set(WearableCapability.allCases)
        let ids = MeasurementRegistry.available(capabilities: ring, ring: nil, isOn: defaults).map(\.id)
        XCTAssertFalse(ids.contains("bloodPressure"))
        XCTAssertFalse(ids.contains("glucose"))
        XCTAssertTrue(ids.contains("heartRate"))
        let allOn = MeasurementRegistry.available(capabilities: ring, ring: nil, isOn: { _ in true }).map(\.id)
        XCTAssertTrue(allOn.contains("bloodPressure"))
        XCTAssertTrue(allOn.contains("glucose"))

        XCTAssertFalse(AutoMeasureSettingsView.isOffered(1, isOn: defaults), "BP schedule row")
        XCTAssertFalse(AutoMeasureSettingsView.isOffered(2, isOn: defaults), "glucose schedule row")
        XCTAssertTrue(AutoMeasureSettingsView.isOffered(0, isOn: defaults), "heart-rate schedule row")
    }

    /// The ring records no temperature, no REM staging and no blood-fatigue score, and it measures vitals
    /// one at a time (no combined sweep). Those cards stay out of the grid rather than sitting empty.
    func testTheAgaraRingHidesTheMetricsItDoesNotRecord() throws {
        let context = try TestSupport.makeContext()
        context.insert(Device(deviceType: .veepoo, capabilities: agara))
        try context.save()

        for metric: MetricKey in [.temperature, .fatigue] {
            XCTAssertFalse(MetricsService.supports(metric, context: context), metric.rawValue)
        }
    }

    /// The declared set, straight from the coordinator — the one place a capability can come from. Each
    /// entry is a verified protocol feature (see `docs/ring/veepoo-protocol.md`).
    func testTheAgaraCoordinatorDeclaresTheVerifiedSet() {
        let coordinator = VeepooCoordinator()
        XCTAssertEqual(coordinator.capabilities, [
            .steps, .realtimeSteps, .sleep, .remSleep, .battery,   // REM: A5 stage bitmap, verified 2026-09-25
            .heartRate, .spo2, .spo2History, .hrv, .stress, .bloodSugar, .bloodPressure,
            .manualHeartRate, .manualSpo2, .manualBloodPressure,
            // Measure hub (measure-hub-spec): tests the ring's `a7` packets advertise, the DF series it
            // fills, and find-device (`b5`).
            .manualStress, .manualBloodSugar, .manualBloodComponents,
            .respiration, .met, .cardiacLoad, .bloodComponents, .findDevice,
        ])
        // No per-unit sensor bitmap on this protocol, so nothing is bitmap-gated.
        XCTAssertTrue(coordinator.bitmapGatedCapabilities.isEmpty)
        XCTAssertEqual(coordinator.refinedCapabilities(bitmapDerived: [.temperature]), coordinator.capabilities)
    }

    /// A device row that predates capability stamping (empty `capabilitiesRaw`) still shows the base
    /// metrics, so an upgrade doesn't cost anyone their HR/SpO₂ cards.
    func testLegacyDeviceFallsBackToBaseMetrics() throws {
        let context = try TestSupport.makeContext()
        context.insert(Device(deviceType: .veepoo, capabilities: []))
        try context.save()

        XCTAssertTrue(MetricsService.supports(.heartRate, context: context))
        XCTAssertTrue(MetricsService.supports(.spo2, context: context))
        XCTAssertFalse(MetricsService.supports(.hrv, context: context))
    }

    func testCapabilityCSVRoundTrip() {
        let caps: Set<WearableCapability> = [.heartRate, .hrv, .bloodPressure]
        XCTAssertEqual(Set<WearableCapability>(csv: caps.csv), caps)
        // Unknown tokens (an older or newer store) are ignored rather than failing the parse.
        XCTAssertEqual(Set<WearableCapability>(csv: "heartRate,notACapability"), [.heartRate])
    }

    /// The bitmap refinement stays additive-only: a device bitmap may grant a capability the coordinator
    /// pre-approved, and can never conjure one it did not — nor remove part of the baseline.
    func testRefinementIsAdditiveAndPreApprovedOnly() {
        let refined = GatedCoordinator().refinedCapabilities(
            bitmapDerived: [.temperature, .fatigue, .bloodSugar]
        )
        XCTAssertTrue(refined.contains(.temperature), "pre-approved, so the bitmap may grant it")
        XCTAssertFalse(refined.contains(.bloodSugar), "not pre-approved: the bitmap cannot conjure it")
        XCTAssertTrue(refined.isSuperset(of: GatedCoordinator().capabilities),
                      "a bitmap can never remove a baseline capability")
    }

    /// A coordinator that opts into bitmap gating, used only to exercise the mechanism.
    private struct GatedCoordinator: WearableCoordinator {
        static let deviceType: RingDeviceType = .veepoo
        static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool { false }
        init() {}
        let capabilities: Set<WearableCapability> = [.heartRate, .spo2, .steps]
        let bitmapGatedCapabilities: Set<WearableCapability> = [.temperature, .stress]
        let iconSystemName = "circle"
        func makeDriver(writer: RingCommandWriter) -> WearableDriver { VeepooDriver(writer: writer) }
    }

    // MARK: Nothing the ring doesn't support (owner rule, 2026-09-29)

    /// Sample mode ("Explore without ring") has no device row; its capabilities must be exactly the TK20
    /// catalog's, so it can never show a metric the real ring lacks.
    func testSampleModeCapabilitiesAreExactlyTheTK20Catalog() throws {
        UserDefaults.standard.set(true, forKey: SampleDataStore.activeKey)
        defer { UserDefaults.standard.removeObject(forKey: SampleDataStore.activeKey) }
        let context = try TestSupport.makeContext()
        XCTAssertEqual(MetricsService.deviceCapabilities(context), agara)
        XCTAssertEqual(MetricsService.deviceCapabilities(context), VeepooCoordinator().capabilities)
        for extra: WearableCapability in [.temperature, .fatigue, .manualHrv, .combinedVitalsMeasurement] {
            XCTAssertFalse(MetricsService.deviceCapabilities(context).contains(extra), extra.rawValue)
        }
    }

    /// The debug demo seed (`SeedData.seedDemo`) also advertises the TK20 set and no more.
    func testDemoSeedDeviceAdvertisesExactlyTheTK20Set() throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true)
        let device = try XCTUnwrap(try context.fetch(FetchDescriptor<Device>()).first)
        XCTAssertEqual(device.capabilities, agara)
        let kinds = Set(try context.fetch(FetchDescriptor<PulseLoop.Measurement>()).map(\.kind))
        XCTAssertFalse(kinds.contains(.fatigue))
        XCTAssertFalse(kinds.contains(.temperature))
    }

    /// A TK20-capability device shows no fatigue / skin-temperature card (Today or Vitals), and none of the
    /// flag-gated metrics at their default flags.
    func testTK20DeviceShowsNoFatigueTemperatureOrFlaggedCards() throws {
        let store = AgaraFeatureStore.shared
        let flags: [AgaraFeature] = [.vitalsBp, .vitalsGlucose, .vitalsRespiration, .vitalsMet, .vitalsCardiacLoad, .bloodComponents]
        let saved = flags.map { store.override(for: $0) }
        defer { for (f, v) in zip(flags, saved) { store.setOverride(f, v) } }
        for f in flags { store.setOverride(f, nil); XCTAssertFalse(f.defaultOn, "\(f)") }

        let context = try TestSupport.makeContext()
        context.insert(UserProfile(name: "Rae", onboardingCompleted: true, baselineCompleted: true))
        context.insert(Device(deviceType: .veepoo, capabilities: agara))
        try context.save()

        let hidden: [MetricKey] = [.fatigue, .temperature, .bloodPressureSystolic, .bloodPressureDiastolic, .bloodSugar,
                                   .respiratoryRate, .met, .cardiacLoad, .bloodComponents]
        let today = TodayStore(modelContext: context)
        let vitals = VitalsStore(modelContext: context)
        for metric in hidden {
            XCTAssertFalse(MetricsService.isVisible(metric, context: context), "vitals \(metric.rawValue)")
            XCTAssertFalse(MetricsService.isVisible(metric, context: context, scope: .today), "today \(metric.rawValue)")
            XCTAssertFalse(today.visibleMetrics.contains(metric), "today store \(metric.rawValue)")
            XCTAssertFalse(vitals.visibleMetrics.contains(metric), "vitals store \(metric.rawValue)")
        }
        for metric: MetricKey in [.heartRate, .spo2, .hrv, .stress] {
            XCTAssertTrue(vitals.visibleMetrics.contains(metric), metric.rawValue)
        }
    }

    /// The measure sweep result sheet never offers a fatigue tile.
    func testVitalsResultTilesNeverIncludeFatigue() {
        var reading = RingSyncCoordinator.VitalsReading()
        reading.heartRate = 70
        reading.fatigue = 40
        XCTAssertFalse(VitalsResultsView.tiles(for: reading).contains { $0.name == "Fatigue" })
    }
}
