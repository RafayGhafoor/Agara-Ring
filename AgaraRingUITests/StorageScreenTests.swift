import XCTest

/// Settings › Data & Export › Storage (store launch phase 3). Runs on the sample data set, so it needs no emulator:
/// opens the screen through the real navigation, checks its parts, confirms the destructive action goes through the one
/// confirmation, runs "Optimize now", and writes a screenshot to `STORAGE_SHOT_DIR` (default: the test's attachments only).
final class StorageScreenTests: AgaraUITestCase {
    private var shotDir: String? { ProcessInfo.processInfo.environment["STORAGE_SHOT_DIR"] }

    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let image = XCUIScreen.main.screenshot()
        if let shotDir {
            try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(shotDir)/\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openStorage() {
        app.launchArguments = ["-noCoachMarks", "YES", "-acceptDisclaimer", "YES", "-sampleData", "YES",
                               "-features", "", "-AppleLanguages", "(en)"]
        app.launch()
        waitFor(app.buttons["Vitals"].exists ? app.buttons["Vitals"] : app.tabBars.buttons["Vitals"], timeout: 40)
        openTab("Settings")
        let dataExport = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Data & Export")).firstMatch
        waitFor(dataExport, "Data & Export row missing")
        scrollTo(dataExport)
        dataExport.tap()
        let row = element("openStorage")
        waitFor(row, "Storage row missing on Data & Export (flag storage_settings)")
        row.tap()
        waitFor(element("storageTotal"), timeout: 30, "usage total missing")
    }

    func testStorageScreenShowsUsageAndTheClearAndOptimizeActions() {
        openStorage()
        // Usage: a total and a row per class with a size.
        let total = element("storageTotal").label
        XCTAssertTrue(total.contains(" of "), "usage reads \"x of y\": \(total)")
        XCTAssertTrue(anyElement(labelContains: "Health readings (detailed)").exists)
        XCTAssertTrue(anyElement(labelContains: "Workouts & routes").exists)
        XCTAssertTrue(anyElement(labelContains: "Diagnostics (raw data and logs)").exists)
        shot("storage-top")

        // The limit and retention choices come from the catalog.
        XCTAssertTrue(anyElement(labelContains: "Storage limit").exists)
        XCTAssertTrue(anyElement(labelContains: "250 MB").exists, "default limit")
        XCTAssertTrue(anyElement(labelContains: "Keep detailed readings").exists)

        // Always kept + Diagnostics further down.
        let clear = element("clearRawData")
        scrollTo(clear)
        XCTAssertTrue(anyElement(labelContains: "Always kept").exists || anyElement(labelContains: "ALWAYS KEPT").exists)
        shot("storage-diagnostics")

        // Clear raw data goes through the one confirmation, with the catalog copy.
        clear.tap()
        let alert = app.alerts.firstMatch
        waitFor(alert, timeout: 10, "confirmation missing")
        XCTAssertTrue(alert.staticTexts["Clear raw data?"].exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sleep' OR label CONTAINS 'repair'")).firstMatch.exists,
                      "the body must say the raw trace feeds the sleep repair")
        alert.buttons["Cancel"].tap()

        // Optimize now: runs and finishes.
        let optimize = element("optimizeNow")
        scrollTo(optimize)
        // Optimize now is off on a low disk (the banner says so) — the rule under test either way.
        let lowDisk = element("storageBanner").exists
        XCTAssertEqual(optimize.isEnabled, !lowDisk, "Optimize now is disabled exactly when the low-space banner is up")
        guard optimize.isEnabled else { shot("storage-optimize-disabled"); return }
        optimize.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        waitFor(element("storageTotal"), timeout: 30)
        shot("storage-after-optimize")
    }
}
