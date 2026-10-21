import XCTest

/// The Coach tab, release 1.1: the five-tab bar with Settings behind the gear, every state the tab can be in, the
/// cloud coach's consent sheet and its withdrawal, the quota pill, exactly three follow-ups, the data-based starter
/// prompts and the conversation history.
///
/// No ring emulator is needed: the coach's own screens read the app's store, and a turn is pinned to the scripted
/// provider (`-coachProvider offlineStub`) so nothing here touches a model or the network. The cloud states are forced
/// with `-coachState` (DEBUG only) because the real ones need an account, a used-up quota and a running turn.
final class CoachTabUITests: AgaraUITestCase {

    /// Flags this suite pins, so neither an earlier run's overrides nor a release default can change the result.
    private static let coachFeatures = "coach=on,coach_cloud=on,coach_history=on"

    /// The five tabs the bar must show, in order.
    private static let tabs = ["Today", "Vitals", "Activity", "Sleep", "Coach"]

    private func launchCoach(extra: [String], features: String = coachFeatures) {
        app.launchArguments = [
            "-noCoachMarks", "YES",
            "-acceptDisclaimer", "YES",
            "-seedDemo", "YES",
            "-forceOnboarding", "NO",
            "-features", features,
            "-AppleLanguages", "(en)",
        ] + extra
        app.launch()
        waitFor(app.tabBars.firstMatch, timeout: 90, "tabs never appeared")
    }

    private func openSettingsViaGear(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(app.buttons["settingsGear"], "the gear that opens Settings is missing", file: file, line: line).tap()
        waitFor(app.staticTexts["Settings"], timeout: 20, "Settings did not open from the gear", file: file, line: line)
    }

