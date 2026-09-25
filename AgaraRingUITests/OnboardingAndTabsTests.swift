import XCTest

/// Onboarding (pair → name the ring → skip the profile → goals → start), the four tabs rendering emulator
/// data, and a relaunch keeping that data.
final class OnboardingAndTabsTests: AgaraUITestCase {

    /// The real first-run path: the virtual ring is "found" by the pairing screen's scan
    /// (`-virtualRingOnPair YES`), so the "Name your ring" step appears exactly as it does over Bluetooth.
    func testOnboardingPairNameAndSkip() throws {
        try launch(extra: ["-forceOnboarding", "YES", "-forcePairingUI", "YES", "-virtualRingOnPair", "YES"])
        // A previous interrupted run may have left the flow mid-way: walk back to the welcome screen.
        let getStarted = app.buttons["Get started"]
        var backs = 0
        while !getStarted.waitForExistence(timeout: 4) && app.buttons["Back"].exists && backs < 6 {
            app.buttons["Back"].tap()
            backs += 1
        }
        waitFor(getStarted, "welcome screen missing").tap()

        waitFor(app.buttons["Connect my ring"], "pairing screen missing").tap()
        waitFor(app.staticTexts["Name your ring"], timeout: 30, "naming step never appeared")
        let field = app.textFields["Ring name"]
        waitFor(field).tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText("Onboard Ring")
        let saveName = app.buttons["Save name"]
        if !saveName.isHittable { app.swipeUp() }
        saveName.tap()

        // Profile: skip it.
        waitFor(app.buttons["Skip"], "profile step missing").tap()
        // Goals: keep the recommended targets.
        let saveGoals = app.buttons["Save goals"]
        waitFor(saveGoals, "goals step missing")
        scrollTo(saveGoals)
        saveGoals.tap()
        // Baseline explainer → into the app.
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start using'")).firstMatch
        waitFor(start, "baseline step missing")
        scrollTo(start)
        start.tap()

        waitFor(app.tabBars.buttons["Vitals"].exists ? app.tabBars.buttons["Vitals"] : app.buttons["Today"],
                "main tabs not shown after onboarding")
        waitForConnected()
        // The name chosen during pairing is the ring's name.
        eventually(timeout: 20, "ring name not applied (chip: \(app.buttons["ringChip"].label))") {
            app.buttons["ringChip"].label.contains("Onboard Ring")
        }
    }

    func testFourTabsShowEmulatorData() throws {
        try launch()
        waitForConnected()

        openTab("Today")
        attachScreenshot("tab-today")
        eventually(timeout: 60, "Today shows no step count") {
            anyElement(labelContains: "step").exists
        }

        openTab("Vitals")
        waitFor(app.staticTexts["Vitals"])
        eventually(timeout: 60, "Vitals heart-rate card has no data") {
            text(containing: "HEART RATE").exists && !text(containing: "No data").exists
        }
        attachScreenshot("tab-vitals")

        openTab("Activity")
        eventually(timeout: 30, "Activity shows no steps") { anyElement(labelContains: "step").exists }
        attachScreenshot("tab-activity")

        openTab("Sleep")
        assertSleepDayShowsNight()
        attachScreenshot("tab-sleep")
    }

    /// The emulator serves 8 nights (`--sleep-nights 8`), so last night is on the Day view.
    func testSleepDayViewShowsTheNight() throws {
        try launch(extra: ["-startSleepRange", "day"])
        waitForConnected()
        openTab("Sleep")
        assertSleepDayShowsNight()
    }

    private func assertSleepDayShowsNight() {
        eventually(timeout: 90, "Sleep day view shows no night") {
            text(containing: "Night timeline").exists && !text(containing: "No sleep recorded").exists
        }
        // A duration like "7h 12m" in the hero.
        let duration = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #".*\d+h.*"#)).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 10), "no sleep duration on the day view")
    }

    /// Data survives a relaunch: the second launch points at a port nobody listens on, so everything on
    /// screen must come from the store.
    func testRelaunchKeepsData() throws {
        try launch()
        waitForConnected()
        openTab("Vitals")
        eventually(timeout: 60, "no vitals before relaunch") { text(containing: "HEART RATE").exists }
        app.terminate()

        app.launchArguments = ["-virtualRing", "9799", "-noCoachMarks", "YES", "-features", Self.allFeatures,
                               "-historyWindowDays", "90"]
        app.launch()
        openTab("Vitals")
        eventually(timeout: 30, "vitals gone after relaunch") {
            text(containing: "HEART RATE").exists && !text(containing: "No data").exists
        }
        openTab("Sleep")
        assertSleepDayShowsNight()
    }
}
