import XCTest
import HealthKit
@testable import PulseLoop

/// Store-launch permission audit (owner, 2026-09-29): the app must not declare or ask for anything it doesn't
/// use, and must only ask at the moment it is needed. These fail when a usage string, background mode or
/// request site appears without a reachable feature behind it.
@MainActor
final class PermissionDeclarationsTests: XCTestCase {

    // MARK: - Declared usage strings

    /// Every purpose string the app may declare, and the release-reachable feature that needs it.
    /// Adding a key here is the review step: name the feature and how it is gated.
    private static let releaseUsageKeys: [String: String] = [
        "NSBluetoothAlwaysUsageDescription": "ring link (pairing / reconnect)",
        "NSHealthShareUsageDescription": "Profile > Import from Apple Health (age, sex, height, weight)",
        "NSHealthUpdateUsageDescription": "Settings > Apple Health export (opt-in)",
        "NSLocationWhenInUseUsageDescription": "GPS workouts (route recording)",
    ]
    /// Debug-only extras: features that are flag-off in the store release but reachable with a debug override.
    private static let debugOnlyUsageKeys: [String: String] = [
        "NSPhotoLibraryAddUsageDescription": "share_card flag: Save Image from the share sheet",
        "NSLocalNetworkUsageDescription": "coach flag: local AI model server",
    ]

    private var projectFile: URL {
        // …/PulseLoopiOS/PulseLoopTests/<this file> → …/PulseLoopiOS/PulseLoop.xcodeproj/project.pbxproj
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PulseLoop.xcodeproj/project.pbxproj")
    }

