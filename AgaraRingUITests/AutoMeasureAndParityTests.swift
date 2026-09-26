import XCTest

/// Consistency framework phases 4–6 on the real app against the emulator: auto-measure written to the ring
/// and read back (`b3 01` set → ack → `b3 02` read), the tidied Settings (Data & Export, About, Wearable ring
/// actions, glucose unit in Profile), and parity flags hiding iOS-only features until turned on.
final class AutoMeasureAndParityTests: AgaraUITestCase {

    private func openSettingsRow(_ title: String) {
        openTab("Settings")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        waitFor(row, "Settings row \(title) missing")
        scrollTo(row)
        row.tap()
    }

    private func settingsRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func state(_ type: Int) -> String { element("autoMeasure.state.\(type)").value as? String ?? "" }

    private func pickInterval(_ label: String, type: Int = 0) {
        let menu = app.buttons["autoMeasure.interval.\(type)"]
        waitFor(menu, timeout: 30, "interval picker for type \(type) missing (schedule not read?)")
        menu.tap()
        // The menu's items, not another row's picker whose value happens to read the same (SpO₂ is "1 h").
        let option = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'autoMeasure')", label)).firstMatch
        waitFor(option, timeout: 5, "interval option \(label) missing").tap()
    }

    // MARK: - Phase 4

    /// Heart rate every 60 min: the app writes the `b3 01` set, the emulator acks and the read-back shows the
    /// new value; a relaunch reads it again from the ring. Restores 30 min at the end.
    func testHeartRateSixtyMinutesIsWrittenAndReadBack() throws {
        try launch()
        waitForConnected()
        openSettingsRow("Auto-measure")
        let menu = app.buttons["autoMeasure.interval.0"]
        waitFor(menu, timeout: 30, "auto-measure screen shows no heart-rate row")
        eventually(timeout: 20, "HR not at the captured 30 min (\(menu.value as? String ?? "-"))") {
            (menu.value as? String) == "30 min"
        }
        XCTAssertTrue(text(containing: "shortest interval").exists, "30 min is the shortest → battery warning")
        XCTAssertTrue(element("autoMeasure.locked.6").exists, "the heart-rhythm scatter is read-only")
        attachScreenshot("auto-measure-before")

        pickInterval("1 h")
        eventually(timeout: 20, "the ring never confirmed (state \(state(0)))") {
            state(0) == "idle" && (menu.value as? String) == "1 h"
        }
        attachScreenshot("auto-measure-hr-60")

        // Relaunch: the value comes back from the ring's own table.
        app.terminate()
        try launch()
        waitForConnected()
        openSettingsRow("Auto-measure")
        let again = app.buttons["autoMeasure.interval.0"]
        waitFor(again, timeout: 30)
        eventually(timeout: 20, "after relaunch the ring's table should say 1 h (\(again.value as? String ?? "-"))") {
            (again.value as? String) == "1 h"
        }

        pickInterval("30 min")
        eventually(timeout: 20, "restore to 30 min not confirmed") { state(0) == "idle" && (again.value as? String) == "30 min" }
    }

    // MARK: - Phase 5

    func testDataExportAboutAndProfileGlucoseUnit() throws {
        try launch()
        waitForConnected()
        openSettingsRow("Data & Export")
        waitFor(app.staticTexts["Data & Export"], "Data & Export screen missing")
        XCTAssertTrue(anyElement(labelContains: "Export all data").waitForExistence(timeout: 5))
        XCTAssertTrue(anyElement(labelContains: "Include diagnostics").exists)
        XCTAssertTrue(anyElement(labelContains: "Export diagnostics").exists)
        XCTAssertFalse(anyElement(labelContains: "Reseed demo data").exists, "demo rows stay behind demo_data")
        attachScreenshot("data-export")
        app.buttons["Back"].firstMatch.tap()

        openSettingsRow("Privacy")
        waitFor(anyElement(labelContains: "Reset app data"), "Privacy lost its resets")
        XCTAssertFalse(anyElement(labelContains: "Export all data").exists, "export moved to Data & Export")
        app.buttons["Back"].firstMatch.tap()

        openSettingsRow("About")
        waitFor(element("about.hero"), "About hero missing")
        let version = element("about.version")
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(anyElement(labelContains: "1.0.0 (1)").exists, "version from the bundle")
        for id in ["about.social.website", "about.social.instagram", "about.social.telegram",
                   "about.contact.email", "about.contact.phone", "about.licences"] {
            XCTAssertTrue(element(id).exists, "\(id) missing")
        }
        attachScreenshot("about")
        app.buttons["Back"].firstMatch.tap()

        openSettingsRow("User Profile")
        let unit = element("profile.glucoseUnit")
        scrollTo(unit)
        waitFor(unit, "glucose unit not in Profile")
        attachScreenshot("profile-glucose-unit")
    }

    func testWearableRingActionsGroup() throws {
        try launch()
        waitForConnected()
        app.buttons["ringChip"].tap()
        waitFor(app.staticTexts["Wearable"], "Wearable screen missing")
        waitFor(text(containing: "RING ACTIONS"), "no Ring actions group")
        for label in ["Find ring", "Disconnect", "Forget ring"] {
            XCTAssertTrue(app.buttons[label].exists, "\(label) missing from Ring actions")
        }
        attachScreenshot("wearable-ring-actions")
        let alerts = element("wearable.batteryAlerts")
        scrollTo(alerts)
        XCTAssertTrue(alerts.exists, "low-battery alert should live on Wearable")
        XCTAssertFalse(text(containing: "Live heart rate").exists, "live HR toggle is behind live_hr_toggle")
        attachScreenshot("wearable-actions")
    }

    // MARK: - Phase 6

    func testParityFlagsHideIOSOnlyFeaturesByDefault() throws {
        try launch(features: Self.allFeatures + ",parity=off")
        waitForConnected()
        openTab("Settings")
        waitFor(settingsRow("User Profile"))
        for title in ["AI Coach", "Physiology", "Heart Rate Zones", "Activity Tracking", "Nutrition", "Strava", "Agara Cloud"] {
            XCTAssertFalse(settingsRow(title).exists, "\(title) must be hidden with its flag off")
        }
        XCTAssertFalse(app.buttons["Open coach"].exists || element("coachFAB").exists, "coach FAB hidden")
        attachScreenshot("settings-parity-off")

        app.terminate()
        try launch(features: Self.allFeatures + ",parity=on")
        waitForConnected()
        openTab("Settings")
        waitFor(settingsRow("User Profile"))
        for title in ["AI Coach", "Physiology", "Heart Rate Zones", "Activity Tracking", "Nutrition"] {
            let row = settingsRow(title)
            scrollTo(row)
            XCTAssertTrue(row.exists, "\(title) must show with parity=on")
        }
        attachScreenshot("settings-parity-on")
        // Leave the persisted overrides as the other tests expect.
        app.terminate()
        try launch(features: Self.allFeatures + ",parity=off")
    }
}
