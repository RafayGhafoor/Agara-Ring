import XCTest

/// App Preview footage (store-launch phase 5, `docs/process/plans/store-launch/store-assets.md` §4.2 / §4.5).
/// Performs the storyboard beats in the simulator against the **hero** ring emulator, at a calm pace, while
/// `scripts/store_video_capture.sh` records the screen (`xcrun simctl io booted recordVideo --codec=h264`).
/// Every beat is logged with a wall-clock time (seconds since 1970) into a JSON sidecar, so the motion scenes cut on
/// the marks and a re-capture never needs manual re-editing:
///
///   { "marks": { "launch": 1790000000.12, "synced": ..., "today": ..., ... }, "storeNow": "...", "theme": "dark" }
///
/// Environment (`TEST_RUNNER_<NAME>` on the host, from `store/scenario.env` via the script):
///  * `E2E_PORT`           the hero emulator's port (9951)
///  * `STORE_NOW`          the emulator's `--now` (default `2026-09-24T19:30:00`)
///  * `STORE_VIDEO_BEATS`  where to write the JSON sidecar (default: the test's temporary directory)
///  * `STORE_MAP_WAIT`     seconds to let map tiles load on the first visit to the workout (default 6)
///
/// Same hooks as `StoreScreenshotTests` (debug only): `-fixedNow`, `-storeCapture YES`, shipped flag defaults (`-features ""`).
/// Screen recordings only: no fingers, no other app. Each mark is taken right BEFORE the action it names, and the
/// element is resolved first, so the mark is within a few tenths of a second of the visible change.
final class StoreVideoTests: AgaraUITestCase {
    private var marks: [String: Double] = [:]

    private var storeNow: String {
        ProcessInfo.processInfo.environment["STORE_NOW"].flatMap { $0.isEmpty ? nil : $0 } ?? "2026-09-24T19:30:00"
    }

    private func mark(_ name: String) {
        marks[name] = Date().timeIntervalSince1970
        NSLog("STORE_BEAT %@ %.3f", name, marks[name] ?? 0)
    }

