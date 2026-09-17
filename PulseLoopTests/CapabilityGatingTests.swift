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

        for metric: MetricKey in [.heartRate, .spo2, .hrv, .stress,
                                  .bloodPressureSystolic, .bloodPressureDiastolic, .bloodSugar] {
            XCTAssertTrue(MetricsService.supports(metric, context: context), metric.rawValue)
        }
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
            .steps, .realtimeSteps, .sleep, .battery,
            .heartRate, .spo2, .spo2History, .hrv, .stress, .bloodSugar, .bloodPressure,
            .manualHeartRate, .manualSpo2, .manualBloodPressure,
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
}
