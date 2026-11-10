import XCTest

/// The EV40 Daily Tracker end to end (Rule 19): the card on Today, the eight checkboxes, the count, the completion
/// state, the collapsed card, the history and the read-only past day — and that a tick survives a relaunch.
///
/// No ring is needed: the checklist is the user's own content, which is exactly why this suite can run without an
/// emulator. Launched with a clean store by `tools/e2e_ios.sh` (it uninstalls first), so "today starts empty" is a real
/// assertion rather than an accident.
final class Ev40TrackerTests: AgaraUITestCase {
    private var shotDir: String? { ProcessInfo.processInfo.environment["EV40_SHOT_DIR"] }

    private func launch(reset: Bool = false) {
        // `-skipOnboarding YES` is the harness's own way past a clean install (minimal profile, **no** demo rows);
        // `-sampleData` no longer reaches Today, which is why this class sat on step 1 of 7 and every assertion failed
        // upstream of the thing it tests.
        app.launchArguments = ["-noCoachMarks", "YES", "-acceptDisclaimer", "YES", "-skipOnboarding", "YES",
                               "-features", "", "-AppleLanguages", "(en)"]
        if reset { app.launchArguments += ["-ev40Reset", "YES"] }
        app.launch()
        // This class builds its own launch, so it does not inherit `AgaraUITestCase.launch()`'s guard. Without this the
        // fresh-install notifications prompt blocks every element query and the failure reads as "ring chip missing"
        // (the skill's rule, and this class proved it by failing 0/3 without it).
        dismissSystemAlert()
        waitFor(app.buttons["Vitals"].exists ? app.buttons["Vitals"] : app.tabBars.buttons["Vitals"], timeout: 40)
    }

    /// Relaunch **without** `-sampleData`: that launch arg reloads the release sample set, and loading it wipes the store
    /// first (it is the "explore without ring" bootstrap). Keeping the data is the whole point of this launch, so the
    /// profile the first launch created is simply reused.
    private func relaunchKeepingData() {
        app.terminate()
        app.launchArguments = ["-noCoachMarks", "YES", "-acceptDisclaimer", "YES", "-skipOnboarding", "YES",
                               "-features", "", "-AppleLanguages", "(en)"]
        app.launch()
        // This class builds its own launch, so it does not inherit `AgaraUITestCase.launch()`'s guard. Without this the
        // fresh-install notifications prompt blocks every element query and the failure reads as "ring chip missing"
        // (the skill's rule, and this class proved it by failing 0/3 without it).
        dismissSystemAlert()
        waitFor(app.buttons["Vitals"].exists ? app.buttons["Vitals"] : app.tabBars.buttons["Vitals"], timeout: 40)
    }

