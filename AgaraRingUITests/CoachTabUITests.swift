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
        // The Coach tab's bar has no gear (owner 2026-10-23): Settings is reached from any other tab.
        if !app.buttons["settingsGear"].waitForExistence(timeout: 3) { openTab("Today") }
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
        let quotaArgs = ["-coachOn", "YES", "-coachProvider", "agaraCloud",
                         "-coachQuotaRemaining", "24", "-coachQuotaResetsAt", "2026-10-21T00:00:00Z"]

        // While the cloud answers, the header's status line carries the count (fed by X-Coach-Remaining-Day).
        launchCoach(extra: quotaArgs + ["-coachGateOpen", "YES"])
        openTab("Coach")
        let pill = waitFor(element("coach.quota"), timeout: 20, "the quota is missing while the cloud answers")
        XCTAssertTrue(pill.label.contains("24"), "status reads: \(pill.label)")
        app.terminate()

        // Cloud chosen but not ready (no account here): the phone answers, so the line says so and shows NO count —
        // "On this phone · 24 left" mixed the two coaches.
        launchCoach(extra: quotaArgs)
        openTab("Coach")
        let promise = waitFor(element("coach.promise"), timeout: 20, "the on-device status line is missing")
        XCTAssertFalse(promise.label.contains("24"), "an on-device status must not carry the cloud count: \(promise.label)")
        XCTAssertFalse(element("coach.quota").exists, "no cloud quota while the phone answers")
        app.terminate()

        // The conversation runs on the scripted provider: the on-device model is a real model call in the simulator
        // and failed there ("GenerationError -1"), which made this test flaky rather than wrong.
        launchCoach(extra: ["-coachOn", "YES", "-coachProvider", "offlineStub"])
        openTab("Coach")

        // The empty thread offers prompts built from the seeded data, not a fixed list.
        let starters = app.buttons.matching(identifier: "coach.starter")
        waitFor(starters.firstMatch, timeout: 20, "no starter prompts in the empty thread")
        XCTAssertGreaterThanOrEqual(starters.count, 2)
        let firstPrompt = starters.firstMatch.label

        starters.firstMatch.tap()

        // One answer, exactly three follow-ups (the scripted answer carries two; the third comes from the prompts).
        // The answer now lands at its FIRST line (reading order), so a long answer's chips start below the fold and
        // SwiftUI drops fully-clipped views from the accessibility tree: scroll to them before asserting.
        let chips = app.buttons.matching(identifier: "coach.chip")
        for _ in 0..<5 where !chips.firstMatch.exists { app.swipeUp() }
        waitFor(chips.firstMatch, timeout: 60, "no answer / no follow-up chips")
        XCTAssertEqual(chips.count, 3, "an answer must show exactly three follow-ups")

        // History: start a fresh thread, then reopen the first one from the list.
        waitFor(app.buttons["New conversation"], "new-conversation button missing").tap()
        waitFor(element("coach.history"), "history button missing").tap()
        waitFor(app.staticTexts["Conversations"], timeout: 20, "the history sheet did not open")
        // Rows are newest-first, so the first one is the empty "New chat" this test just created. A conversation's title
        // is the answer's title, NOT the prompt, so pick positionally: the oldest row is the chat that was actually had.
        // Rows are newest-first, so the first is the empty "New chat" this test just created; the last is the chat that
        // was actually had. Tap the title (a `List` row's own identifier never reaches the accessibility tree).
        let titles = app.staticTexts.matching(identifier: "coach.history.title")
        waitFor(titles.firstMatch, timeout: 20, "the past conversation is not listed (\(titles.count) titles)")
        XCTAssertGreaterThanOrEqual(titles.count, 2, "history lists only \(titles.count) conversation(s)")
        titles.element(boundBy: titles.count - 1).tap()
        // The reopened thread also starts at its first line, so scroll to its chips before counting them.
        for _ in 0..<5 where chips.count == 0 { app.swipeUp() }
        eventually(timeout: 20, "the reopened conversation shows no messages") { chips.count == 3 }
    }

    // MARK: - 5. Screenshots (light and dark)

    /// Jimmy's 1.1.0 (3) (2026-10-22): with the ring still "Connecting…", the Coach tab's header crushed the title column
    /// to "● (" over a lone "C". Same state here — the longest status line, a ring that never connects — on the narrowest
    /// simulator: the title and the status line must keep readable widths.
    func testHeaderKeepsTheCoachTitleWhileTheRingConnects() {
        launchCoach(extra: ["-coachOn", "YES", "-coachProvider", "agaraCloud", "-coachGateOpen", "YES",
                            "-coachQuotaRemaining", "24", "-virtualRing", "9799"])
        openTab("Coach")
        let title = waitFor(app.staticTexts["Coach"].firstMatch, timeout: 20, "the Coach title is missing")
        let status = waitFor(element("coach.quota"), timeout: 20, "the status line is missing")
        attachScreenshot("coach-header-connecting")
        XCTAssertGreaterThanOrEqual(title.frame.width, 50, "the title was squeezed to \(title.frame.width) pt")
        XCTAssertGreaterThanOrEqual(status.frame.width, 90, "the status line was squeezed to \(status.frame.width) pt")
        XCTAssertLessThanOrEqual(title.frame.maxX, app.buttons["coach.history"].frame.minX + 1, "the title runs under the buttons")
        // Owner 2026-10-23: the Coach tab's bar carries no ring chip and no gear; the other tabs keep both.
        XCTAssertFalse(app.buttons["ringChip"].exists, "the ring chip is hidden on the Coach tab")
        XCTAssertFalse(app.buttons["settingsGear"].exists, "the gear is hidden on the Coach tab")
        openTab("Today")
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10), "Today keeps the gear")
        XCTAssertTrue(app.buttons["ringChip"].exists, "Today keeps the ring chip")
    }

    /// Owner 2026-10-22: if an update skipped the cloud coach consent, the header line itself must lead to it.
    func testTheHeaderLineOpensTheSkippedConsent() {
        launchCoach(extra: ["-coachOn", "YES", "-coachProvider", "agaraCloud", "-coachState", "consent"])
        openTab("Coach")
        let line = waitFor(element("coach.consentLine"), timeout: 20, "the 'tap to agree' line is missing")
        XCTAssertTrue(line.label.contains("tap to agree"), "line reads: \(line.label)")
        attachScreenshot("coach-header-consent-line")
        line.tap()
        waitFor(element("coach.consent.intro"), timeout: 10, "tapping the line did not open the consent sheet")
    }

    func testCoachScreensLight() { walkScreens(theme: "light") }
    func testCoachScreensDark() { walkScreens(theme: "dark") }

    /// Every coach screen, in the theme named by the test, as an attachment named `<theme>-NN-<screen>`. `scripts/`
    /// extracts them into `captures/coach-ui/` (see `scripts/coach_ui_shots.sh`).
    // MARK: - 6. The demo set (one run, the screens a reviewer needs)

    /// The coach's demo screenshots: asking, an answer with a chart, its follow-ups, history, the privacy sheet, the
    /// consent sheet, and the answer again in dark. Attachments are named `demo-NN-…`; export them with
    /// `scripts/coach_demo_shots.sh`, which also wipes the old set. The answer is the DEBUG `-coachDemoChart` seed — the
    /// same `coach_response` JSON a cloud answer carries, through the production renderer.
    func testDemoScreenshots() {
        var frame = 0
        func snap(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            frame += 1
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = String(format: "demo-%02d-%@", frame, name)
            shot.lifetime = .keepAlways
            add(shot)
        }
        // `-coachGateOpen` (DEBUG): the cloud coach is the one that answers, so the header says so. Without an account
        // the effective coach is the on-device one, and the header correctly says "On this phone".
        let cloud = ["-coachOn", "YES", "-coachProvider", "agaraCloud", "-coachGateOpen", "YES",
                     "-coachQuotaRemaining", "24", "-coachQuotaResetsAt", "2026-10-23T00:00:00Z"]

        // 1. Ask: the briefing, then three questions built from the user's own numbers.
        launchCoach(extra: ["-theme", "light"] + cloud)
        openTab("Coach")
        waitFor(app.buttons.matching(identifier: "coach.starter").firstMatch, timeout: 20, "no starter prompts")
        snap("ask")
        app.terminate()

        // 2–5. A conversation.
        launchCoach(extra: ["-theme", "light", "-coachDemoChart", "YES"] + cloud)
        openTab("Coach")
        waitFor(element("coach.chart"), timeout: 30, "the answer's chart is missing")
        snap("answer-with-chart")
        let chips = app.buttons.matching(identifier: "coach.chip")
        // Drag from the prose above the chart: a synthetic swipe from the screen centre starts on the chart's overlay.
        for _ in 0..<3 where !(chips.element(boundBy: 2).exists && chips.element(boundBy: 2).isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        }
        snap("follow-ups")
        waitFor(element("coach.history"), "history button missing").tap()
        waitFor(app.staticTexts["Conversations"], timeout: 20, "the history sheet did not open")
        snap("history")
        app.buttons["Done"].tap()
        waitFor(element("coach.quota"), timeout: 20, "the status line is missing").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        snap("usage-and-privacy")
        app.terminate()

        // 6. Before the first cloud question: the third-party disclosure.
        launchCoach(extra: ["-theme", "light", "-coachState", "consent", "-coachOn", "YES"])
        openTab("Coach")
        waitFor(element("coach.state.primary"), "consent card missing").tap()
        waitFor(element("coach.consent.intro"), timeout: 20, "consent sheet missing")
        snap("consent")
        app.terminate()

        // 7–8. Dark.
        launchCoach(extra: ["-theme", "dark", "-coachDemoChart", "YES"] + cloud)
        openTab("Coach")
        waitFor(element("coach.chart"), timeout: 30, "the answer's chart is missing (dark)")
        snap("answer-with-chart-dark")
        app.terminate()
        launchCoach(extra: ["-theme", "dark"] + cloud)
        openTab("Coach")
        waitFor(app.buttons.matching(identifier: "coach.starter").firstMatch, timeout: 20, "no starter prompts (dark)")
        snap("ask-dark")
    }

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
        launchCoach(extra: ["-theme", theme, "-coachOn", "YES", "-coachProvider", "agaraCloud", "-coachGateOpen", "YES",
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
