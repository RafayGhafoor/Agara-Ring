import XCTest

/// Owner feedback before release (2026-09-26, `docs/process/plans/consistency-framework.md`), on the real app
/// against the naps emulator (`--sleep-sessions 2`: a night plus a 40-minute nap at 13:00 each day):
/// 1. Today's sleep tile shows the day's **main sleep** (this branch's BUG-205 rule) with the nap on its own
///    "+ nap 40 m" line beside it.
/// 2. A reconnect asks the ring only for day 0, from the record after the last one stored (`SyncPlan`) — read
///    from the emulator's own log of the DF requests it served.
final class SleepDayAndSyncPlanTests: AgaraUITestCase {

    private func napLog() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["E2E_NAP_LOG"], !path.isEmpty else {
            throw XCTSkip("E2E_NAP_LOG not set — run through tools/e2e_ios.sh")
        }
        return path
    }

    /// The emulator log as lines (its status line rewrites itself with `\r`).
    private func logLines(_ path: String) -> [String] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
    }

    /// The lines logged since the last "app connected".
    private func linesOfLastConnection(_ path: String) -> [String] {
        let lines = logLines(path)
        guard let start = lines.lastIndex(where: { $0.contains("app connected") }) else { return [] }
        return Array(lines[start...])
    }

    private static func minutes(ofLogDuration line: String) -> Int? {
        // "… day 0: sleep 00:05–06:40 (6:35:00) deep=…"
        guard let range = line.range(of: #"\((\d+):(\d\d):\d\d\)"#, options: .regularExpression) else { return nil }
        let parts = line[range].dropFirst().dropLast().split(separator: ":").compactMap { Int($0) }
        return parts.count == 3 ? parts[0] * 60 + parts[1] : nil
    }

    private static func format(_ minutes: Int) -> String {   // SleepFormat.duration
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    func testTodayShowsNightPlusNapAndReconnectAsksOnlyForToday() throws {
        let log = try napLog()
        // Determinism, not a fix for anything: pin the tab this test asserts on instead of inheriting the tab an
        // earlier test left in use — a test must not depend on remembered UI state. (The ring chip lives in
        // `AppHeader`, mounted above the `TabView` for every tab, so it is not tab-dependent.)
        try launch(portKey: "E2E_NAP_PORT", extra: ["-startTab", "today"])
        waitForConnected()
        waitForSyncIdle()
        openTab("Today")

        let nap = element("today.sleep.nap")
        scrollTo(nap)
        eventually(timeout: 60, "no nap line on the Today sleep tile") { nap.exists && nap.label == "+ nap 40 m" }
        // This branch shows the **main sleep** in the tile's headline (BUG-205): the bar and the score below it
        // describe that one session, so the nap is not added to it. 1.1 (`agara/1.1-cloud`) shows the whole day
        // — night + naps — on purpose; see `docs/apps/parity-matrix.md` › "1.0 vs 1.1 — the sleep number
        // differs on purpose". Change this assertion only with a decision to adopt that rule here.
        let night = linesOfLastConnection(log).first { $0.contains("day 0: sleep") }.flatMap(Self.minutes(ofLogDuration:))
        let total = element("today.sleep.total")
        XCTAssertTrue(total.exists, "no sleep total on the Today tile")
        if let night {
            XCTAssertEqual(total.label, Self.format(night), "Today's headline is the main night (\(night) min)")
        }
        attachScreenshot("today-sleep-night-plus-nap")

        // Reconnect (relaunch = a new connection to the same ring): only day 0, from the resume position.
        app.terminate()
        try launch(portKey: "E2E_NAP_PORT", extra: ["-startTab", "today"])
        waitForConnected()
        waitForSyncIdle()
        var requests: [String] = []
        eventually(timeout: 60, "the reconnect never asked for day 0's records") {
            requests = linesOfLastConnection(log).filter { $0.contains("from position") }
            return !requests.isEmpty
        }
        let others = linesOfLastConnection(log).filter { $0.range(of: #"day [1-9]\d*[: ]"#, options: .regularExpression) != nil }
        XCTAssertEqual(requests.count, 1, "one DF request per reconnect: \(requests)")
        XCTAssertTrue(others.isEmpty, "past days were asked again: \(others)")
        let position = requests.first.flatMap { line -> Int? in
            guard let r = line.range(of: #"day 0 from position (\d+)"#, options: .regularExpression) else { return nil }
            return Int(line[r].split(separator: " ").last ?? "")
        }
        XCTAssertNotNil(position, "not a day-0 request: \(requests)")
        XCTAssertGreaterThan(position ?? 0, 1, "day 0 must resume after the last stored record: \(requests)")
        let attachment = XCTAttachment(string: linesOfLastConnection(log).joined(separator: "\n"))
        attachment.name = "emulator-log-reconnect"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Still the night + nap after the refresh.
        openTab("Today")
        scrollTo(nap)
        XCTAssertTrue(nap.waitForExistence(timeout: 20))
        attachScreenshot("today-sleep-after-reconnect")
    }
}
