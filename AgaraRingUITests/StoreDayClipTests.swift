import XCTest

/// One short, real clip of the Today screen at one pinned clock, for the App Preview's "whole day in seconds" scene
/// (`scripts/store_video_capture.sh --day`). The script restarts the hero emulator at `--now <clock>` (no `--today-steps`, so
/// steps, calories and the heart-rate record accumulate with the clock), records the simulator, and runs this test once per
/// clock with the app launched at the same instant (`-fixedNow`). The app is uninstalled between runs (clean store).
///
/// Choreography (identical for every clock, so the clips cut together): connect, let the history sync finish, Sleep tab, then
/// Today again (the rings and cards animate in), a slow scroll down and back up, then the test ends (the runner terminates the app,
/// the last big change in the recording, which the script uses to find the clip).
///
/// Environment (`TEST_RUNNER_<NAME>`): `E2E_PORT` (9951), `STORE_NOW` (the emulator's `--now`), `STORE_HOLD` (dwell on Today, default 1.6 s).
/// Debug hooks as in `StoreScreenshotTests`; shipped flag defaults; screen recording only, no value is touched.
final class StoreDayClipTests: AgaraUITestCase {
    func testDayClip() throws {
        let now = ProcessInfo.processInfo.environment["STORE_NOW"].flatMap { $0.isEmpty ? nil : $0 } ?? "2026-09-24T19:30:00"
        try launch(extra: [
            "-fixedNow", now,
            "-storeCapture", "YES",
            "-theme", "dark",
            "-historyDays", "30",
            "-AppleLocale", "en_US",
        ], features: "")
        waitForConnected()
        waitForSyncIdle()

        let today = app.tabBars.buttons["Today"]
        let sleep = app.tabBars.buttons["Sleep"]
        waitFor(today, timeout: 20, "Today tab missing")
        eventually(timeout: 90, "Today shows no step count") { anyElement(labelContains: "step").exists }
        sleep.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        today.tap()
        // Dwell on Today before the scroll: 1.6 s normally; `STORE_HOLD` (seconds) lengthens it for the clip that ends the day scene
        // and is held on screen as the "Your day, at a glance" beat.
        let hold = ProcessInfo.processInfo.environment["STORE_HOLD"].flatMap(Double.init) ?? 1.6
        RunLoop.current.run(until: Date().addingTimeInterval(hold))
        app.swipeUp(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        app.swipeDown(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
}
