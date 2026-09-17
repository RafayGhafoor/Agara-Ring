import XCTest
import UIKit
@testable import PulseLoop

/// The pairing/catalog surface of an **Agara-only** build.
///
/// This replaces the old cross-family matcher suite: with one family there are no cross-claims to
/// assert, so what is worth pinning is that the single-family invariants hold — one catalog card, one
/// coordinator, the ring's own names, and the persistence contract for rows written by the families
/// this build no longer ships.
@MainActor
final class AgaraPairingTests: XCTestCase {

    private let noAdv = AdvertisementInfo(serviceUUIDs: [], manufacturerData: nil)

    /// The `TK20` capture: an `f8f8` company prefix + the MAC byte-reversed.
    private var veepooAdv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [], manufacturerData: Data([0xf8, 0xf8, 0x3b, 0x00, 0x33, 0x34, 0x42, 0x41]))
    }

    // MARK: - Catalog

    func testTheCatalogIsTheAgaraRingAlone() {
        XCTAssertEqual(WearableModel.catalog.map(\.id), ["tk20"])
        XCTAssertEqual(WearableModel.setupCatalog.map(\.id), ["tk20"])

        let ring = try? XCTUnwrap(WearableModel.catalog.first)
        XCTAssertEqual(ring?.family, .veepoo)
        XCTAssertEqual(ring?.displayName, AgaraCopy.ringDisplayName)
        XCTAssertEqual(ring?.brand, AgaraCopy.ringDisplayName)
        // No product art is registered for the Agara ring: nil is the supported path to the generic one.
        XCTAssertNil(ring?.imageName)
    }

    /// The name shown for a ring that never advertised one comes from the shared copy catalog, so the
    /// app name and the ring name cannot drift apart (Rule 5).
    func testTheDeviceTypeDisplayNameComesFromTheCatalog() {
        XCTAssertEqual(RingDeviceType.veepoo.displayName, AgaraCopy.ringDisplayName)
        XCTAssertEqual(RingDeviceType.allCases, [.veepoo])
    }

    func testEveryDeclaredImageNameResolvesToAnAsset() {
        for model in WearableModel.catalog {
            guard let name = model.imageName else { continue }
            XCTAssertNotNil(UIImage(named: name), "missing asset for \(model.id): \(name)")
        }
        // The fallback every art-less card renders must exist too, or the platter comes up empty.
        XCTAssertNotNil(UIImage(named: "generic-ring"))
    }

    // MARK: - Registry + scan matching

    func testTheRegistryIsTheAgaraCoordinatorAlone() {
        XCTAssertEqual(RingBLEClient.coordinators.count, 1)
        XCTAssertEqual(RingBLEClient.coordinators.first?.deviceType, .veepoo)
    }

    func testTheAgaraRingClaimsItsAdvertisedNames() {
        // `TK20` is the verified unit's name; `AGARA` is this build's own branding. F008/F002 are not
        // advertised, so the name is the only pre-connect signal.
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "TK20", advertisement: noAdv), .veepoo)
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "TK20 3B00", advertisement: veepooAdv), .veepoo)
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "AGARA", advertisement: noAdv), .veepoo)
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "AGARA 3B00", advertisement: veepooAdv), .veepoo)
    }

    func testNothingElseIsClaimed() {
        XCTAssertNil(RingBLEClient.matchDeviceType(name: nil, advertisement: veepooAdv))
        XCTAssertNil(RingBLEClient.matchDeviceType(name: "SMART_RING", advertisement: noAdv))
        XCTAssertNil(RingBLEClient.matchDeviceType(name: "R09_ABCD", advertisement: noAdv))
        XCTAssertNil(RingBLEClient.matchDeviceType(name: "TK5", advertisement: noAdv))
    }

    func testCoordinatorTypeFallsBackToTheAgaraRing() {
        XCTAssertEqual(RingBLEClient.coordinatorType(preferredFamily: nil, autoMatched: nil).deviceType, .veepoo)
        XCTAssertEqual(RingBLEClient.coordinatorType(preferredFamily: nil, autoMatched: .veepoo).deviceType, .veepoo)
    }

    // MARK: - Model resolution

    func testAdvertisedNamesResolveToTheModel() {
        XCTAssertEqual(WearableModel.model(advertisedName: "TK20")?.id, "tk20")
        XCTAssertEqual(WearableModel.model(advertisedName: "AGARA 3B00")?.id, "tk20")
        XCTAssertNil(WearableModel.model(advertisedName: "R09_ABCD"))
    }

    func testAnUnidentifiedAgaraRingStillResolves() {
        // No name, no remembered model: the only ring this build drives is still the right answer, and
        // the device card gets a name instead of a blank.
        let resolved = WearableModel.resolve(advertisedName: nil, selectedModelID: nil, family: .veepoo)
        XCTAssertEqual(resolved?.id, "tk20")

        // A remembered selection wins over an unrecognized advertisement.
        let remembered = WearableModel.resolve(advertisedName: "Mystery Ring", selectedModelID: "tk20", family: .veepoo)
        XCTAssertEqual(remembered?.id, "tk20")
    }

    func testACardAcceptsOnlyItsOwnFamily() {
        let ring = WearableModel.catalog[0]
        XCTAssertTrue(ring.acceptsScanFamily(.veepoo))
        XCTAssertFalse(ring.acceptsScanFamily(nil))
    }

    // MARK: - The persistence contract for removed families

    /// A stored raw value from a family this build dropped must not decode — and the device row that
    /// holds it is dropped at launch. What matters here is that the enums don't silently *reinterpret*
    /// that data as something else.
    func testLegacyFamilyRawValuesDoNotDecode() {
        for legacy in ["jring", "colmiR02", "colmiSmartHealth", "luckRing", "ycbt", "rwfit", "crp", "tk5"] {
            XCTAssertNil(RingDeviceType(rawValue: legacy), "\(legacy) must not decode as a live family")
        }
    }

    /// `MeasurementSource.legacyVendor` keeps the `"colmi"` raw value alive **only** so measurement rows
    /// written before the removal still read back. Renaming the raw value would make them undecodable.
    func testMeasurementRowsFromTheRemovedFamilyStillDecode() {
        XCTAssertEqual(MeasurementSource(rawValue: "colmi"), .legacyVendor)
        XCTAssertEqual(MeasurementSource.legacyVendor.rawValue, "colmi")
    }

    /// Capability raw values are persisted per device, so the case list must not lose entries just
    /// because this build stopped producing them.
    func testCapabilityRawValuesAreStable() {
        let legacyRawValues = ["heartRate", "spo2", "steps", "sleep", "battery", "remSleep", "stress", "hrv",
                               "temperature", "bloodPressure", "bloodSugar", "fatigue", "manualHeartRate",
                               "manualSpo2", "manualHrv", "manualBloodPressure", "combinedVitalsMeasurement",
                               "realtimeHeartRate", "realtimeSteps", "findDevice", "powerOff", "factoryReset",
                               "measurementInterval", "spo2History"]
        for raw in legacyRawValues {
            XCTAssertNotNil(WearableCapability(rawValue: raw), "lost persisted capability \(raw)")
        }
    }

    // MARK: - Connect-failure copy

    func testConnectFailureMessageIsGeneric() {
        let message = RingConnectFailure.message(family: .veepoo)
        XCTAssertTrue(message.contains("didn't respond"))
        // No app names to switch to any more — the old copy told users to pick a different vendor app.
        XCTAssertFalse(message.lowercased().contains("qrring"))
        XCTAssertFalse(message.lowercased().contains("smarthealth"))
    }
}