    private func openCoachSettings() {
        openSettingsViaGear()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "AI Coach")).firstMatch
        scrollTo(row)
        waitFor(row, "AI Coach row missing in Settings").tap()
        waitFor(element("coach.consent.state"), timeout: 20, "the cloud-consent row is missing in AI Coach settings")
    }

    // MARK: - 1. The tab bar and the gear

    func testFiveTabsWithSettingsBehindTheGear() {
        launchCoach(extra: [])

        // Five tabs, in order, and no iOS "More" fold:
        for tab in Self.tabs {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 20), "tab \(tab) missing")
        }
        XCTAssertFalse(app.tabBars.buttons["More"].exists, "six tabs would fold iOS into a More tab")
        XCTAssertFalse(app.tabBars.buttons["Settings"].exists, "Settings is behind the gear now, not a tab")
        XCTAssertEqual(app.tabBars.buttons.count, Self.tabs.count, "the bar must hold exactly five tabs")

        // Every tab's top bar carries the gear; Settings opens from each of them.
        for tab in Self.tabs {
            openTab(tab)
            openSettingsViaGear()
            goBack()
        }

        // Every route that used to live in the Settings tab is still reachable, Developer included (debug-only).
        openSettingsViaGear()
        for row in ["User Profile", "Privacy", "About"] {
            let cell = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
            scrollTo(cell)
            waitFor(cell, "Settings row \(row) missing").tap()
            waitFor(app.buttons["Back"], timeout: 20, "\(row) did not open")
            goBack()
        }
        XCTAssertTrue(app.staticTexts["Settings"].exists || app.buttons["Back"].exists)
    }

    func testDeveloperMenuIsStillReachableFromSettingsInDebug() {
        launchCoach(extra: ["-developerUnlocked", "YES"])
        openSettingsViaGear()
        let developer = app.buttons.matching(NSPredicate(format: "label == %@", "Developer")).firstMatch
        scrollTo(developer)
        waitFor(developer, "Developer row missing (debug build)").tap()
        waitFor(app.staticTexts["Developer"], timeout: 20, "Developer screen did not open")
    }

    // MARK: - 2. Every coach state is reachable

    /// Each state, with its headline and the action it offers. The copies are written out here on purpose: a UI test
    /// target cannot import the app module, and a copy change should fail this test rather than silently pass
    /// (they mirror `CoachCopy`, which is the source the lead catalogues into `brand.yaml`).
    private static let states: [(id: String, title: String, primary: String)] = [
        ("off", "AI Coach is off", "Turn on Coach"),
        ("signedOut", "Sign in to use the cloud coach", "Sign in"),
        ("unverified", "Verify your email", "Open account"),
        ("consent", "Your permission is needed", "Review and agree"),
        ("busy", "The coach is still answering", "Try again"),
        ("quota", "That's all for today", "Use the on-device coach"),
    ]

    func testEveryCoachStateIsReachable() {
        for state in Self.states {
            launchCoach(extra: ["-coachState", state.id,
                                "-coachQuotaRemaining", "0",
                                "-coachQuotaResetsAt", "2026-10-21T00:00:00Z",
                                "-coachBusy", "YES"])
            openTab("Coach")
            let card = element("coach.state.\(state.id)")
            waitFor(card, timeout: 20, "the \(state.id) card never appeared")
            XCTAssertTrue(anyElement(labelContains: state.title).exists,
                          "the \(state.id) card has no headline")
            XCTAssertEqual(waitFor(element("coach.state.primary"), "the \(state.id) card has no action").label,
                           state.primary, "wrong action offered for \(state.id)")
            app.terminate()
        }
    }

    func testOutOfQuotaNamesTheResetTime() {
        launchCoach(extra: ["-coachState", "quota", "-coachProvider", "agaraCloud",
                            "-coachQuotaRemaining", "0",
                            "-coachQuotaResetsAt", "2026-10-21T00:00:00Z"])
        openTab("Coach")
        waitFor(element("coach.state.quota"), timeout: 20, "the out-of-quota card never appeared")
        // "Your daily cloud questions reset 21 Oct 2026 at 00:00…" — the sentence carries the date the header sent.
        // Locale-agnostic: the card renders a DateFormatter date, which is "21 Oct 2026" in en_US and "21. Okt. 2026"
        // in de_DE, so assert on the DAY and the fact that a reset time is named at all.
        XCTAssertTrue(anyElement(labelContains: "21").exists,
                      "the card does not say which day the quota resets")
        XCTAssertTrue(anyElement(labelContains: "reset").exists,
                      "the card does not name a reset at all")
        XCTAssertTrue(anyElement(labelContains: "on-device coach").exists)
    }

    // MARK: - 3. Consent and withdrawal

    func testConsentSheetExplainsTheDisclosureAndRecordsAgreement() {
        launchCoach(extra: ["-coachState", "consent", "-coachOn", "YES"])
        openTab("Coach")
        waitFor(element("coach.state.primary"), "the consent card has no action").tap()
        waitFor(element("coach.consent.intro"), timeout: 20, "the consent sheet did not open")

        // The four facts 5.1.2(i) asks for: what leaves, to whom, what is kept, how to stop it.
        XCTAssertTrue(anyElement(labelContains: "age, sex, height and weight").exists, "what leaves the phone")
        XCTAssertTrue(anyElement(labelContains: "OpenCode").exists, "the third-party provider is not named")
        XCTAssertTrue(anyElement(labelContains: "in memory only").exists, "nothing-stored promise missing")
        XCTAssertTrue(anyElement(labelContains: "Withdraw").exists, "the withdrawal path is not explained")
        XCTAssertTrue(element("coach.consent.leaves").exists)
        XCTAssertTrue(element("coach.consent.provider").exists)
        XCTAssertTrue(element("coach.consent.stored").exists)

        waitFor(element("coach.consent.agree"), "no agree button").tap()

        // The agreement is recorded with the disclosure's version, and Settings shows it.
        openCoachSettings()
        XCTAssertEqual(element("coach.consent.state").label, "Agreed")

        // Withdrawal: the shared confirmation, then the record is gone and the coach is back on-device.
        let withdraw = element("coach.consent.withdraw")
        scrollTo(withdraw)
        waitFor(withdraw, "the withdraw button is missing").tap()
        let alert = app.alerts.firstMatch
        waitFor(alert, "withdrawing consent must ask first")
        XCTAssertTrue(alert.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "on-device")).firstMatch.exists,
            "the confirmation does not say the on-device coach keeps working")
        alert.buttons["Withdraw"].tap()
        eventually(timeout: 10, "consent was not withdrawn") {
            element("coach.consent.state").label == "Not given"
        }
        XCTAssertFalse(element("coach.consent.withdraw").exists, "nothing to withdraw once consent is gone")
    }

    // MARK: - 4. Ready: quota pill, starter prompts, three follow-ups, history

    func testReadyStateShowsQuotaPillStarterPromptsThreeFollowUpsAndHistory() {
        // The pill reports the CLOUD quota, so the test must select the cloud coach - with `offlineStub` the header
        // correctly says "nothing is sent" and there is no quota to report.
        launchCoach(extra: ["-coachOn", "YES", "-coachProvider", "agaraCloud",
                            "-coachQuotaRemaining", "24",
                            "-coachQuotaResetsAt", "2026-10-21T00:00:00Z"])
        openTab("Coach")

        // The pill is fed by the last response's X-Coach-Remaining-Day.
        let pill = waitFor(element("coach.quota"), timeout: 20, "the quota pill is missing")
        XCTAssertEqual(pill.label.contains("24") || pill.label.contains("24 left today"), true,
                       "pill reads: \(pill.label)")

        // The empty thread offers prompts built from the seeded data, not a fixed list.
        let starters = app.buttons.matching(identifier: "coach.starter")
        waitFor(starters.firstMatch, timeout: 20, "no starter prompts in the empty thread")
        XCTAssertGreaterThanOrEqual(starters.count, 2)
        let firstPrompt = starters.firstMatch.label

        starters.firstMatch.tap()

        // One answer, exactly three follow-ups (the scripted answer carries two; the third comes from the prompts).
        let chips = app.buttons.matching(identifier: "coach.chip")
        waitFor(chips.firstMatch, timeout: 60, "no answer / no follow-up chips")
        XCTAssertEqual(chips.count, 3, "an answer must show exactly three follow-ups")

        // History: start a fresh thread, then reopen the first one from the list.
        waitFor(app.buttons["New conversation"], "new-conversation button missing").tap()
        waitFor(element("coach.history"), "history button missing").tap()
        waitFor(app.staticTexts["Conversations"], timeout: 20, "the history sheet did not open")
        let past = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(firstPrompt.prefix(18)))).firstMatch
        waitFor(past, "the past conversation is not listed").tap()
        eventually(timeout: 20, "the reopened conversation shows no messages") {
            app.buttons.matching(identifier: "coach.chip").count == 3
        }
    }

    // MARK: - 5. Screenshots (light and dark)

    func testCoachScreensLight() { walkScreens(theme: "light") }
    func testCoachScreensDark() { walkScreens(theme: "dark") }

    /// Every coach screen, in the theme named by the test, as an attachment named `<theme>-NN-<screen>`. `scripts/`
    /// extracts them into `captures/coach-ui/` (see `scripts/coach_ui_shots.sh`).
    private func walkScreens(theme: String) {
        var frame = 0
        func snap(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))   // let glass and animations settle
            frame += 1
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "%@-%02d-%@", theme, frame, name)
            shot.lifetime = .keepAlways
            add(shot)
        }

        for (id, screen) in [("off", "state-off"), ("signedOut", "state-signed-out"),
                             ("unverified", "state-unverified"), ("consent", "state-consent"),
                             ("busy", "state-busy"), ("quota", "state-quota")] {
            launchCoach(extra: ["-theme", theme, "-coachState", id, "-coachProvider", "agaraCloud",
                                "-coachQuotaRemaining", "0",
                                "-coachQuotaResetsAt", "2026-10-21T00:00:00Z",
                                "-coachBusy", "YES"])
            openTab("Coach")
            waitFor(element("coach.state.\(id)"), timeout: 20, "\(id) card missing for the screenshot")
            snap(screen)
            app.terminate()
        }

        // The consent sheet itself.
        launchCoach(extra: ["-theme", theme, "-coachState", "consent", "-coachOn", "YES"])
        openTab("Coach")
        waitFor(element("coach.state.primary"), "consent card missing").tap()
        waitFor(element("coach.consent.intro"), timeout: 20, "consent sheet missing")
        snap("consent-sheet")
        app.terminate()

        // Ready: quota pill, starter prompts and the empty thread.
        launchCoach(extra: ["-theme", theme, "-coachOn", "YES", "-coachProvider", "agaraCloud",
                            "-coachQuotaRemaining", "24", "-coachQuotaResetsAt", "2026-10-21T00:00:00Z"])
        openTab("Coach")
        waitFor(element("coach.quota"), timeout: 20, "quota pill missing for the screenshot")
        snap("ready-empty")
        app.terminate()

        // A conversation: the answer bubble, its chart-less reply and exactly three follow-ups.
        launchCoach(extra: ["-theme", theme, "-coachOn", "YES", "-coachProvider", "offlineStub",
                            "-coachQuotaRemaining", "23"])
        openTab("Coach")
        let starters = app.buttons.matching(identifier: "coach.starter")
        if starters.firstMatch.waitForExistence(timeout: 20) { starters.firstMatch.tap() }
        _ = app.buttons.matching(identifier: "coach.chip").firstMatch.waitForExistence(timeout: 60)
        snap("answer-with-chips")
        app.terminate()
    }

    // MARK: - Helpers

    private func goBack() {
        for label in ["Back", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.exists && button.isHittable { button.tap(); return }
        }
        app.navigationBars.buttons.firstMatch.tap()
    }
}