    private func dwell(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func writeBeats() {
        let path = ProcessInfo.processInfo.environment["STORE_VIDEO_BEATS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("store-video-beats.json")
        let body: [String: Any] = ["marks": marks, "storeNow": storeNow, "theme": "dark", "port": ProcessInfo.processInfo.environment["E2E_PORT"] ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSLog("STORE_BEATS_FILE %@", path)
    }

    // MARK: - The flow

    func testHeroFlow() throws {
        defer { writeBeats() }

        // Beat 0-5 s: launch, connect, sync. The clip before "synced" is the "Syncs straight to your phone" beat.
        mark("launch")
        try launch(extra: [
            "-fixedNow", storeNow,
            "-storeCapture", "YES",
            "-theme", "dark",
            "-historyDays", "30",
            "-AppleLocale", "en_US",
        ], features: "")
        waitForConnected()
        waitForSyncIdle()
        mark("synced")

        // Beat 5-8 s: Today (rings closed, numbers settled).
        let today = app.tabBars.buttons["Today"]
        waitFor(today, timeout: 20, "Today tab missing")
        _ = today.isHittable
        mark("today")
        today.tap()
        eventually(timeout: 90, "Today shows no step count") { anyElement(labelContains: "step").exists }
        dwell(4.0)

        // Beat 8-12 s: Sleep (hypnogram draws in, score).
        let sleepTab = app.tabBars.buttons["Sleep"]
        waitFor(sleepTab, timeout: 20, "Sleep tab missing")
        _ = sleepTab.isHittable
        mark("sleep")
        sleepTab.tap()
        eventually(timeout: 90, "Sleep day view shows no night") {
            text(containing: "Night timeline").exists && !text(containing: "No sleep recorded").exists
        }
        dwell(4.5)

        // Beat 12-16 s: Vitals -> heart-rate detail, tooltip scrubbed across the day.
        let vitalsTab = app.tabBars.buttons["Vitals"]
        waitFor(vitalsTab, timeout: 20, "Vitals tab missing")
        mark("vitalsOpen")
        vitalsTab.tap()
        let hrCard = text(containing: "HEART RATE")
        eventually(timeout: 90, "Vitals heart-rate card has no data") {
            hrCard.exists && !text(containing: "No data").exists
        }
        dwell(2.0)
        _ = hrCard.isHittable
        mark("hrOpen")
        hrCard.tap()
        waitFor(app.buttons["Back"], timeout: 15, "heart-rate detail did not open")
        dwell(1.4)   // chart draws in
        // Scrub the chart from the early morning to the evening peak, slowly (a press then a drag, so the
        // tooltip follows). Coordinates are relative to the window: the chart sits at about 4-96 % x, 19-48 % y.
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.36))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.36))
        mark("hrScrub")
        from.press(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
        dwell(0.6)

        // Beat 16-19.5 s: Vitals (HRV / SpO2 / stress ...), a slow scroll.
        mark("vitalsBack")
        app.buttons["Back"].tap()
        dwell(1.2)
        mark("vitalsScroll")
        app.swipeUp(velocity: .slow)
        dwell(1.4)
        app.swipeUp(velocity: .slow)
        dwell(1.5)

        // Beat 19.5-23 s: Activity (weekly goal) and the sample walk with its route map.
        let activityTab = app.tabBars.buttons["Activity"]
        waitFor(activityTab, timeout: 20, "Activity tab missing")
        // Off-camera pass first: the map tiles load on the first visit, so the pass that is used shows the map at once.
        activityTab.tap()
        eventually(timeout: 60, "Activity shows no steps") { anyElement(labelContains: "step").exists }
        let row = app.buttons["activity.workoutRow"].firstMatch
        scrollTo(row)
        waitFor(row, timeout: 30, "no workout on Activity (store-capture walk missing)").tap()
        waitFor(app.buttons["Back"], timeout: 15, "workout summary did not open")
        let mapWait = TimeInterval(ProcessInfo.processInfo.environment["STORE_MAP_WAIT"] ?? "") ?? 6
        dwell(mapWait)
        app.buttons["Back"].tap()
        dwell(1.0)
        // On camera: Activity from the top, then the workout again (tiles cached).
        app.swipeDown(velocity: .fast)
        dwell(0.8)
        let vitalsAgain = app.tabBars.buttons["Vitals"]
        vitalsAgain.tap()          // leave and come back so Activity's tab switch is on camera
        dwell(1.0)
        mark("activity")
        activityTab.tap()
        dwell(2.4)
        scrollTo(row)
        _ = row.isHittable
        mark("workout")
        row.tap()
        waitFor(app.buttons["Back"], timeout: 15, "workout summary did not open (2nd)")
        dwell(3.0)
        app.buttons["Back"].tap()
        dwell(0.8)

        // Beat 23-26.5 s: Measure hub (heart rate, blood oxygen, stress spot checks).
        vitalsTab.tap()
        let measure = app.buttons["vitals.measure"]
        waitFor(measure, timeout: 30, "Measure button missing")
        dwell(1.2)
        mark("measure")
        measure.tap()
        waitFor(app.staticTexts["Measure"], "measure hub did not open")
        dwell(3.4)
        let close = app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Done"]
        if close.exists { close.tap() } else { app.swipeDown() }
        dwell(0.8)

        // Beat 26.5-29 s: Settings > Privacy (on-phone storage, optional cloud backup, no account), under the end card.
        let settingsTab = app.tabBars.buttons["Settings"]
        waitFor(settingsTab, timeout: 20, "Settings tab missing")
        settingsTab.tap()
        let privacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Privacy")).firstMatch
        scrollTo(privacy)
        waitFor(privacy, "Privacy row missing in Settings")
        dwell(0.6)
        mark("privacy")
        privacy.tap()
        dwell(4.0)
        mark("end")
    }
}
