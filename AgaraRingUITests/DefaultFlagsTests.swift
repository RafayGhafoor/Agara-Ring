import XCTest

/// Default-flag mode (the shipped release configuration): blood pressure and blood sugar are off by flag
/// (`vitals_bp`, `vitals_glucose`, `measure_bp`, `measure_glucose`), so no card, tile, setting or text for them
/// may appear anywhere. The other UI tests run with `AgaraUITestCase.allFeatures`, which turns them on.
/// Store launch phase 1, item 1 — the same check runs on an iPad destination (see the e2e command in the report).
final class DefaultFlagsTests: AgaraUITestCase {

    private let bannedLabels = ["Blood pressure", "Blood sugar", "Blood glucose", "Glucose", "Hypertension", "mmHg", "mg/dL"]

    private func assertNoBloodPressureOrSugar(_ where_: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in bannedLabels {
            let hit = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch
            XCTAssertFalse(hit.exists, "\"\(word)\" is visible on \(where_) with default flags", file: file, line: line)
        }
    }

    private func walkEveryTab(_ label: String) {
        for tab in ["Today", "Vitals", "Activity", "Sleep", "Settings"] {
            openTab(tab)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            assertNoBloodPressureOrSugar("\(tab) tab (\(label))")
        }
        // Measure hub: no BP or glucose tile.
        openTab("Vitals")
        let measure = app.buttons["vitals.measure"]
        if measure.waitForExistence(timeout: 10) {
            measure.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCTAssertFalse(app.buttons["measure.tile.bloodPressure"].exists, "BP measure tile")
            XCTAssertFalse(app.buttons["measure.tile.glucose"].exists, "glucose measure tile")
            assertNoBloodPressureOrSugar("Measure hub (\(label))")
            for name in ["Close", "Cancel", "Done"] where app.buttons[name].firstMatch.exists { app.buttons[name].firstMatch.tap() }
        }
        // Settings: no glucose unit or calibration row; profile has no units group for glucose.
        openTab("Settings")
        XCTAssertFalse(app.staticTexts["Calibration"].exists, "Calibration row (BP / glucose)")
        let profile = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'User Profile'")).firstMatch
        if profile.waitForExistence(timeout: 5) {
            profile.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCTAssertFalse(element("profile.glucoseUnit").exists, "glucose unit picker")
            assertNoBloodPressureOrSugar("Profile (\(label))")
        }
    }

    /// Sample data needs no emulator, so this always runs (also on an iPad simulator).
    func testDefaultFlagsShowNoBloodPressureOrSugarWithSampleData() {
        app.launchArguments = ["-noCoachMarks", "YES", "-acceptDisclaimer", "YES", "-sampleData", "YES",
                               "-features", "", "-AppleLanguages", "(en)"]
        app.launch()
        waitFor(app.buttons["Vitals"].exists ? app.buttons["Vitals"] : app.tabBars.buttons["Vitals"], timeout: 40)
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        walkEveryTab("sample data")
    }

    /// With the emulator the ring really sends BP and glucose; the UI must still hide them.
    func testDefaultFlagsHideBloodPressureAndSugarThatTheRingSends() throws {
        try launch(extra: [], features: "")
        waitForConnected()
        waitForSyncIdle()
        walkEveryTab("emulator")
    }
}
