import XCTest
@testable import PulseLoop

/// The permission prompts, display names and widget names users see are read from the *built* Info.plists.
/// The upstream name "PulseLoop" leaked into several of them once (`INFOPLIST_KEY_*` in project.pbxproj), so
/// this reads the real products: the app (the unit-test host) and every embedded extension.
final class InfoPlistBrandingTests: XCTestCase {
    private static let userVisibleKeys: Set<String> = ["CFBundleDisplayName", "CFBundleName", "NSUserActivityTypes"]

    private func userVisibleStrings(in plist: [String: Any]) -> [(String, String)] {
        var found: [(String, String)] = []
        for (key, value) in plist {
            guard key.hasSuffix("UsageDescription") || Self.userVisibleKeys.contains(key) else { continue }
            if key == "CFBundleName" { continue }   // the executable/product name, never shown when a display name exists
            if let s = value as? String { found.append((key, s)) }
            if let a = value as? [String] { found += a.map { (key, $0) } }
        }
        return found
    }

    private func plists() throws -> [(String, [String: Any])] {
        var result: [(String, [String: Any])] = []
        let app = Bundle.main
        result.append((app.bundleURL.lastPathComponent, app.infoDictionary ?? [:]))
        let plugins = try XCTUnwrap(app.builtInPlugInsURL)
        let appexes = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        for appex in appexes where appex.pathExtension == "appex" {
            if let info = Bundle(url: appex)?.infoDictionary { result.append((appex.lastPathComponent, info)) }
        }
        return result
    }

    func testNoUserVisibleStringSaysTheUpstreamName() throws {
        let all = try plists()
        XCTAssertGreaterThanOrEqual(all.count, 3, "expected the app and both extensions")
        for (bundle, plist) in all {
            for (key, value) in userVisibleStrings(in: plist) {
                XCTAssertFalse(value.localizedCaseInsensitiveContains("PulseLoop"), "\(bundle) \(key): \(value)")
                XCTAssertFalse(value.contains("SMART_RING"), "\(bundle) \(key): unfilled placeholder in \(value)")
            }
        }
    }

    func testDisplayNamesAndKeyPromptsSayAgaraRing() throws {
        for (bundle, plist) in try plists() {
            XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Agara Ring", "\(bundle) display name")
        }
        let app = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(app["NSBluetoothAlwaysUsageDescription"] as? String,
                       "Agara Ring connects to your ring over Bluetooth to sync steps, sleep and vitals.")
        XCTAssertEqual(app["NSLocalNetworkUsageDescription"] as? String,
                       "Agara Ring connects to the AI model server you run on your own network, so coaching can happen without sending your health data to a cloud provider.")
    }
}
