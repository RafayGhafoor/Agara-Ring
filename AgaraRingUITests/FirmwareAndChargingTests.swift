import XCTest

/// Firmware check → download → install against the emulator's AB-OTA responder, and the charging state.
final class FirmwareAndChargingTests: AgaraUITestCase {

    func testFirmwareCheckDownloadInstall() throws {
        let http = try port("E2E_OTA_HTTP")
        try launch(portKey: "E2E_OTA_PORT",
                   extra: ["-firmwareCheckUrl", "http://127.0.0.1:\(http)/api/Version/GetVersionForSport"])
        waitForConnected()
        app.buttons["ringChip"].tap()
        waitFor(app.staticTexts["Wearable"])

        // Check (or it may already know from the daily check).
        let offered = anyElement(labelContains: "00.12.09")
        let check = app.buttons["Check for firmware update"]
        if !offered.waitForExistence(timeout: 5) {
            waitFor(check, "no firmware Check button (firmware_check flag / a1 identity)").tap()
        }
        waitFor(offered, timeout: 30, "the update to 00.12.09 was not offered")
        offered.tap()

        // Release sheet: Download (unless an earlier run already has it).
        let download = app.buttons["Download"]
        let install = app.buttons["Install on ring"]
        if download.waitForExistence(timeout: 5) { download.tap() }
        waitFor(install, timeout: 60, "download never became ready")
        eventually(timeout: 30, "install still blocked by a gate") { install.isEnabled }
        attachScreenshot("firmware-ready")
        install.tap()
        let confirm = app.alerts.buttons["Install"]
        waitFor(confirm, "no install confirmation").tap()

        waitFor(app.staticTexts["Updated to 00.12.09"], timeout: 300, "install did not finish")
        attachScreenshot("firmware-updated")
        app.buttons["Done"].tap()
    }

    func testChargingStateAndTimeToFull() throws {
        try launch(portKey: "E2E_CHG_PORT")
        let chip = app.buttons["ringChip"]
        waitFor(chip, timeout: 30)
        eventually(timeout: 40, "chip never said charging (\(chip.label))") { chip.label.lowercased().contains("charging") }

        // Measuring is blocked on the charger.
        openTab("Vitals")
        let measure = app.buttons["vitals.measure"]
        waitFor(measure).tap()
        waitFor(element("measure.chargingBanner"), "no charging banner in the hub")
        XCTAssertFalse(app.buttons["measure.tile.heartRate"].isEnabled, "HR tile should be disabled while charging")
        app.buttons["Close"].firstMatch.tap()

        // Wearable: "Charging · NN %" and, once three readings span 3 min, "Full in ~N min".
        chip.tap()
        waitFor(text(containing: "Charging ·"), timeout: 20, "no charging status line")
        attachScreenshot("charging")
        eventually(timeout: 300, "no time-to-full estimate") { text(containing: "Full in ~").exists }
        attachScreenshot("charging-full-in")
    }
}
