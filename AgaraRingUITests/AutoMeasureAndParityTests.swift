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
        // Polish spec item 3: the intro explains the battery trade-off once; no row repeats it.
        XCTAssertTrue(text(containing: "Shorter intervals use more ring battery").exists, "intro paragraph missing")
        XCTAssertFalse(text(containing: "shortest interval").exists, "no per-row battery warning")
        XCTAssertTrue(element("autoMeasure.locked.6").exists, "the heart-rhythm scatter is read-only")
        attachScreenshot("polish-auto-measure")

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

        // The shortest option names its cost in the picker.
        pickInterval("30 min · most battery")
        eventually(timeout: 20, "restore to 30 min not confirmed") { state(0) == "idle" && (again.value as? String) == "30 min" }
    }

    /// Rebrand-measure spec item 1: "Live heart rate" sits at the top of Auto-measure, off by default, with its
    /// one-line explanation.
    func testLiveHeartRateToggleTopsAutoMeasureAndDefaultsOff() throws {
        // The parity test persists `live_hr_toggle=off` as an override; pin the shipped `on` explicitly.
        try launch(features: Self.allFeatures + ",live_hr_toggle=on")
        waitForConnected()
        openSettingsRow("Auto-measure")
        let toggle = element("autoMeasure.liveHeartRate")
        waitFor(toggle, timeout: 20, "Live heart rate toggle missing (flag live_hr_toggle)")
        XCTAssertTrue(text(containing: "Streams your pulse continuously while connected").exists, "explanation missing")
        let hr = app.buttons["autoMeasure.interval.0"]
        if hr.waitForExistence(timeout: 30) {
            XCTAssertLessThan(toggle.frame.minY, hr.frame.minY, "the toggle tops the screen")
        }
        let value = (app.switches["autoMeasure.liveHeartRate"].value as? String) ?? (toggle.value as? String) ?? ""
        XCTAssertTrue(value == "0" || value.lowercased() == "off", "live HR should default off (value \(value))")
        attachScreenshot("auto-measure-live-hr")
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
        // The debug row is a button; its text can surface as the label or the value depending on the runtime.
        let versionText = version.label + " " + ((version.value as? String) ?? "")
        XCTAssertTrue(versionText.contains("1.0.0 (2)") || anyElement(labelContains: "1.0.0 (2)").exists,
                      "version from the bundle (\(versionText))")
        for id in ["about.social.website", "about.social.instagram", "about.social.telegram",
                   "about.contact.email", "about.contact.phone", "about.licences"] {
            XCTAssertTrue(element(id).exists, "\(id) missing")
        }
        XCTAssertTrue(element("about.wordmark").exists || element("about.hero").exists)
        for caption in ["Website", "Instagram", "Telegram"] where element("about.social.\(caption.lowercased())").exists {
            XCTAssertEqual(element("about.social.\(caption.lowercased())").label, caption, "social link needs its caption/label")
        }
        attachScreenshot("polish-about")
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
        // Polish spec item 4: ring card (with Sync now) → Ring actions → Ring details.
        let card = element("wearable.ringCard")
        waitFor(card, "ring card missing")
        let sync = app.buttons["wearable.syncNow"]
        let find = app.buttons["Find ring"]
        let details = text(containing: "RING DETAILS")
        XCTAssertTrue(sync.exists && details.exists, "Sync now / Ring details missing")
        XCTAssertLessThan(card.frame.minY, sync.frame.minY, "Sync now sits under the ring card header")
        XCTAssertLessThan(sync.frame.minY, find.frame.minY, "ring card comes before Ring actions")
        XCTAssertLessThan(find.frame.minY, details.frame.minY, "Ring actions come before Ring details")
        attachScreenshot("polish-wearable")
        attachScreenshot("wearable-ring-actions")
        let alerts = element("wearable.batteryAlerts")
        scrollTo(alerts)
        XCTAssertTrue(alerts.exists, "low-battery alert should live on Wearable")
        let history = text(containing: "BATTERY HISTORY")
        scrollTo(history)
        XCTAssertLessThan(alerts.frame.minY, history.frame.minY, "Low-battery alert comes before Battery history")
        XCTAssertFalse(text(containing: "Live heart rate").exists, "the live HR toggle moved to Auto-measure")
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
