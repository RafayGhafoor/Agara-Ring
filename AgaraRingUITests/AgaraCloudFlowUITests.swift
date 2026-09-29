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
}
