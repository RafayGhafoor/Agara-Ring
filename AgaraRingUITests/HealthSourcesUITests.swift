import XCTest

/// App Review 1.4.1: the citations must be easy to find. Vitals → "Sources & references" (the last row of the list)
/// opens the full screen; a metric detail shows "Where these ranges come from" with an "All sources" link.
/// Needs no ring: seeded demo data. Set `TEST_RUNNER_SOURCES_SHOT_DIR=<dir>` to also save PNGs of each screen.
final class HealthSourcesUITests: AgaraUITestCase {

    private func launchDemo(_ extra: [String] = []) {
        launchWithoutRing(extra: ["-seedDemo", "YES", "-forceOnboarding", "NO", "-startTab", "vitals"] + extra)
    }

    private func save(_ name: String) {
        attachScreenshot(name)
        guard let dir = ProcessInfo.processInfo.environment["SOURCES_SHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testVitalsFooterOpensSourcesScreen() {
        launchDemo()
        openTab("Vitals")
        let footer = element("vitals.sources")
        scrollTo(footer, maxSwipes: 20)
        waitFor(footer, "Vitals has no Sources & references row")
        save("vitals-footer")
        footer.tap()
        waitFor(element("sources.screen"), "Sources & references screen did not open")
        XCTAssertTrue(app.staticTexts["Sources & references"].exists)
        XCTAssertTrue(element("sources.row.hr_aha_resting").exists, "first heart-rate source missing")
        save("sources-screen")
        let sleepRow = element("sources.row.sleep_ninds")
        scrollTo(sleepRow, maxSwipes: 12)
        XCTAssertTrue(sleepRow.exists, "sleep source missing")
        save("sources-screen-end")
    }

    func testMetricDetailFooterLinksToAllSources() {
        launchDemo(["-openMetric", "spo2"])
        let all = element("metric.sources")
        scrollTo(all, maxSwipes: 20)
        waitFor(all, "Blood oxygen detail has no sources footer")
        XCTAssertTrue(element("sources.footer.spo2_medlineplus").exists)
        save("metric-spo2-footer")
        all.tap()
        waitFor(element("sources.screen"), "All sources did not open the Sources screen")
    }
}
