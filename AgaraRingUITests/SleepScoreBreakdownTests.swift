import XCTest

/// The score explains itself (item E-P2 of plan `asana-heart-bugs-2026-11-01`): on the Sleep tab's main-night hero,
/// "Why this score?" opens the components that were actually scored, with their points, and an "estimated" note when
/// the ring did not label the whole night.
///
/// Runs with `sleep_score_v2=on` — the shipped flag is off, and with it off the disclosure is hidden by design (the v1
/// scorer has no per-component model, so there is nothing honest to show).
final class SleepScoreBreakdownTests: AgaraUITestCase {

    private var v2Features: String { AgaraUITestCase.allFeatures + ",sleep_score_v2=on" }

    func testTheScoreShowsWhatItIsMadeOf() throws {
        try launch(features: v2Features)
        waitForConnected()
        openTab("Sleep")

        let toggle = waitFor(app.buttons["sleep.score.breakdown"], timeout: 30, "no breakdown disclosure under the hero")
        toggle.tap()

        for id in ["duration", "deep", "rem", "light"] {
            waitFor(element("sleep.score.component.\(id)"), timeout: 10,
                    "component '\(id)' missing from the breakdown")
        }
        attachScreenshot("sleep-breakdown-open")

        // A disclosure, not a one-way door.
        toggle.tap()
        XCTAssertFalse(element("sleep.score.component.duration").waitForExistence(timeout: 2),
                       "the breakdown should collapse")
    }

    /// A nap's page carries no score (owner 2026-11-04, option (a)) — so it must carry no breakdown either.
    func testANapPageOffersNoBreakdown() throws {
        try launch(portKey: "E2E_NAP_PORT", features: v2Features)
        waitForConnected()
        openTab("Sleep")
        guard app.buttons["sleep.hero.nap"].waitForExistence(timeout: 10) else {
            throw XCTSkip("this emulator has no nap session on the day")
        }
        XCTAssertFalse(element("sleep.score.breakdown").exists,
                       "a page with no score must not offer to explain one")
    }
}
