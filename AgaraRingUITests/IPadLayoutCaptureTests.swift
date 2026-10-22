import XCTest

/// iPad layout pass (store launch phase 1d): walks every tab, the Measure hub, key Settings pages, pairing, onboarding and
/// the disclaimer in portrait and landscape and writes PNGs to `captures/ipad-layout/<device>-<orientation>-<screen>.png`
/// (git-ignored). Runs on the sample data set ("Explore without ring"), so it needs no emulator. Skips on iPhone.
/// Windowed / split-view widths can't be driven from XCUITest; those are reported as unverified.
///
/// **iPad is not shipped in the first version** (owner, 2026-09-29): the app targets iPhone only, so on an iPad
/// simulator the app runs in compatibility mode (idiom `.phone`) and this test skips itself. It is not part of any
/// default run (the unit suite is `PulseLoopTests`; this lives in the UI scheme). To capture the iPad layout again,
/// set `TARGETED_DEVICE_FAMILY = "1,2"` (and the iPad orientation keys) for the app target locally, then run
/// `scripts/ipad_layout_capture.sh "iPad Pro 13-inch (M5)"`.
final class IPadLayoutCaptureTests: XCTestCase {
    private var app: XCUIApplication!
    private let outDir = ProcessInfo.processInfo.environment["IPAD_SHOT_DIR"]
        ?? "/Users/emumba/Downloads/projects/hring-vpg-api/captures/ipad-layout"

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    private var deviceTag: String {
        let size = XCUIScreen.main.screenshot().image.size
        return "\(Int(min(size.width, size.height)))"
    }

    private func shot(_ name: String, _ orientation: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        // XCUIScreen returns the portrait framebuffer, so a landscape capture comes back rotated 90 degrees:
        // `scripts/`-side post-processing (`sips -r 270`) uprights every `*-landscape-*.png`.
        let image = XCUIScreen.main.screenshot()
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(deviceTag)-\(orientation)-\(name).png"))
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "\(orientation)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ extra: [String]) {
        app.launchArguments = ["-noCoachMarks", "YES", "-AppleLanguages", "(en)"] + extra
        app.launch()
    }

    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 20) { tab.tap(); return }
        let button = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        if button.waitForExistence(timeout: 10) { button.tap() }
    }

    private func back() {
        for label in ["Back", "Close", "Done"] {
            let b = app.buttons[label].firstMatch
            if b.exists && b.isHittable { b.tap(); return }
        }
        app.swipeRight()
    }

    func testSampleDataScreensInBothOrientations() {
        launch(["-sampleData", "YES", "-acceptDisclaimer", "YES"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40) || app.buttons["Today"].waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        for (label, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            for tab in ["Today", "Vitals", "Activity", "Sleep", "Settings"] {
                openTab(tab)
                shot("tab-\(tab.lowercased())", label)
            }
            // Pairing, opened from the sample-data banner.
            let banner = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sample data'")).firstMatch
            if banner.waitForExistence(timeout: 5) {
                banner.tap()
                shot("pairing", label)
                back()
            }
            // Measure hub (sheet) from Vitals; the tile says "Connect your ring" with no ring.
            openTab("Vitals")
            let measure = app.buttons["vitals.measure"]
            if measure.waitForExistence(timeout: 5) {
                measure.tap()
                shot("measure-hub", label)
                let tile = app.buttons["measure.tile.heartRate"]
                if tile.waitForExistence(timeout: 3) {
                    tile.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(9))
                    shot("measure-sheet-no-ring", label)
                    for name in ["Close", "Cancel", "Done"] where app.buttons[name].firstMatch.exists { app.buttons[name].firstMatch.tap() }
                }
                for name in ["Close", "Cancel", "Done"] where app.buttons[name].firstMatch.exists { app.buttons[name].firstMatch.tap() }
            }
            // Settings pages.
            openTab("Settings")
            for row in ["User Profile", "Privacy", "About AGARA Heart", "Apple Health", "Data & Export", "Appearance"] {
                let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", row)).firstMatch
                guard cell.waitForExistence(timeout: 3) else { continue }
                cell.tap()
                shot("settings-\(row.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "&", with: "and"))", label)
                back()
            }
        }
    }

    func testOnboardingAndDisclaimerInBothOrientations() {
        // Disclaimer: the argument domain overrides the persisted acceptance.
        launch(["-agara.wellnessDisclaimerAccepted", "NO"])
        XCTAssertTrue(app.buttons["disclaimer.accept"].waitForExistence(timeout: 30))
        for (label, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            shot("disclaimer", label)
        }
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        launch(["-acceptDisclaimer", "YES", "-forceOnboarding", "YES", "-onboarding.route.v2", "(welcome)"])
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        for (label, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            shot("onboarding-welcome", label)
        }
        XCUIDevice.shared.orientation = .portrait
        let explore = app.buttons["Explore without ring"]
        if explore.waitForExistence(timeout: 5) {
            explore.tap()
            for (label, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
                XCUIDevice.shared.orientation = orientation
                shot("onboarding-profile", label)
            }
        }
    }
}
