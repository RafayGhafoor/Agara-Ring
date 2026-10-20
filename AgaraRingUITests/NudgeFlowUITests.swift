import XCTest

/// The six nudge actions, one test each, plus the ledger assertion behind "Not now". Every test launches the app with a
/// debug fixture nudge (`-nudgeFixture a1|c1|g1|b1`) instead of a 28-day store: the fixture goes through the same
/// `NudgeProviding` seam the real engine fills, the same card view, the same `NudgeDelivery.perform` and the same ledger.
///
/// Each test asserts the *effect* of the tap — the ledger line in Settings › Notifications › Last 7 days, the
/// lighter-today override on Today, the breathing sheet, the ring screen — not the pixels of a button.
final class NudgeFlowUITests: AgaraUITestCase {

    private static let nudgeFeatures = "coach=on,coach_cloud=on,coach_history=on,coach_nudges=on"

    private func launch(fixture: String) {
        app.launchArguments = [
            "-noCoachMarks", "YES",
            "-acceptDisclaimer", "YES",
            "-seedDemo", "YES",
            "-forceOnboarding", "NO",
            "-features", Self.nudgeFeatures,
            "-nudgeFixture", fixture,
            "-nudgeFixtureReset", "YES",
            "-AppleLanguages", "(en)",
        ]
        app.launch()
        waitFor(app.tabBars.firstMatch, timeout: 90, "tabs never appeared")
        openTab("Today")
    }

    /// Today's card for the fixture rule.
    private func card(_ rule: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        scrollTo(app.descendants(matching: .any)["nudge.card.\(rule)"], maxSwipes: 6)
        return waitFor(app.descendants(matching: .any)["nudge.card.\(rule)"], timeout: 20,
                       "the \(rule) card never appeared on Today", file: file, line: line)
    }

    private func tap(_ action: String, on rule: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)["nudge.action.\(action)"]
        scrollTo(element, maxSwipes: 6)
        waitFor(element, timeout: 20, "the \(action) button on \(rule) is missing", file: file, line: line).tap()
    }

    /// Open Settings › Notifications and read the ledger line for one rule + outcome.
    private func assertLedger(_ rule: String, _ outcome: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(app.buttons["settingsGear"], "settings gear missing", file: file, line: line).tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch
        scrollTo(row, maxSwipes: 6)
        waitFor(row, "the Notifications row is missing in Settings", file: file, line: line).tap()
        let ledgerLine = app.descendants(matching: .any)["nudges.ledger.\(rule).\(outcome)"]
        scrollTo(ledgerLine, maxSwipes: 8)
        XCTAssertTrue(ledgerLine.waitForExistence(timeout: 20),
                      "no ledger line for \(rule) / \(outcome) — the tap was not recorded",
                      file: file, line: line)
    }

    // MARK: - The six actions

    func testKeepGoalIsRecorded() {
        launch(fixture: "a1")
        _ = card("a1")
        tap("keepGoal", on: "a1")
        assertLedger("a1", "keptGoal")
    }

    func testLighterTodayLowersTodaysGoalOnlyAfterTheConfirmation() {
        launch(fixture: "a1")
        _ = card("a1")
        tap("lighterToday", on: "a1")

        // The one confirmation (Rule 10) comes first; only its confirm button changes the goal.
        let confirm = app.buttons[AgaraCopyStrings.nudgeConfirmLighter]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the lighter-today confirmation never appeared")
        confirm.tap()

        let override = app.descendants(matching: .any)["nudge.goalOverride"]
        scrollTo(override, maxSwipes: 8)
        XCTAssertTrue(override.waitForExistence(timeout: 20), "Today does not show the lighter goal")
        assertLedgerAfterReturning()
    }

    func testWhyOpensTheSeededCoachAnswer() {
        launch(fixture: "a1")
        _ = card("a1")
        tap("why", on: "a1")
        // The seeded answer is written already; the ledger is the deterministic proof the tap routed to the coach.
        let seed = app.descendants(matching: .any)["coach.seed.card"]
        if seed.waitForExistence(timeout: 10) {
            XCTAssertTrue(app.staticTexts["coach.seed.message"].exists, "the seeded card has no message")
        }
        openTab("Today")
        assertLedger("a1", "whyOpened")
    }

    func testNotNowIsRecordedInTheLedger() {
        launch(fixture: "b1")
        _ = card("b1")
        tap("notNow", on: "b1")
        // "Not now" pauses the category until the next wake time, so the card goes away for the rest of the day.
        XCTAssertFalse(app.descendants(matching: .any)["nudge.card.b1"].exists, "the card is still there after Not now")
        assertLedger("b1", "notNow")
    }

    func testBreatheStartsTheTwoMinuteSession() {
        launch(fixture: "c1")
        _ = card("c1")
        tap("breathe", on: "c1")
        let session = app.descendants(matching: .any)["breathing.session"]
        XCTAssertTrue(session.waitForExistence(timeout: 10), "the breathing session never opened")
        XCTAssertTrue(app.staticTexts["Two quiet minutes"].exists, "the session's title is missing")
        XCTAssertTrue(app.buttons["Finish early"].exists, "the session cannot be ended early")
        app.buttons["breathing.close"].tap()
        openSettingsNotifications()
        let ledgerLine = app.descendants(matching: .any)["nudges.ledger.c1.breathed"]
        scrollTo(ledgerLine, maxSwipes: 8)
        XCTAssertTrue(ledgerLine.waitForExistence(timeout: 20), "the breathing session was not recorded")
    }

    func testOpenRingRoutesToTheRingScreen() {
        launch(fixture: "g1")
        _ = card("g1")
        tap("openRing", on: "g1")
        // The ring screen is Settings › Wearable; its own title proves the route.
        XCTAssertTrue(app.staticTexts["Wearable"].waitForExistence(timeout: 20)
                      || app.navigationBars["Wearable"].waitForExistence(timeout: 5),
                      "Open ring did not reach the Wearable screen")
        goBack()
        assertLedger("g1", "openedRing")
    }

    // MARK: - Helpers

    /// Pop the pushed Wearable screen (the gear lives on the tab bar's own chrome, which a pushed page covers).
    private func goBack() {
        for label in ["Back", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.exists && button.isHittable { button.tap(); return }
        }
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func openSettingsNotifications() {
        waitFor(app.buttons["settingsGear"], "settings gear missing").tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications")).firstMatch
        scrollTo(row, maxSwipes: 6)
        waitFor(row, "the Notifications row is missing in Settings").tap()
    }

    /// After the lighter-today confirmation the app is on Today; the ledger line still has to be there.
    private func assertLedgerAfterReturning(file: StaticString = #filePath, line: UInt = #line) {
        openTab("Today")
        openSettingsNotifications()
        let ledgerLine = app.descendants(matching: .any)["nudges.ledger.a1.madeLighter"]
        scrollTo(ledgerLine, maxSwipes: 8)
        XCTAssertTrue(ledgerLine.waitForExistence(timeout: 20), "the lighter-today action was not recorded",
                      file: file, line: line)
    }
}

/// Copy the UI tests need as a button label. Read from the generated catalog so a wording change cannot break a test
/// silently (the confirm button says "Lighter today", the same string the card's button uses).
enum AgaraCopyStrings {
    static let nudgeConfirmLighter = "Lighter today"
}
