import XCTest

/// Measure hub: every tile runs to a value against the emulator (one optical test at a time, like the
/// real ring). `MeasureHeartRate` is the regression test for the Mac "Measure → Heart rate" crash.
final class MeasureTests: AgaraUITestCase {

    private func openHub() {
        openTab("Vitals")
        let measure = app.buttons["vitals.measure"]
        waitFor(measure, timeout: 30, "Measure button missing (no tests offered?)").tap()
        waitFor(app.staticTexts["Measure"], "hub did not open")
    }

    /// Tap a tile and wait for the sheet's status element to say the reading was saved.
    private func runTile(_ id: String, timeout: TimeInterval = 75, expectDigits: Bool = true,
                         onResult: (() -> Void)? = nil) {
        let tile = app.buttons["measure.tile.\(id)"]
        waitFor(tile, "tile \(id) missing").tap()
        let status = element("measurement.status")
        waitFor(status, "measurement sheet for \(id) did not open")
        // The visible copy is the source of truth (the status element's value can lag in XCUI snapshots);
        // the error state's "Try again" fails fast with the sheet's own message.
        let saved = app.staticTexts["Saved to your history."]
        let savedGrid = app.staticTexts["Saved"]
        let tryAgain = app.buttons["Try again"]
        eventually(timeout: timeout, "\(id) never reached a value") {
            if tryAgain.exists {
                XCTFail("\(id) ended in the error state: \(status.value as? String ?? "-")")
                return true
            }
            return saved.exists || savedGrid.exists || (status.value as? String ?? "").contains("Saved")
        }
        if expectDigits {
            let value = status.value as? String ?? ""
            let digitsOnScreen = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"^\d+(\.\d+)?(/\d+)?$"#)).firstMatch
            XCTAssertTrue(value.range(of: #"\d"#, options: .regularExpression) != nil || digitsOnScreen.exists,
                          "\(id): no reading on screen (\(value))")
        }
        onResult?()
        attachScreenshot("measure-\(id)-result")
        // Close the result (held open by -measureHoldResult) so the next test starts from the hub.
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        // The app must still be alive after the sheet goes away.
        XCTAssertEqual(app.state, .runningForeground, "app died after \(id)")
    }

    private func launchConnected() throws {
        try launch(extra: ["-measureHoldResult", "YES"])
        waitForConnected()
        waitForSyncIdle()
    }

    func testMeasureHeartRate() throws {
        try launchConnected()
        openHub()
        runTile("heartRate")
    }

    func testMeasureSpO2() throws {
        try launchConnected()
        openHub()
        runTile("spo2")
    }

    func testMeasureBloodPressure() throws {
        try launchConnected()
        openHub()
        runTile("bloodPressure")
    }

    func testMeasureStress() throws {
        try launchConnected()
        openHub()
        runTile("stress")
    }

    func testMeasureGlucose() throws {
        try launchConnected()
        openHub()
        runTile("glucose")
    }

    func testMeasureBloodComponents() throws {
        try launchConnected()
        openHub()
        runTile("bloodComponents", expectDigits: false) {
            XCTAssertTrue(self.text(containing: "Uric").exists || self.text(containing: "holesterol").exists,
                          "blood-components result grid not shown")
        }
    }

    /// Every tile in one session, back to back — the order a user would try them in. Catches a test
    /// that leaves the ring busy (a leftover stream kills the next optical test on the real ring).
    func testAllTilesBackToBack() throws {
        try launchConnected()
        for id in ["heartRate", "spo2", "bloodPressure", "stress", "glucose", "bloodComponents"] {
            openHub()
            runTile(id, expectDigits: id != "bloodComponents")
        }
    }

    // MARK: - No ring / Bluetooth unavailable

    /// No virtual ring, no paired ring: CoreBluetooth is unauthorized/unsupported in the simulator (and on a
    /// Mac without the Bluetooth permission). Tapping Heart rate must not crash — it either runs the demo
    /// reading (never paired) or says the ring isn't connected.
    func testHeartRateWithoutRingDoesNotCrash() throws {
        launchWithoutRing(extra: ["-measureHoldResult", "YES", "-forceOnboarding", "NO"])
        // A fresh install lands on onboarding; a previous test run leaves the virtual ring paired.
        let vitalsTab = app.tabBars.buttons["Vitals"]
        guard vitalsTab.waitForExistence(timeout: 15) else {
            throw XCTSkip("onboarding showing — no paired profile on this install")
        }
        vitalsTab.tap()
        let measure = app.buttons["vitals.measure"]
        guard measure.waitForExistence(timeout: 10) else {
            // Hidden when the ring offers no test; nothing to tap, so nothing to crash.
            return
        }
        measure.tap()
        let tile = app.buttons["measure.tile.heartRate"]
        waitFor(tile).tap()
        let status = element("measurement.status")
        waitFor(status)
        eventually(timeout: 20, "HR without a ring never settled") {
            let v = status.value as? String ?? ""
            return v.contains("Saved") || v.contains("isn't connected") || v.contains("Reconnect")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
