import XCTest

/// Base class for the end-to-end suite. Every test drives the real app against the ring emulator over the
/// debug socket transport (`-virtualRing <port>`), so the whole pipeline — frames, decode, store, UI — runs.
///
/// The runner (`tools/e2e_ios.sh`) starts the emulator(s) and hands the ports in through the test-runner
/// environment (`TEST_RUNNER_E2E_*` → `E2E_*` here):
///
/// | variable          | emulator                                                       |
/// |-------------------|----------------------------------------------------------------|
/// | `E2E_PORT`        | main ring, `--seed 7 --now … --days 8 --sleep-nights 8`         |
/// | `E2E_OTA_PORT`    | ring on firmware 00.12.07 that is offered 00.12.09             |
/// | `E2E_OTA_HTTP`    | that emulator's fake vendor version server                     |
/// | `E2E_CHG_PORT`    | ring sitting on its charger (`--charging`)                     |
/// | `E2E_NAP_PORT`    | ring with a night + a 40-min nap per day (`--sleep-sessions 2`) |
/// | `E2E_NAP_LOG`     | that emulator's log file (the DF requests it served)           |
/// | `E2E_FIND_PORT`   | ring whose signal walks far → near (`--rssi-walk far-to-near:20`) |
/// | `E2E_FIND_LOG`    | that emulator's log file (the find-device frames it received)  |
/// | `E2E_FW_PORT`     | ring that can be "re-flashed" mid-test (same identity, new `a1`) |
/// | `E2E_FW_LOG`      | that emulator's log file (the DF requests it served)            |
/// | `E2E_FW_HTTP`     | its control route: `POST /control/firmware?version=`            |
///
/// A variable that isn't set skips the tests that need that emulator, rather than failing them.
class AgaraUITestCase: XCTestCase {
    /// Every feature flag the release ships or can switch on, so every tile and screen is reachable.
    static let allFeatures = [
        "capability_probe", "measure_stress", "charging_state", "find_ring", "vitals_respiration",
        "vitals_met", "vitals_cardiac_load", "blood_components", "measure_lipids", "measure_glucose",
        "auto_measure_settings", "profile_sync", "firmware_check", "firmware_download", "firmware_install",
        "find_ring_proximity",
        // BP and blood sugar are off in the shipped defaults; the e2e run turns them on so the hidden code keeps working.
        "measure_bp", "vitals_bp", "vitals_glucose",
    ].map { "\($0)=on" }.joined(separator: ",")

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        // A screenshot on every failure, attached to the .xcresult (kept on success too for the report).
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "failure-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Environment

