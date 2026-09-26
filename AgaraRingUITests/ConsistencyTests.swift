import XCTest

/// Consistency framework (docs/process/plans/consistency-framework.md), phases 1–3 on the real app against the
/// emulator: a measurement keeps running when its sheet closes and the user changes tab; Disconnect and Forget
/// ask first (ConfirmAction); the battery chart shows a value when scrubbed (AgaraChart).
final class ConsistencyTests: AgaraUITestCase {

    private func openWearable() {
        let chip = app.buttons["ringChip"]
        waitFor(chip).tap()
        waitFor(app.staticTexts["Wearable"], "Wearable screen missing")
    }

    /// Swipe the frontmost sheet down (a swipe leaves a measurement running; Cancel would stop it).
    private func swipeSheetDown() {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.98)))
    }

    private var statusValue: String { element("measurement.status").value as? String ?? "" }

    // MARK: - Measurement engine (phase 2)

    /// Start heart rate, close the sheet, switch tab: the pill says it's still measuring; back on Vitals the
    /// Measure button resumes the same running measurement; close again and the result lands (and is saved)
    /// while the sheet is closed; the pill reopens it on the result.
    func testHeartRateKeepsRunningAcrossTabsAndResumes() throws {
        try launch(extra: ["-measureHoldResult", "YES"])
        waitForConnected()
        waitForSyncIdle()
        openTab("Vitals")
        waitFor(app.buttons["vitals.measure"], timeout: 30).tap()
        waitFor(app.buttons["measure.tile.heartRate"])
        attachScreenshot("measure-hub-icon-tiles")
        app.buttons["measure.tile.heartRate"].tap()
        waitFor(element("measurement.status"), "measurement sheet did not open")
        eventually(timeout: 20, "HR never started measuring (\(statusValue))") { statusValue.contains("Measuring") }

        swipeSheetDown()
        let pill = app.buttons["measurement.pill"]
        waitFor(pill, timeout: 10, "no in-app measurement pill after closing the sheet")
        openTab("Today")
        XCTAssertTrue(pill.exists, "the pill must follow the user to another tab")
        XCTAssertTrue(pill.label.contains("Measuring"), "still measuring on Today (\(pill.label))")
        attachScreenshot("measure-running-on-today")

        // Back to Vitals: Measure resumes the running test instead of offering the hub.
        openTab("Vitals")
        app.buttons["vitals.measure"].tap()
        waitFor(element("measurement.status"), "sheet did not reopen")
        XCTAssertFalse(app.buttons["measure.tile.heartRate"].exists, "reopened the hub instead of the running test")
        XCTAssertTrue(statusValue.contains("Measuring") || statusValue.contains("Saved"), "not resumed (\(statusValue))")
        attachScreenshot("measure-resumed")

        // Close it again; the result lands with the sheet closed, on another tab.
        if statusValue.contains("Measuring") {
            swipeSheetDown()
            openTab("Today")
            eventually(timeout: 75, "result never landed while the sheet was closed (\(pill.label))") {
                pill.label.contains("Saved")
            }
            attachScreenshot("measure-result-pill")
            pill.tap()
            waitFor(element("measurement.status"), "pill did not open the result")
        }
        eventually(timeout: 75, "no saved result (\(statusValue))") { statusValue.contains("Saved") }
        XCTAssertTrue(statusValue.range(of: #"\d"#, options: .regularExpression) != nil, "no value (\(statusValue))")
        attachScreenshot("measure-result-after-resume")
        waitFor(app.buttons["Done"]).tap()
        eventually(timeout: 5, "pill should go once the result is acknowledged") { !pill.exists }
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - ConfirmAction (phase 1)

    func testDisconnectAndForgetAreConfirmed() throws {
        try launch()
        waitForConnected()
        openWearable()

        let disconnect = app.buttons["Disconnect"]
        scrollTo(disconnect)
        waitFor(disconnect).tap()
        let disconnectAlert = app.alerts["Disconnect the ring?"]
        waitFor(disconnectAlert, timeout: 5, "Disconnect did not ask first")
        attachScreenshot("confirm-disconnect")
        disconnectAlert.buttons["Cancel"].tap()
        XCTAssertTrue(text(containing: "Connected ring").waitForExistence(timeout: 5), "Cancel must keep the ring connected")

        let forget = app.buttons["Forget ring"]
        scrollTo(forget)
        waitFor(forget).tap()
        let forgetAlert = app.alerts["Forget this ring?"]
        waitFor(forgetAlert, timeout: 5, "Forget did not ask first")
        XCTAssertTrue(forgetAlert.buttons["Forget"].exists)
        attachScreenshot("confirm-forget")
        forgetAlert.buttons["Cancel"].tap()
        XCTAssertTrue(text(containing: "Connected ring").waitForExistence(timeout: 5), "Cancel must keep the ring")
    }

    // MARK: - AgaraChart (phase 1)

    func testBatteryChartShowsAValueOnScrub() throws {
        try launch()
        // The header's sync indicator ("Syncing day N of M") while the post-connect history pass runs.
        if element("sync.status").waitForExistence(timeout: 30) { attachScreenshot("sync-header-indicator") }
        waitForConnected()
        openWearable()
        let chart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["battery.chart", "chart"])).firstMatch
        scrollTo(chart)
        waitFor(chart, timeout: 20, "battery chart missing (no history?)")
        if !chart.isHittable { app.swipeUp() }
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        let tooltip = element("chart.tooltip")
        eventually(timeout: 5, "no value marker after scrubbing the battery chart") {
            tooltip.exists && tooltip.label.contains("%")
        }
        attachScreenshot("battery-chart-scrub")
    }
}