    /// `INFOPLIST_KEY_*UsageDescription` names of the app target's Debug and Release configurations.
    private func appTargetUsageKeys() throws -> [String: Set<String>] {
        let text = try String(contentsOf: projectFile, encoding: .utf8)
        var result: [String: Set<String>] = [:]
        for block in text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
            guard block.contains("INFOPLIST_FILE = PulseLoop/Info.plist;"),
                  let nameRange = block.range(of: #"name = (Debug|Release);"#, options: .regularExpression) else { continue }
            let name = block[nameRange].dropFirst("name = ".count).dropLast()
            let keys = block.components(separatedBy: .newlines).compactMap { line -> String? in
                guard let r = line.range(of: #"INFOPLIST_KEY_(NS\w*UsageDescription)"#, options: .regularExpression) else { return nil }
                return String(line[r].dropFirst("INFOPLIST_KEY_".count))
            }
            result[String(name)] = Set(keys)
        }
        return result
    }

    // MARK: - Device family (owner, 2026-09-29: iPhone only for the first version)

    /// The app and both extensions build for iPhone only (`TARGETED_DEVICE_FAMILY = 1`), in every configuration, and
    /// the app is portrait-only on iPhone with no iPad orientation keys. The iPad layout code stays (reusable);
    /// only the shipping target changes. To run the iPad layout capture again, set the family to "1,2" locally.
    func testAppAndExtensionsAreIPhoneOnlyInEveryConfiguration() throws {
        let text = try String(contentsOf: projectFile, encoding: .utf8)
        var checked = Set<String>()
        for block in text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
            guard let idRange = block.range(of: #"PRODUCT_BUNDLE_IDENTIFIER = com\.agara\.ring(\.RingLiveActivity|\.RingWidgets)?;"#, options: .regularExpression),
                  let nameRange = block.range(of: #"name = (Debug|Release);"#, options: .regularExpression) else { continue }
            let target = String(block[idRange]), config = String(block[nameRange])
            XCTAssertTrue(block.contains("TARGETED_DEVICE_FAMILY = 1;"), "\(target) \(config) must target iPhone only")
            XCTAssertFalse(block.contains("TARGETED_DEVICE_FAMILY = \"1,2\""), "\(target) \(config) still targets iPad")
            XCTAssertTrue(block.contains("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;"), "\(target) \(config)")
            XCTAssertFalse(block.contains("UISupportedInterfaceOrientations_iPad"), "\(target) \(config): no iPad orientation keys")
            if block.contains("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone") {
                XCTAssertTrue(block.contains(#"INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait";"#),
                              "\(target) \(config): iPhone is portrait-only")
            }
            checked.insert("\(target) \(config)")
        }
        XCTAssertEqual(checked.count, 6, "app + LiveActivity + Widgets, Debug and Release: \(checked)")
    }

    /// The built product (the unit-test host is the app) declares iPhone and portrait only.
    func testBuiltInfoPlistDeclaresIPhoneOnlyPortrait() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["UIDeviceFamily"] as? [Int], [1], "UIDeviceFamily must be [1]")
        XCTAssertEqual(info["UISupportedInterfaceOrientations"] as? [String], ["UIInterfaceOrientationPortrait"])
        XCTAssertNil(info["UISupportedInterfaceOrientations~ipad"], "no iPad-only orientation key")
    }

    func testReleaseDeclaresOnlyStringsWithAReachableFeature() throws {
        let keys = try appTargetUsageKeys()
        let release = try XCTUnwrap(keys["Release"], "app target Release configuration not found")
        XCTAssertEqual(release, Set(Self.releaseUsageKeys.keys),
                       "Release purpose strings must be exactly the allow-list — add a feature justification to change it")
    }

    func testDebugAddsOnlyFlagGatedStrings() throws {
        let keys = try appTargetUsageKeys()
        let debug = try XCTUnwrap(keys["Debug"], "app target Debug configuration not found")
        let allowed = Set(Self.releaseUsageKeys.keys).union(Self.debugOnlyUsageKeys.keys)
        XCTAssertTrue(debug.isSubset(of: allowed), "unexpected Debug strings: \(debug.subtracting(allowed).sorted())")
        XCTAssertTrue(Set(Self.releaseUsageKeys.keys).isSubset(of: debug))
    }

    func testDeprecatedAndUnusedStringsAreGoneEverywhere() throws {
        let text = try String(contentsOf: projectFile, encoding: .utf8)
        XCTAssertFalse(text.contains("NSBluetoothPeripheralUsageDescription"), "deprecated; the app is central-only")
        #if !AGARA_CAMERA
        XCTAssertFalse(text.contains("NSCameraUsageDescription"), "the store build has no camera use")
        XCTAssertFalse(CameraSupport.isAvailable)
        XCTAssertFalse(CameraSupport.barcodeScanningAvailable)
        XCTAssertEqual(CameraPicker.route(cameraAvailable: CameraSupport.isAvailable), .library)
        #endif
    }

    func testHostBundleMergedInfoPlistMatchesTheAllowList() {
        let info = Bundle.main.infoDictionary ?? [:]
        let declared = Set(info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") })
        let allowed = Set(Self.releaseUsageKeys.keys).union(Self.debugOnlyUsageKeys.keys)
        XCTAssertTrue(declared.isSubset(of: allowed), "undeclared-in-audit strings: \(declared.subtracting(allowed).sorted())")
        XCTAssertNil(info["NSBluetoothPeripheralUsageDescription"])
        #if !AGARA_CAMERA
        XCTAssertNil(info["NSCameraUsageDescription"])
        #endif
    }

    /// `fetch` is deliberate (release 1.1): Agara Cloud's background sync of the user's data to their Agara account runs as a
    /// `BGAppRefreshTask` (`com.agara.ring.cloudsync`). Nothing else may be added without a matching feature and review note.
    func testBackgroundModesAreExactlyLocationBluetoothCentralAndFetch() {
        let modes = (Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String]) ?? []
        XCTAssertEqual(Set(modes), ["location", "bluetooth-central", "fetch"])
        let ids = Set((Bundle.main.infoDictionary?["BGTaskSchedulerPermittedIdentifiers"] as? [String]) ?? [])
        XCTAssertTrue(ids.contains("com.agara.ring.cloudsync"))
        XCTAssertEqual(AgaraCloud.backgroundTaskIdentifier, "com.agara.ring.cloudsync")
    }

    // MARK: - Request sites

    /// Sources under PulseLoop/ that contain `needle`, as paths relative to it.
    private func sourcesContaining(_ needle: String) throws -> Set<String> {
        let root = projectFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PulseLoop")
        let fm = FileManager.default
        var hits: Set<String> = []
        let files = try XCTUnwrap(fm.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
                hits.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return hits
    }

    func testEachSystemPromptHasOnlyItsKnownRequestSites() throws {
        // A new request site must be added here on purpose, with the moment it fires.
        XCTAssertEqual(try sourcesContaining("CBCentralManager("), ["RingProtocol/RingBLEClient.swift"],
                       "the Bluetooth prompt: only via RingBLEClient.startManagerIfNeeded")
        XCTAssertEqual(try sourcesContaining("requestWhenInUseAuthorization("),
                       ["Services/GpsRouteRecorder.swift", "Coach/Context/CoachEnvironmentContextService.swift"],
                       "location: GPS workout start; coach weather toggle (coach flag off in release)")
        XCTAssertEqual(try sourcesContaining("requestAlwaysAuthorization("), [], "Always location is never requested")
        XCTAssertEqual(try sourcesContaining("store.requestAuthorization("), ["Health/HealthSyncService.swift"])
        XCTAssertEqual(try sourcesContaining("HealthSyncService.shared.requestAuthorization"), [],
                       "no caller outside the Health settings screen's toggle")
        XCTAssertEqual(try sourcesContaining("service.requestAuthorization()"), ["Views/Settings/AppleHealthSettingsView.swift"])
        XCTAssertEqual(try sourcesContaining("requestProfileReadAuthorization()"),
                       ["Health/HealthSyncService.swift", "Views/Settings/ProfileSettingsView.swift"])
        XCTAssertEqual(try sourcesContaining(".requestAuthorization(options:"),
                       ["Services/AgaraNotifications.swift", "Views/Settings/WearableSettingsView.swift",
                        "Views/Settings/NotificationsSettingsView.swift", "Coach/Config/CoachSettingsSection.swift"],
                       "notifications: opt-in row / measurement start / Settings toggles only")
        XCTAssertEqual(try sourcesContaining("requestAuthorizationIfUndetermined()"),
                       ["Services/AgaraNotifications.swift", "Services/MeasurementService.swift",
                        "Views/OnboardingSyncingView.swift"],
                       "the background battery alert must not prompt")
    }

    func testNothingRequestsPermissionAtLaunch() throws {
        // AgaraApp.init runs at every cold start: it may construct the clients but must not itself ask.
        let root = projectFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PulseLoop")
        let app = try String(contentsOf: root.appendingPathComponent("AgaraApp.swift"), encoding: .utf8)
        for forbidden in ["requestAuthorization", "requestWhenInUse", "requestAlways", "CBCentralManager("] {
            XCTAssertFalse(app.contains(forbidden), "AgaraApp must not call \(forbidden)")
        }
    }

    // MARK: - Bluetooth: no manager (no prompt) until pairing or an existing ring

    func testManagerStartsAtLaunchOnlyForAnAlreadyPairedRing() {
        XCTAssertFalse(RingBLEClient.shouldStartManagerAtLaunch(allowed: true, hasPairedRing: false), "fresh install: wait for pairing")
        XCTAssertTrue(RingBLEClient.shouldStartManagerAtLaunch(allowed: true, hasPairedRing: true), "paired: must reconnect / restore")
        XCTAssertFalse(RingBLEClient.shouldStartManagerAtLaunch(allowed: false, hasPairedRing: true), "tests / virtual ring")
        XCTAssertFalse(RingBLEClient.shouldStartManagerAtLaunch(allowed: false, hasPairedRing: false))
    }

    func testDisallowedClientNeverCreatesTheManagerEvenWhenAskedToScan() {
        let client = RingBLEClient(startManager: false)
        XCTAssertFalse(client.isBluetoothStarted)
        client.startScanning()
        client.connectLastKnown()
        client.startProximityScan()
        XCTAssertFalse(client.isBluetoothStarted)
        XCTAssertFalse(client.isBluetoothReady)
    }

    // MARK: - HealthKit

    func testHealthAuthorizationReadsOnlyWhatTheImportButtonReads() {
        let service = HealthSyncService.shared
        XCTAssertTrue(service.readTypes.isEmpty, "the export authorization asks to write, never to read")
        let profile = Set(service.profileReadTypes.map(\.identifier))
        XCTAssertEqual(profile, [
            HKCharacteristicTypeIdentifier.dateOfBirth.rawValue,
            HKCharacteristicTypeIdentifier.biologicalSex.rawValue,
            HKQuantityTypeIdentifier.height.rawValue,
            HKQuantityTypeIdentifier.bodyMass.rawValue,
        ])
    }
}