    func port(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("\(key) not set — run through tools/e2e_ios.sh (TEST_RUNNER_\(key)=<port>)")
        }
        return value
    }

    // MARK: - Emulator logs

    /// The path of an emulator log the runner hands in (e.g. `E2E_FIND_LOG`), or skip.
    func emulatorLogPath(_ key: String) throws -> String {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else {
            throw XCTSkip("\(key) not set — run through tools/e2e_ios.sh")
        }
        return path
    }

    /// The log's text from byte `offset` on (pass `emulatorLogSize` taken earlier to see only what happened since).
    func emulatorLog(_ path: String, from offset: Int = 0) -> String {
        guard let data = FileManager.default.contents(atPath: path), data.count > offset else { return "" }
        return String(decoding: data.dropFirst(offset), as: UTF8.self)
    }

    func emulatorLogSize(_ path: String) -> Int { FileManager.default.contents(atPath: path)?.count ?? 0 }

    /// Open Wearable › Ring actions › Find ring (the proximity screen) and wait for it.
    func openFindRing(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(app.buttons["ringChip"], file: file, line: line).tap()
        waitFor(app.staticTexts["Wearable"], "Wearable screen missing", file: file, line: line)
        let find = app.buttons["Find ring"]
        scrollTo(find)
        waitFor(find, "Find ring missing (flag find_ring_proximity)", file: file, line: line).tap()
        waitFor(app.staticTexts["findRing.band"], timeout: 10, "Find ring screen did not open", file: file, line: line)
    }

    // MARK: - Launch

    /// Launch against the ring emulator on `portKey`, with every feature flag on and coach marks off.
    @discardableResult
    func launch(portKey: String = "E2E_PORT",
                extra: [String] = [],
                coachMarks: Bool = false,
                features: String = AgaraUITestCase.allFeatures) throws -> XCUIApplication {
        let ringPort = try port(portKey)
        app.launchArguments = [
            "-virtualRing", ringPort,
            "-features", features,
            "-historyDays", "8",
            "-historyWindowDays", "90",
            // Writes one line per sync pass and one per planned day to Documents/syncdiag.log. Debug-only in the app
            // and inert unless asked, so it costs nothing here — and when a sync stores nothing, this file is the only
            // place that says why (2026-11-19: the store capture had 0 measurements and no channel carried the reason).
            "-syncDiag", "YES",
            "-noCoachMarks", coachMarks ? "NO" : "YES",
            // Start at Today: a clean install otherwise sits on onboarding and every ring assertion fails upstream.
            // Minimal profile, no demo rows — the ring's own data is what these tests assert.
            "-skipOnboarding", "YES",
            "-acceptDisclaimer", "YES",   // the one-time wellness disclaimer (debug launch argument)
            // Keep every run on the same, shipped look regardless of what an earlier test chose.
            "-AppleLanguages", "(en)",
        ] + extra
        app.launch()
        dismissSystemAlert()
        return app
    }

    /// Tap through a system alert that a fresh install raises (today: the notifications permission prompt), which
    /// otherwise blocks **every** element query — the failure then looks like "ring chip missing" or a dead app.
    /// Scoped to the prompts we expect; anything else is left alone so a real dialog still fails the test loudly.
    func dismissSystemAlert(timeout: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: timeout) {
                button.tap()
                return
            }
        }
    }

    /// Launch with no ring transport at all (CoreBluetooth path — unauthorized/unsupported in the sim).
    func launchWithoutRing(extra: [String] = []) {
        app.launchArguments = ["-noCoachMarks", "YES", "-acceptDisclaimer", "YES", "-features", Self.allFeatures] + extra
        app.launch()
    }

    // MARK: - Waiting

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 20,
                 _ message: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            attachScreenshot("waiting-for-\(element.description.prefix(40))")
            XCTFail(message ?? "Timed out waiting for \(element)", file: file, line: line)
        }
        return element
    }

    /// Poll until `predicate` is true (or fail). XCUI's `waitForExistence` only covers existence.
    func eventually(timeout: TimeInterval = 20, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        attachScreenshot("eventually-\(message.prefix(40))")
        XCTFail(message, file: file, line: line)
    }

    func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Any element carrying `identifier`, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Any static text containing `text`.
    func text(containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func anyElement(labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    // MARK: - Navigation

    func openTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 20) {
            tab.tap()
            return
        }
        // iOS 18–25 fallback bar / Designed-for-iPad sidebar: any button with the tab's label.
        let button = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        waitFor(button, "tab \(name) not found", file: file, line: line).tap()
    }

    /// Scroll the frontmost scroll view until `element` is hittable (bounded).
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 12, up: Bool = false) {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes {
            if up { app.swipeDown() } else { app.swipeUp() }
            n += 1
        }
    }

    /// Wait until the ring's history has actually **landed**, not merely until the "Syncing" label is quiet.
    ///
    /// `waitForSyncIdle` returns after 3 s without the label, which is satisfied *mid-sync* on a 30-day pass: the early
    /// days deliver steps and sleep first and heart rate later. Measured 2026-11-19 — the App Preview test had 395 HR
    /// readings because it spends ~25 s tapping before it reaches Vitals, while the screenshot walk shot frame 03 with
    /// "No heart rate yet" and frame 04 with "Not enough data for this period". Same launch args, same emulator: the
    /// only difference was time. Call this while the **Vitals** tab is open; it waits for the empty-state copy to go.
    func waitForHealthData(timeout: TimeInterval = 600, file: StaticString = #filePath, line: UInt = #line) {
        // Positive signal only. Waiting for the ABSENCE of the empty-state copy is not enough: it is also absent while
        // the card is still loading, which is how an earlier version of this wait passed and the walk then captured an
        // empty card (2026-11-19 — 42,106 measurement rows in the store, "No heart rate yet" in the frame).
        let reading = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "bpm")).firstMatch
        let emptyStates = ["No heart rate yet", "No oxygen readings yet"]
        // Wait in LONG idle chunks and query once per chunk. The first version of this polled `exists` every second for
        // 300 s and timed out while still showing "No heart rate yet" — 300 accessibility snapshots keep the app's main
        // thread busy, and this codebase already documents that measure/sync work during a busy main thread delays HR
        // samples. The App Preview test, which taps and idles rather than polling, gets 395 readings on the same rig.
        let chunk: TimeInterval = 20
        let deadline = Date().addingTimeInterval(timeout)
        var lastEmpty = ""
        while Date() < deadline {
            if reading.exists { return }
            if let found = emptyStates.first(where: { app.staticTexts[$0].exists }) {
                lastEmpty = found
                print("waitForHealthData: still \(found) — idling \(Int(chunk)) s")
                RunLoop.current.run(until: Date().addingTimeInterval(chunk))
                continue
            }
            return
        }
        attachScreenshot("health-data-never-arrived")
        let message = "the ring's history never delivered a reading within \(Int(timeout)) s (still showing \"\(lastEmpty)\")"
        // Diagnostics only: while the cause is being found we still want the rest of the walk to run and write its logs.
        // Never set this for a release capture — it is exactly how three empty frames shipped.
        // `xcodebuild` forwards `TEST_RUNNER_*` into the test process, so the capture script sets that form; accept both.
        let env = ProcessInfo.processInfo.environment
        if env["STORE_ALLOW_EMPTY_HEALTH"] == "1" || env["TEST_RUNNER_STORE_ALLOW_EMPTY_HEALTH"] == "1" {
            print("WARNING: \(message) — continuing because STORE_ALLOW_EMPTY_HEALTH=1")
            return
        }
        XCTFail(message, file: file, line: line)
    }

    /// Wait until the post-connect history sync has finished (the header's "Syncing" bar gone for 3 s).
    /// Measuring while that sync floods the main thread delays HR samples past the 3 s contact-gap rule and
    /// the reading is (wrongly) abandoned — see the report; tests measure the way a user does, after sync.
    func waitForSyncIdle(timeout: TimeInterval = 120) {
        let bar = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Syncing'")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var quietSince: Date?
        while Date() < deadline {
            if bar.exists { quietSince = nil } else if quietSince == nil { quietSince = Date() }
            if let quietSince, Date().timeIntervalSince(quietSince) >= 3 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        attachScreenshot("sync-never-idle")
    }

    /// Wait until the virtual ring's post-auth handshake has completed (the header reads connected).
    func waitForConnected(timeout: TimeInterval = 40, file: StaticString = #filePath, line: UInt = #line) {
        let chip = app.buttons["ringChip"]
        waitFor(chip, timeout: timeout, "ring chip missing", file: file, line: line)
        eventually(timeout: timeout, "ring never connected (chip: \(chip.label))", file: file, line: line) {
            let label = chip.label.lowercased()
            return label.contains(" connected") || label.contains(" charging")
        }
    }
}
