import XCTest

/// App Store screenshots (store-launch phase 5, `docs/process/plans/store-launch/store-assets.md` §2.2 / §3).
/// Walks the storyboard screens against the **hero** ring emulator and attaches one full-screen PNG per screen to
/// the `.xcresult` (`XCUIScreen.main.screenshot()`, so the status-bar override is in the picture). On an iPhone 17
/// Pro Max that is the exact 6.9" size, 1320 x 2868. `scripts/store_shots_ios.sh` runs it and extracts the
/// attachments to `store/raw/ios/<theme>/NN-name.png`.
///
/// The debug hooks it relies on (compiled out of Release):
///  * `-fixedNow <ISO>`   the app's clock equals the emulator's `--now` (`AppClock`);
///  * `-storeCapture YES` profile "Maya", no Developer/debug rows, "Updated just now", no informational banner, and the
///                        seeded 45-minute walk with a GPS route (`StoreCapture`, `SampleWorkout`).
///
/// Environment (`TEST_RUNNER_<NAME>` on the host, from `store/scenario.env` via the script):
///  * `E2E_PORT`   the hero emulator's port (9951)
///  * `STORE_NOW`  the emulator's `--now` (default `2026-09-24T19:30:00`)
///  * `STORE_MAP_WAIT` seconds to let map tiles load on the workout screen (default 6)
///
/// One test per theme; the shipped flag defaults (`-features ""`: no BP, no blood sugar, no coach, no cloud) are used, so
/// nothing in the frames is hidden behind a developer flag. No value is retouched.
final class StoreScreenshotTests: AgaraUITestCase {
    private var theme = "dark"
    private var frame = 0

    private var storeNow: String {
        ProcessInfo.processInfo.environment["STORE_NOW"].flatMap { $0.isEmpty ? nil : $0 } ?? "2026-09-24T19:30:00"
    }

    func testStoreScreenshotsDark() throws { try walk(theme: "dark") }
    func testStoreScreenshotsLight() throws { try walk(theme: "light") }

    // MARK: - The walk

    private func walk(theme: String) throws {
        self.theme = theme
        frame = 0
        try launch(extra: [
            "-fixedNow", storeNow,
            "-storeCapture", "YES",
            "-theme", theme,
            "-historyDays", "30",
            "-AppleLocale", "en_US",
        ], features: "")
        waitForConnected()
        waitForSyncIdle()

        // 01 Today: greeting, rings, sleep and heart-rate tiles.
        openTab("Today")
        eventually(timeout: 90, "Today shows no step count") { anyElement(labelContains: "step").exists }
        snap("today")

        // 02 Sleep: last night, score, hypnogram.
        openTab("Sleep")
        eventually(timeout: 90, "Sleep day view shows no night") {
            text(containing: "Night timeline").exists && !text(containing: "No sleep recorded").exists
        }
        snap("sleep")

        // 03 Vitals: the recovery-related cards (HRV, SpO2, stress, resting heart rate).
        openTab("Vitals")
        eventually(timeout: 90, "Vitals heart-rate card has no data") {
            text(containing: "HEART RATE").exists && !text(containing: "No data").exists
        }
        snap("vitals")

        // 04 Heart-rate detail (the card opens the metric's chart page).
        let hrCard = text(containing: "HEART RATE")
        hrCard.tap()
        waitFor(app.buttons["Back"], timeout: 15, "heart-rate detail did not open")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        snap("heart-rate")
        goBack()

        // 05 Activity: rings, steps chart, today's workout.
        openTab("Activity")
        eventually(timeout: 60, "Activity shows no steps") { anyElement(labelContains: "step").exists }
        snap("activity")

        // 06 Workout: the seeded walk with its route map, pace and heart rate.
        let row = app.buttons["activity.workoutRow"].firstMatch
        scrollTo(row)
        waitFor(row, timeout: 30, "no workout on Activity (store-capture walk missing)").tap()
        waitFor(app.buttons["Back"], timeout: 15, "workout summary did not open")
        let mapWait = TimeInterval(ProcessInfo.processInfo.environment["STORE_MAP_WAIT"] ?? "") ?? 6
        RunLoop.current.run(until: Date().addingTimeInterval(mapWait))   // let the map tiles draw
        snap("workout")
        goBack()

        // 07 Measure hub.
        openTab("Vitals")
        let measure = app.buttons["vitals.measure"]
        waitFor(measure, timeout: 30, "Measure button missing").tap()
        waitFor(app.staticTexts["Measure"], "measure hub did not open")
        snap("measure")
        let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Done"]
        if close.exists { close.tap() } else { app.swipeDown() }

        // 08 Settings > Privacy (on-phone storage, optional cloud backup, no account).
        openTab("Settings")
        let privacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Privacy")).firstMatch
        scrollTo(privacy)
        waitFor(privacy, "Privacy row missing in Settings").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        snap("privacy")
    }

    // MARK: - Helpers

    /// A full-screen capture (status bar included), attached as `<theme>-NN-<name>`. XCUIScreen returns native pixels.
    private func snap(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))   // let animations, charts and count-ups settle
        frame += 1
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = String(format: "%@-%02d-%@", theme, frame, name)
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func goBack() {
        let back = app.buttons["Back"]
        if back.exists { back.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }
}
