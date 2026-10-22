import XCTest

/// Owner feedback before release (2026-09-26, `docs/process/plans/consistency-framework.md`), on the real app
/// against the naps emulator (`--sleep-sessions 2`: a night plus a 40-minute nap at 13:00 each day):
/// 1. Today's sleep tile shows the day's total (night + nap) with a "Night … · nap 40m" breakdown line.
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
        try launch(portKey: "E2E_NAP_PORT")
        waitForConnected()
        waitForSyncIdle()
        openTab("Today")

        let nap = element("today.sleep.nap")
        scrollTo(nap)
        // The line under the total breaks it down (owner 2026-10-22): "Night 6h 45m · nap 40m" — it used to read
        // "+ nap 40 m", as if the nap were on top of the total that already included it.
        eventually(timeout: 60, "no night/nap breakdown on the Today sleep tile") {
            nap.exists && nap.label.hasPrefix("Night ") && nap.label.hasSuffix("· nap 40m")
        }
        // The headline is the night (as the emulator logged it) plus the nap.
        let night = linesOfLastConnection(log).first { $0.contains("day 0: sleep") }.flatMap(Self.minutes(ofLogDuration:))
        if let night {
            // Written out here rather than calling the app's formatter: the test should not trust the code under test.
            let h = night / 60, m = night % 60
            XCTAssertEqual(nap.label, "Night \(h > 0 ? "\(h)h \(m)m" : "\(m)m") · nap 40m",
                           "the breakdown names the night the emulator logged")
        }
        let total = element("today.sleep.total")
        XCTAssertTrue(total.exists, "no sleep total on the Today tile")
        if let night {
            XCTAssertEqual(total.label, Self.format(night + 40), "Today's total = night \(night) min + nap 40 min")
        }
        attachScreenshot("today-sleep-night-plus-nap")

        // Reconnect (relaunch = a new connection to the same ring): only day 0, from the resume position.
        app.terminate()
        try launch(portKey: "E2E_NAP_PORT")
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