    private func shot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = XCUIScreen.main.screenshot()
        if let shotDir {
            try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(shotDir)/\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openTracker() {
        let card = app.buttons["ev40.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the EV40 card is not at the top of Today")
        card.tap()
        waitFor(element("ev40.screen"), timeout: 15, "the tracker screen did not open")
    }

    private func toggle(_ discipline: String) {
        let row = element("ev40.toggle.\(discipline)")
        scrollTo(row)
        row.tap()
    }

    func testCardOpensTheTrackerAndThreeTicksShowThreeOfEight() {
        launch(reset: true)
        // The card is above the coach card: it exists before anything else on Today is scrolled into view.
        XCTAssertTrue(app.buttons["ev40.card"].waitForExistence(timeout: 20))
        XCTAssertTrue(anyElement(labelContains: "0/8").exists, "a fresh day starts empty")
        shot("today-card-empty")

        openTracker()
        for discipline in ["hydrate", "move", "fuel"] { toggle(discipline) }
        waitFor(element("ev40.progress"), timeout: 10, "the progress line never appeared")
        XCTAssertTrue(element("ev40.progress").label.contains("3 disciplines completed"),
                      "progress reads the live count: \(element("ev40.progress").label)")
        XCTAssertTrue(anyElement(labelContains: "3/8").exists)
        shot("tracker-3-of-8")
    }

    func testAllEightCompleteCollapsesTheCardAndKeepsTheHistory() {
        launch(reset: true)
        openTracker()
        for discipline in ["hydrate", "move", "grow", "fuel", "energize", "fastRelease", "documentShare", "rest"] {
            toggle(discipline)
        }
        XCTAssertTrue(element("ev40.complete").waitForExistence(timeout: 10), "the completion panel did not appear")
        shot("tracker-complete")

        // Back on Today the full card is gone and the one-line complete row is in its place (decision D6).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("ev40.card.complete").waitForExistence(timeout: 15), "the card did not collapse when complete")
        XCTAssertFalse(element("ev40.card.full").exists, "the full card must be replaced by the collapsed row")
        shot("today-card-complete")

        // The history lists today, and its day detail is read-only.
        element("ev40.card.complete").tap()
        let historyLink = element("ev40.historyLink")
        scrollTo(historyLink)
        historyLink.tap()
        waitFor(element("ev40.history"), timeout: 15, "the history screen did not open")
        XCTAssertTrue(anyElement(labelContains: "8/8").exists, "today's 8/8 row is missing from the history")
        shot("history")

        let today = element("ev40.history.row.\(ISO8601DateFormatter.ev40DayKey())")
        XCTAssertTrue(today.waitForExistence(timeout: 10), "today's history row is missing")
        today.tap()
        waitFor(element("ev40.day"), timeout: 15, "the past-day screen did not open")
        // Read-only (decision D4): the rows are not buttons on a past day. The absence only means something once the row
        // is known to be *rendered* — an empty screen satisfies "not a button" just as well (AGENTS Rule 19: an absence
        // assertion must first assert the surface exists).
        waitFor(element("ev40.toggle.hydrate"), timeout: 15, "the past day's rows did not render")
        XCTAssertFalse(app.buttons["ev40.toggle.hydrate"].exists, "a past day must not be editable")
        shot("day-detail")
    }

    /// The share sheet: the challenge eyebrow is on the tracker, the card renders, and the `ShareLink` exists.
    /// Surface first, then the toggle — a sheet that opens empty must not pass as "no share button".
    func testTheShareSheetRendersTheChallengeCard() {
        launch(reset: true)
        openTracker()
        toggle("hydrate")
        toggle("move")
        XCTAssertTrue(element("ev40.challengeDay").waitForExistence(timeout: 10),
                      "the challenge day line is missing on a ticked day")
        XCTAssertTrue(element("ev40.challengeDay").label.lowercased().contains("day 1 of"),
                      "day one of the challenge, got \(element("ev40.challengeDay").label)")

        app.buttons["ev40.shareButton"].tap()
        waitFor(element("ev40.shareSheet"), timeout: 15, "the share sheet did not open")
        shot("ev40-share-story")
        XCTAssertTrue(element("ev40.shareLink").waitForExistence(timeout: 20), "no ShareLink on the sheet")

        // Square is the sheet's other export; the preview must survive the switch.
        app.buttons["Square"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("ev40-share-square")
        XCTAssertTrue(element("ev40.shareLink").exists, "the ShareLink disappeared after switching format")
    }

    func testTicksSurviveARelaunch() {
        launch(reset: true)
        openTracker()
        toggle("hydrate")
        toggle("rest")
        waitFor(element("ev40.progress"), timeout: 10, "the progress line never appeared")
        XCTAssertTrue(element("ev40.progress").label.contains("2 disciplines completed"))

        relaunchKeepingData()
        XCTAssertTrue(app.buttons["ev40.card"].waitForExistence(timeout: 20), "the card is missing after a relaunch")
        XCTAssertTrue(anyElement(labelContains: "2/8").exists, "the ticks did not survive the relaunch")
    }
}

extension ISO8601DateFormatter {
    /// The day key the tracker uses (`yyyy-MM-dd`, local) for today — the history row's identifier.
    static func ev40DayKey(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
