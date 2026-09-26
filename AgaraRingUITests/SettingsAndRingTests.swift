import XCTest

/// Settings screens and the ring screen: profile, appearance, goals, wearable, rename, find ring,
/// disconnect/reconnect, hints.
final class SettingsAndRingTests: AgaraUITestCase {

    private func openSettingsRow(_ title: String) {
        openTab("Settings")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        waitFor(row, "Settings row \(title) missing")
        scrollTo(row)
        row.tap()
    }

    private func back() {
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    private func openWearable() {
        let chip = app.buttons["ringChip"]
        waitFor(chip).tap()
        waitFor(app.staticTexts["Wearable"], "Wearable screen missing")
    }

    // MARK: - Profile

    func testProfileEditNameShowsInHeader() throws {
        try launch()
        waitForConnected()
        openSettingsRow("User Profile")
        waitFor(app.staticTexts["Profile"], "Profile screen missing")
        let name = app.textFields.firstMatch
        waitFor(name).tap()
        if let current = name.value as? String, !current.isEmpty, current != "Optional" {
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        name.typeText("Tester E2E\n")
        back()
        openTab("Today")
        eventually(timeout: 10, "profile name not shown in the header") { text(containing: "Tester").exists }
        // Put the emulator's name back for the other tests.
        openSettingsRow("User Profile")
        let again = app.textFields.firstMatch
        waitFor(again).tap()
        if let current = again.value as? String {
            again.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        again.typeText("Emulator\n")
        back()
    }

    // MARK: - Appearance

    func testAppearanceModesAndEveryFlavour() throws {
        try launch()
        openSettingsRow("Appearance")
        waitFor(app.staticTexts["COLOURS"], timeout: 30, "Appearance screen missing")
        for mode in ["Light", "Dark", "System"] {
            let segment = app.segmentedControls.buttons[mode]
            waitFor(segment, "mode \(mode) missing")
            // A segment tap that lands while the previous theme change is still re-rendering is dropped
            // (seen for Light and Dark alternately), so tap again until it takes — at most three times.
            for _ in 0..<3 where !app.segmentedControls.buttons[mode].isSelected {
                segment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            }
            eventually(timeout: 5, "mode \(mode) not selected") { app.segmentedControls.buttons[mode].isSelected }
            attachScreenshot("appearance-\(mode)")
        }
        for flavour in ["Ember", "Midnight", "Forest", "Rose"] {
            let card = app.buttons["\(flavour) colours"]
            scrollTo(card)
            waitFor(card, "flavour \(flavour) missing")
            for _ in 0..<3 where !card.isSelected {
                card.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            }
            eventually(timeout: 5, "flavour \(flavour) not selected") { card.isSelected }
            attachScreenshot("appearance-\(flavour)")
        }
        // Back to the shipped look.
        app.buttons["Ember colours"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.segmentedControls.buttons["System"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Goals

    func testGoalsEditAndSave() throws {
        try launch()
        waitForConnected()
        openSettingsRow("Goals")
        let save = app.buttons["Save goals"]
        waitFor(save, "Goals screen missing")
        scrollTo(save)
        save.tap()
        // Save pops back to Settings.
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'User Profile'")).firstMatch,
                "did not return to Settings after saving goals")
    }

    func testOpenGoalsLaunchArgument() throws {
        try launch(extra: ["-openGoals", "YES"])
        waitFor(app.buttons["Save goals"], timeout: 30, "-openGoals did not open Goals")
    }

    // MARK: - Wearable / ring screen

    func testWearableScreenShowsRing() throws {
        try launch()
        waitForConnected()
        openWearable()
        waitFor(app.staticTexts["Connected ring"].exists ? app.staticTexts["Connected ring"] : text(containing: "CONNECTED RING"))
        for label in ["Device", "Battery", "Firmware", "Last synced"] {
            XCTAssertTrue(text(containing: label).waitForExistence(timeout: 20), "\(label) row missing")
        }
        eventually(timeout: 20, "battery level not shown") {
            app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"\d+%"#)).firstMatch.exists
        }
        attachScreenshot("wearable")
    }

    func testRenameRing() throws {
        try launch()
        waitForConnected()
        openWearable()
        let rename = app.buttons["Rename ring"]
        waitFor(rename).tap()
        let field = app.textFields["Ring name"]
        waitFor(field, "rename sheet missing").tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText("E2E Ring")
        app.buttons["Save"].tap()
        eventually(timeout: 10, "name not saved (\(rename.value as? String ?? "-"))") {
            (rename.value as? String) == "E2E Ring"
        }
        back()
        eventually(timeout: 10, "chip does not use the new name") { app.buttons["ringChip"].label.contains("E2E Ring") }
    }

    func testFindRing() throws {
        try launch()
        waitForConnected()
        openWearable()
        let find = app.buttons["Find ring"]
        scrollTo(find)
        waitFor(find, "Find ring missing (flag / capability)").tap()
        // While the ring vibrates the button turns into Stop; it reverts by itself after ~10 s.
        let stop = app.buttons["Stop"]
        waitFor(stop, timeout: 5, "Find ring did not start")
        stop.tap()
        waitFor(find, timeout: 15, "Find ring did not stop")
    }

    func testDisconnectAndReconnect() throws {
        try launch()
        waitForConnected()
        openWearable()
        let disconnect = app.buttons["Disconnect"]
        scrollTo(disconnect)
        waitFor(disconnect).tap()
        // Disconnect asks first (ConfirmAction).
        let confirm = app.alerts["Disconnect ring?"].buttons["Disconnect"]
        waitFor(confirm, timeout: 5, "Disconnect did not ask first").tap()
        waitFor(text(containing: "No ring connected"), timeout: 15, "did not disconnect")
        attachScreenshot("disconnected")
        let reconnect = app.buttons["Reconnect last ring"]
        waitFor(reconnect, "no Reconnect action").tap()
        waitFor(text(containing: "Connected ring"), timeout: 30, "did not reconnect")
        back()
        waitForConnected()
    }

    // MARK: - Hints

    func testHintsShowAndDismiss() throws {
        try launch(extra: ["-resetCoachMarks", "YES"], coachMarks: true)
        waitForConnected()
        openTab("Vitals")
        let measureHint = element("coachMark.measure")
        waitFor(measureHint, timeout: 15, "Measure hint did not appear")
        measureHint.tap()
        eventually(timeout: 5, "Measure hint did not dismiss") { !measureHint.exists }
        let chipHint = element("coachMark.ringChip")
        waitFor(chipHint, timeout: 15, "ring-chip hint did not follow")
        chipHint.tap()
        eventually(timeout: 5, "ring-chip hint did not dismiss") { !chipHint.exists }
        // Seen hints stay gone after a relaunch.
        app.terminate()
        try launch(coachMarks: true)
        openTab("Vitals")
        XCTAssertFalse(element("coachMark.measure").waitForExistence(timeout: 4), "hint came back")
    }
}
