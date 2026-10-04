import XCTest

/// Regression test for the TestFlight 1.0.0 (1) crash (iOS 26.7.1): `EXC_BREAKPOINT` in
/// `EnvironmentValues.subscript.getter` ← `EnvironmentBox.update` during `-[UIScene _performSystemSnapshotWithActions:]`
/// — the app went to the background, iOS snapshotted it, and a view reading `@Environment(<Observable>.self)` was
/// rebuilt without the object ("No Observable object of type X found"). The fix is `.agaraRingEnvironment()` at every
/// presentation root (`PulseLoop/Views/AgaraRingEnvironment.swift`).
///
/// Opens each main sheet / cover / pushed screen, sends the app home (the snapshot path), checks the process survived,
/// brings it back and checks the presented screen is still there. Before the fix the simulator did not crash, but every
/// open sheet vanished on the way back: the snapshot flips the OS appearance, which swapped the theme and re-identified
/// the whole stack (`RootAppView.applyResolvedTheme`) — the same rebuild-during-snapshot the device crash came from.
final class BackgroundSnapshotTests: AgaraUITestCase {

    /// Home → wait for the snapshot → the app must still be alive → activate → the marker must still be on screen.
    private func backgroundAndReturn(_ what: String, marker: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) {
        waitFor(marker, timeout: 15, "\(what): screen did not open", file: file, line: line)
        attachScreenshot("open-\(what)")
        XCUIDevice.shared.press(.home)
        eventually(timeout: 10, "\(what): app never left the foreground", file: file, line: line) {
            app.state != .runningForeground
        }
        // Give iOS time to take (and re-take) the app-switcher snapshots; the process must stay alive throughout.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            XCTAssertNotEqual(app.state, .notRunning, "\(what): the app died while backgrounding (snapshot crash)",
                              file: file, line: line)
            if app.state == .notRunning { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        app.activate()
        eventually(timeout: 15, "\(what): app did not come back to the foreground", file: file, line: line) {
            app.state == .runningForeground
        }
        waitFor(marker, timeout: 10, "\(what): screen gone after returning (relaunched?)", file: file, line: line)
        attachScreenshot("background-\(what)")
    }

    private func tapIfPresent(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { element.tap() }
    }

    func testSheetsSurviveBackgroundSnapshot() throws {
        // `-forceOnboarding NO`: a persisted `forceOnboarding` default from another run must not hide the tabs.
        try launch(extra: ["-forceOnboarding", "NO"])
        waitForConnected()
        waitForSyncIdle()

        // Today (WindowGroup root) itself.
        backgroundAndReturn("today", marker: app.buttons["ringChip"])

        // Vitals › Measure hub (sheet).
        openTab("Vitals")
        waitFor(app.buttons["vitals.measure"], timeout: 30, "Measure button missing").tap()
        backgroundAndReturn("measure-hub", marker: app.buttons["measure.tile.heartRate"])
        tapIfPresent(app.buttons["Close"])

        // Activity › Workout history (sheet) and weekly goal editor (sheet).
        openTab("Activity")
        waitFor(app.buttons["Workout history"], "history button missing").tap()
        backgroundAndReturn("workout-history", marker: app.navigationBars["Workout history"])
        tapIfPresent(app.buttons["Done"])
        let goals = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'WEEKLY GOAL'")).firstMatch
        scrollTo(goals)
        waitFor(goals, "weekly goal card missing").tap()
        backgroundAndReturn("goal-editor", marker: app.navigationBars["Edit goals"])
        tapIfPresent(app.buttons["Cancel"])

        // Activity › Record (pushed screen in the root NavigationStack).
        let record = app.buttons["+ Record Activity"]
        scrollTo(record, up: true)
        waitFor(record, "Record button missing").tap()
        backgroundAndReturn("record-select", marker: app.buttons["Back"].firstMatch)
        tapIfPresent(app.buttons["Back"].firstMatch)

        // Sleep › day picker (sheet).
        openTab("Sleep")
        let dayPicker = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Today' OR label CONTAINS[c] 'Last night' OR label CONTAINS[c] 'Yesterday'")).firstMatch
        if dayPicker.waitForExistence(timeout: 10) {
            dayPicker.tap()
            if app.navigationBars["Choose a day"].waitForExistence(timeout: 5) {
                backgroundAndReturn("sleep-day-picker", marker: app.navigationBars["Choose a day"])
                tapIfPresent(app.buttons["Done"])
            }
        }

        // Wearable (pushed) › Rename (sheet) › Find ring (full-screen cover).
        openTab("Today")
        waitFor(app.buttons["ringChip"]).tap()
        waitFor(app.staticTexts["Wearable"], "Wearable screen missing")
        backgroundAndReturn("wearable", marker: app.staticTexts["Wearable"])
        waitFor(app.buttons["Rename ring"]).tap()
        backgroundAndReturn("rename", marker: app.textFields["Ring name"])
        tapIfPresent(app.buttons["Cancel"])
        let find = app.buttons["Find ring"]
        scrollTo(find)
        if find.waitForExistence(timeout: 5) {
            find.tap()
            backgroundAndReturn("find-ring", marker: app.staticTexts["findRing.band"])
            tapIfPresent(app.buttons["Close"])
        }

        XCTAssertEqual(app.state, .runningForeground)
    }
}
