import XCTest
import SwiftData
@testable import PulseLoop

/// What `RingBLEClient` remembers about a ring *between* connections — its family, its exact catalog
/// model, and the capabilities it claimed — plus the name that reaches the store.
///
/// All of it has to be re-adopted before a new session publishes its first `.deviceIdentified`, because
/// that event overwrites the persisted `Device` row wholesale: anything the client can't name at that
/// moment is not merely missing from the UI, it is erased from the store.
@MainActor
final class RingIdentityMemoryTests: XCTestCase {
    private let deviceTypeKey = "ring.lastDeviceType"
    private let modelKey = "ring.lastWearableModel"
    private let capabilitiesKey = "ring.lastCapabilities"

    private var agara: Set<WearableCapability> { VeepooCoordinator().capabilities }

    /// Seed (and, on teardown, clear) the client's cross-connection memory. Starts from a clean slate so
    /// a test never inherits another's — or a previous run's — remembered ring.
    private func remember(deviceType: String? = nil, model: String? = nil, capabilities: Set<WearableCapability>? = nil) {
        let defaults = UserDefaults.standard
        let keys = [deviceTypeKey, modelKey, capabilitiesKey]
        keys.forEach { defaults.removeObject(forKey: $0) }
        addTeardownBlock {
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        if let deviceType { defaults.set(deviceType, forKey: deviceTypeKey) }
        if let model { defaults.set(model, forKey: modelKey) }
        if let capabilities { defaults.set(capabilities.csv, forKey: capabilitiesKey) }
    }

    // MARK: - Capability memory

    func testRestoredSessionReadoptsFamilyModelAndClaimedCapabilities() {
        remember(deviceType: "veepoo", model: "tk20", capabilities: agara)
        let client = RingBLEClient()
        client.adoptRememberedIdentity()   // the state-restoration path: family *and* model

        XCTAssertEqual(client.activeDeviceType, .veepoo)
        XCTAssertEqual(client.activeWearableModelID, "tk20")
        XCTAssertEqual(client.activeCapabilities, agara)
    }

    /// A first connect that never sees a capability report still starts from the coordinator's baseline —
    /// `Device()`'s empty default would render no metric cards at all.
    func testAFirstConnectStartsFromTheFamilyBaseline() {
        remember()
        let client = RingBLEClient()
        client.installDriver(VeepooCoordinator.self)

        XCTAssertEqual(client.activeCapabilities, agara)
    }

    /// The Agara coordinator gates nothing, so a remembered set (from any earlier connect) must never
    /// widen or narrow its baseline: `refinedCapabilities` intersects with an empty gate set.
    func testRememberedCapabilitiesCannotLeakIntoAFamilyThatGatesNothing() {
        remember(capabilities: agara.union([.temperature, .fatigue, .remSleep]))
        let client = RingBLEClient()
        client.installDriver(VeepooCoordinator.self)

        XCTAssertEqual(client.activeCapabilities, agara)
        XCTAssertFalse(client.activeCapabilities.contains(.temperature))
        XCTAssertFalse(client.activeCapabilities.contains(.fatigue))
    }

    // MARK: - The name that reaches the store

    private func identified(_ advertisedName: String?) -> PulseEvent {
        .deviceIdentified(
            deviceType: .veepoo,
            wearableModelID: "tk20",
            advertisedName: advertisedName,
            capabilities: []
        )
    }

    /// `Device.name` is what the human-facing surfaces read — the coach's device context, and the
    /// diagnostics export's `wearableName` — and nothing used to write it, so an export named a ring the
    /// user had never paired.
    func testTheAdvertisedNameBecomesTheDeviceName() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        subscriber.persist(identified("TK20 3B00"))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "TK20 3B00")
        XCTAssertEqual(device.advertisedName, "TK20 3B00")
    }

    /// A name a *user* chose survives. `.deviceIdentified` is re-published on every handshake, so
    /// anything that overwrote `name` unconditionally would undo a rename seconds later. Only a
    /// placeholder is ever replaced.
    func testAUserChosenNameIsNotClobberedByAReconnect() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        device.name = "Left hand"

        subscriber.persist(identified("TK20 3B00"))   // the reconnect's re-published identity

        XCTAssertEqual(device.name, "Left hand")
        XCTAssertEqual(device.advertisedName, "TK20 3B00", "the advertised name is still recorded")
    }

    /// A connect with no advertised name to offer (state restoration, a cached peripheral) leaves the
    /// name alone rather than blanking it.
    func testAConnectWithNoAdvertisedNameLeavesTheNameAlone() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))

        subscriber.persist(identified(nil))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "TK20 3B00")
    }

    /// **A ring swap must not leave the previous ring's name behind.** There is one `Device` row and it is
    /// *reused* across pairings, so an adopted name outlives the ring it came from unless Forget clears it
    /// — and an adopted name is neither empty nor a placeholder, so the "don't clobber a name the user
    /// chose" guard would then defend it against the new ring's own advertisement forever.
    func testForgettingARingReleasesItsNameForTheNextOne() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))

        subscriber.persist(.deviceForgotten)

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, "")

        subscriber.persist(identified("AGARA 1111"))
        XCTAssertEqual(device.name, "AGARA 1111", "the next ring's own name must be adopted")
    }

    /// A forgotten ring leaves nothing naming it: the row keeps no advertised name and its model id is
    /// cleared, so nothing can resolve a model for a ring that is gone.
    func testForgettingARingLeavesNothingNamingIt() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))

        subscriber.persist(.deviceForgotten)

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertNil(device.advertisedName)
        XCTAssertNil(device.wearableModelID)
    }

    /// A ring that advertises no name falls back to the *catalog's* name for the family, not to the
    /// now-empty `Device()` default and not to the jring-era `SMART_RING` placeholder.
    func testARingThatAdvertisesNoNameFallsBackToItsOwnFamily() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)

        subscriber.persist(identified(nil))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(device.name, AgaraCopy.ringDisplayName)
    }
}
