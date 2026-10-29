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

/// BUG-211's deterministic trigger, proved on real frames: **the same ring, re-flashed, is read again from the
/// beginning** — including a past day the app had already stored and would normally skip.
///
/// The protocol offers no cheaper signal: `df` has no count selector (a transfer runs from the requested record to
/// the end of the day, and the count header rides only on records sent), so a resume past the ring's last record is
/// byte-identical to a benign "nothing new" refresh. A changed `a1` firmware is the signal that a flash rewrote the
/// ring's history — and it is what the lab actually does.
///
/// A second emulator cannot stand in for the re-flash: the app keys its history ledger per port (`virtual:<port>`),
/// so another port is another ring. Hence the `fw` rig's control route (`POST /control/firmware`) changes what the
/// *same* ring reports, and the app is relaunched against it.
final class ReFlashedRingSyncTests: AgaraUITestCase {

    /// A past day is read in full on the first connection, then read **again** after the firmware changes.
    /// Without the invalidation the second pass skips it (it is `complete`), so this assertion is exactly the fix.
    func testAReFlashedRingIsReadAgainFromTheBeginning() throws {
        guard let logPath = ProcessInfo.processInfo.environment["E2E_FW_LOG"],
              let controlPort = ProcessInfo.processInfo.environment["E2E_FW_HTTP"] else {
            throw XCTSkip("needs the fw rig (tools/e2e_ios.sh starts it)")
        }

        try launch(portKey: "E2E_FW_PORT", extra: ["-startTab", "today"])
        waitForConnected()

        // The first connection reads the past days in full.
        eventually(timeout: 120, "day 1 was never read from record 1 on the first connection") {
            self.occurrences(of: "day 1 from position 1", in: logPath) >= 1
        }
        let before = occurrences(of: "day 1 from position 1", in: logPath)

        // Re-flash the same ring, then come back to it exactly as a user would: the app is closed and reopened.
        app.terminate()
        XCTAssertEqual(try setFirmware("00.13.01", port: controlPort), 200, "the control route refused the change")
        _ = try launch(portKey: "E2E_FW_PORT", extra: ["-startTab", "today"])
        waitForConnected()

        eventually(timeout: 120, "the re-flashed ring's day 1 was skipped — the ledger survived the flash") {
            self.occurrences(of: "day 1 from position 1", in: logPath) > before
        }
    }

    private func occurrences(of needle: String, in path: String) -> Int {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").filter { $0.contains(needle) }.count ?? 0
    }

    /// `POST /control/firmware?version=…` on the rig's test-only control route; returns the HTTP status.
    private func setFirmware(_ version: String, port: String) throws -> Int {
        var status = -1
        let done = expectation(description: "control route")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/control/firmware?version=\(version)")!)
        request.httpMethod = "POST"
        request.httpBody = Data()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return status
    }
}
