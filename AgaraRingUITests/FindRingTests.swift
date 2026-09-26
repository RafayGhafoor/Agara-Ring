import XCTest

/// Find ring with live proximity (plan `docs/process/plans/find-ring-proximity.md`) against the find emulator
/// (`--rssi-walk far-to-near:20 --verbose`, port `E2E_FIND_PORT`, log `E2E_FIND_LOG`): the walk starts at the
/// connection's first `RSSI` poll, i.e. when the screen opens.
/// 1. The band label climbs Out of range → Far → Getting warmer → Very close → Right here, with "Getting closer".
/// 2. Opening the screen never vibrates the ring; "Make it vibrate" sends `b5 0a` and "Stop" `b5 0b` (emulator log).
final class FindRingTests: AgaraUITestCase {

    private static let bandOrder = ["Out of range — walk around", "Far", "Getting warmer", "Very close", "Right here"]

    func testProximityClimbsToRightHereAndVibrateOnlyOnTap() throws {
        let log = try emulatorLogPath("E2E_FIND_LOG")
        try launch(portKey: "E2E_FIND_PORT")
        waitForConnected()
        let since = emulatorLogSize(log)
        openFindRing()
        XCTAssertTrue(app.staticTexts["Find your ring"].exists)
        let band = app.staticTexts["findRing.band"]

        // Follow the label through the walk (20 s of walk + the ~2 s smoothing lag), a screenshot per band.
        var seen: [String] = []
        var sawCloser = false
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let label = band.label
            if seen.last != label, Self.bandOrder.contains(label) {
                seen.append(label)
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // let the 0.35 s colour/label fade settle
                attachScreenshot("find-ring-\(Self.bandOrder.firstIndex(of: label) ?? 9)-\(label)")
            }
            let trend = app.staticTexts["findRing.trend"]
            if !sawCloser, trend.exists, trend.label == "Getting closer" { sawCloser = true }
            if label == "Right here", sawCloser { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(seen.last, "Right here", "labels seen: \(seen)")
        // Every band appears, in order (ignoring a momentary step back at a boundary).
        let firstSeen = seen.reduce(into: [String]()) { acc, s in if !acc.contains(s) { acc.append(s) } }
        XCTAssertEqual(firstSeen, Self.bandOrder, "labels seen: \(seen)")
        XCTAssertTrue(sawCloser, "never said 'Getting closer'")
        XCTAssertTrue(app.staticTexts["findRing.rssi"].label.hasSuffix("dBm"))

        // Decision 1: opening Find ring does not vibrate the ring.
        XCTAssertFalse(emulatorLog(log, from: since).contains("find device: vibrating"), "the ring vibrated without a tap")

        let vibrate = app.buttons["findRing.vibrate"]
        waitFor(vibrate, "Make it vibrate missing while connected")
        XCTAssertEqual(vibrate.label, "Make it vibrate")
        vibrate.tap()
        eventually(timeout: 10, "emulator never received b5 0a") {
            let text = emulatorLog(log, from: since)
            return text.contains("find device: vibrating") && text.contains("b50a")
        }
        let stop = app.buttons["findRing.stop"]
        waitFor(stop, timeout: 5, "Stop did not replace Make it vibrate")
        attachScreenshot("find-ring-5-vibrating")
        stop.tap()
        eventually(timeout: 10, "emulator never received b5 0b") { emulatorLog(log, from: since).contains("find device: stopped") }
        waitFor(vibrate, timeout: 5, "Make it vibrate did not come back after Stop")

        // Close returns to Wearable (FindRingModel.stop ends the RSSI polling on disappear).
        element("findRing.close").tap()
        waitFor(app.staticTexts["Wearable"], timeout: 5, "closing Find ring did not return to Wearable")
    }
}
