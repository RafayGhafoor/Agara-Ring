import XCTest

/// Agara Cloud, release 1.1: consent → sign up → verify your email → synced → delete account, against the in-process fake
/// backend (`-fakeCloud YES`, DEBUG only; there is no Firebase project and no server to reach). No ring emulator needed.
final class AgaraCloudFlowUITests: AgaraUITestCase {
    private func launchCloud(features: String = "agara_cloud=on", extra: [String] = []) {
        app.launchArguments = ["-noCoachMarks", "YES", "-acceptDisclaimer", "YES", "-seedDemo", "YES", "-forceOnboarding", "NO",
                               "-features", features, "-AppleLanguages", "(en)"] + extra
        app.launch()
        waitFor(app.buttons["Vitals"].exists ? app.buttons["Vitals"] : app.tabBars.buttons["Vitals"], timeout: 60)
        openTab("Settings")
    }

    /// REAL coach answer against STAGING: signs in, opens the Coach tab and lets the model answer with the synced data.
    /// Runs only with credentials (`TEST_RUNNER_AGARA_E2E_EMAIL/PASSWORD` + the staging tunnel on 127.0.0.1:18091):
    ///
    ///   ssh -N -L 18091:127.0.0.1:8091 hayden &
    ///   TEST_RUNNER_AGARA_E2E_EMAIL=… TEST_RUNNER_AGARA_E2E_PASSWORD=… \
    ///     xcodebuild test … -only-testing:AgaraRingUITests/AgaraCloudFlowUITests/testLiveCoachAnswer
    ///
    /// It attaches the answer and the trend answer, so a screenshot of a real turn exists instead of a scripted one.
    func testLiveCoachAnswer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let mail = env["AGARA_E2E_EMAIL"], let pass = env["AGARA_E2E_PASSWORD"] else {
            throw XCTSkip("no staging credentials in the environment")
        }
        launchCloud(extra: ["-cloudBaseUrl", "http://127.0.0.1:18091", "-coachProvider", "agaraCloud"])
        openCloudRow()
        if !element("cloud.syncNow").waitForExistence(timeout: 5) {
            let agree = element("cloud.consent.agree")
            scrollTo(agree)
            waitFor(agree).tap()
            let mode = element("cloud.mode")
            if mode.exists { let si = mode.buttons["Sign in"]; if si.exists { si.tap() } }
            let email = waitFor(element("cloud.email"), "email field missing")
            email.tap(); email.typeText(mail)
            let password = waitFor(element("cloud.password"))
            password.tap(); password.typeText(pass)
            let submit = element("cloud.submit")
            scrollTo(submit)
            waitFor(submit).tap()
        }
        waitFor(element("cloud.syncNow"), timeout: 90, "did not reach the signed-in screen")

        openTab("Coach")
        let composer = waitFor(app.textFields.firstMatch, timeout: 30, "the coach composer is missing")
        composer.tap()
        composer.typeText("How did I sleep last night, and what should I do today?")
        app.buttons["coach.send"].firstMatch.tap()

        // A real turn: the model calls tools on this device, then answers with the numbers it read.
        let chips = app.buttons.matching(identifier: "coach.chip")
        waitFor(chips.firstMatch, timeout: 150, "the coach did not answer")
        attachScreenshot("live-1-answer-with-data")

        // A second turn asks for a trend, which must come back with a chart.
        composer.tap()
        composer.typeText("How has my sleep trended this week?")
        app.buttons["coach.send"].firstMatch.tap()
        eventually(timeout: 150, "no chart in the trend answer") {
            self.app.otherElements.matching(identifier: "coach.chart").firstMatch.exists
        }
        attachScreenshot("live-2-trend-with-chart")
    }

    private func openCloudRow() {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Agara Cloud")).firstMatch
        scrollTo(row)
        waitFor(row, "Agara Cloud row missing (flag agara_cloud)").tap()
        waitFor(element("cloud.screen"), timeout: 20, "cloud screen did not open")
    }

    func testConsentSignUpVerifySyncAndDeleteAccount() {
        launchCloud(extra: ["-fakeCloud", "YES", "-fakeCloudSeedBlocks", "3", "-fakeCloudVerifyAfter", "3"])
        openCloudRow()

        // 1. Consent comes first: what is uploaded, where, how to delete.
        waitFor(element("cloud.consent"), "consent screen missing")
        XCTAssertTrue(anyElement(labelContains: "What is uploaded").exists || anyElement(labelContains: "WHAT IS UPLOADED").exists)
        XCTAssertTrue(anyElement(labelContains: "Delete account").exists)
        attachScreenshot("cloud-1-consent")
        let agree = element("cloud.consent.agree")
        scrollTo(agree)
        waitFor(agree).tap()

        // 2. Sign up.
        let email = waitFor(element("cloud.email"), "email field missing")
        email.tap()
        email.typeText("reader@example.com")
        let password = waitFor(element("cloud.password"))
        password.tap()
        password.typeText("password1")
        attachScreenshot("cloud-2-signup")
        let submit = element("cloud.submit")
        scrollTo(submit)
        waitFor(submit).tap()

        // 3. Verify your email: resend is on a cooldown, the screen polls by itself.
        waitFor(element("cloud.verify.check"), timeout: 20, "verify screen missing")
        XCTAssertTrue(anyElement(labelContains: "reader@example.com").exists)
        XCTAssertTrue(anyElement(labelContains: "Resend in").exists, "resend starts on a cooldown")
        attachScreenshot("cloud-3-verify")

        // 4. The fake backend marks the address verified 3 s after the mail; the auto-poll moves on and the first sync runs.
        waitFor(element("cloud.syncNow"), timeout: 40, "did not reach the signed-in screen after verification")
        eventually(timeout: 40, "the first sync did not finish") { element("cloud.lastSync").label != "Not yet" }
        eventually(timeout: 20, "3 of 3 blocks not uploaded") { self.element("cloud.counts").label.contains("3 / 3") }
        XCTAssertTrue(anyElement(labelContains: "reader@example.com").exists)
        attachScreenshot("cloud-4-synced")

        // 5. Sync now works again; sign-out is a confirmation; delete account is destructive and explains itself.
        let again = element("cloud.syncNow")
        scrollTo(again)
        waitFor(again).tap()
        let delete = element("cloud.deleteAccount")
        scrollTo(delete)
        delete.tap()
        let alert = app.alerts.firstMatch
        waitFor(alert, "delete confirmation missing")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "permanently deletes")).firstMatch.exists)
        attachScreenshot("cloud-5-delete")
        alert.buttons["Delete account"].tap()

        // 6. Back to the start: consent again, local data untouched (the app stayed usable throughout).
        waitFor(element("cloud.consent"), timeout: 30, "consent screen should return after deleting the account")
    }

    func testTheAppNeverRequiresAnAccountAndTheRowIsHiddenByDefault() {
        launchCloud(features: "agara_cloud=off")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Agara Cloud")).firstMatch
        scrollTo(row, maxSwipes: 4)
        XCTAssertFalse(row.exists, "the shipped defaults keep the cloud off")
        XCTAssertTrue(app.tabBars.buttons["Vitals"].exists)
    }

    func testAnUnconfiguredBuildSaysSoWithoutTouchingTheNetwork() {
        launchCloud()      // flag on, but no -fakeCloud: this build has no Firebase key
        openCloudRow()
        waitFor(element("cloud.notConfigured"), "not-configured card missing")
    }

    /// REAL Firebase + STAGING (release 1.1 device test). Runs only when the runner has credentials:
    ///   TEST_RUNNER_AGARA_E2E_EMAIL / TEST_RUNNER_AGARA_E2E_PASSWORD, staging tunnel on 127.0.0.1:18091
    ///   (`scripts/phone_cloud_e2e.py prepare` + `seed`). Signs in, waits for the first sync to pull, then deletes the account.
    func testStagingSignInPullAndDeleteAccount() throws {
        let env = ProcessInfo.processInfo.environment
        guard let mail = env["AGARA_E2E_EMAIL"], let pass = env["AGARA_E2E_PASSWORD"] else {
            throw XCTSkip("no staging credentials in the environment")
        }
        launchCloud(extra: ["-cloudBaseUrl", "http://127.0.0.1:18091"])
        openCloudRow()
        if !element("cloud.syncNow").waitForExistence(timeout: 5) {   // a session from an earlier run stays signed in
            let agree = element("cloud.consent.agree")
            scrollTo(agree)
            waitFor(agree).tap()
            let mode = element("cloud.mode")
            if mode.exists { let si = mode.buttons["Sign in"]; if si.exists { si.tap() } }
            let email = waitFor(element("cloud.email"), "email field missing")
            email.tap(); email.typeText(mail)
            let password = waitFor(element("cloud.password"))
            password.tap(); password.typeText(pass)
            let submit = element("cloud.submit")
            scrollTo(submit)
            waitFor(submit).tap()
        }
        waitFor(element("cloud.syncNow"), timeout: 60, "did not reach the signed-in screen")
        eventually(timeout: 60, "the first sync did not finish") { element("cloud.lastSync").label != "Not yet" }
        NSLog("AGARA_E2E lastSync=\(element("cloud.lastSync").label) counts=\(element("cloud.counts").exists ? element("cloud.counts").label : "-")")
        attachScreenshot("staging-1-synced")
        let del = element("cloud.deleteAccount")
        eventually(timeout: 30, "delete button never became tappable") { self.scrollTo(del); return del.exists && del.isHittable }
        del.tap()
        let alert = app.alerts.firstMatch
        waitFor(alert, "delete confirmation missing")
        alert.buttons["Delete account"].tap()
        waitFor(element("cloud.consent"), timeout: 60, "did not return to the consent screen after deleting the account")
        attachScreenshot("staging-2-deleted")
    }
}
