import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class SleepServiceTests: XCTestCase {
    private func night(_ dayOffset: Int) -> Date {
        let base = TestSupport.day(dayOffset)
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: base) ?? base
    }

    /// A fixed "now" at noon today — past the 4 AM day-reference flip — so `.day`-range
    /// assertions don't depend on the wall-clock time the suite happens to run at.
    private func noonToday() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: TestSupport.day(0)) ?? Date()
    }

    func testStaleSleepHiddenFromLatest() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-3), stages: Array(repeating: .light, count: 60), into: context)
        XCTAssertNil(SleepService.latestSleep(context: context), "a 3-day-old session is stale")
    }

    /// BUG-210 — Android keys the Today tile strictly on the *reference night*, so a night the ring was not
    /// worn reads "No sleep recorded". iOS showed the night before last instead, which is a different answer
    /// to the same stored data (and one day-wide, so it looks like a bug rather than a policy).
    func testAnUnwornNightReadsAsNoSleepRatherThanTheNightBeforeLast() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        // One night stored under the 1st; it is now 09:00 on the 2nd and the ring was not worn overnight.
        TestSupport.insertSleep(nightStart: calendar.date(from: DateComponents(year: 2026, month: 10, day: 1,
                                                                            hour: 0, minute: 20))!,
                                stages: Array(repeating: .light, count: 60), into: context)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!
        XCTAssertNil(SleepService.latestSleepDay(context: context, now: now))
        XCTAssertNil(SleepService.latestSleep(context: context, now: now))
        // The same night is still what the 1st's own day view holds.
        XCTAssertNotNil(SleepService.sleepDay(for: calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!,
                                              context: context))
    }

    func testRecentSleepShown() throws {
        try TestSupport.withClock("2026-10-30T09:00:00") {
        let context = try TestSupport.makeContext()
        // A night that began at 02:00 today is keyed to today's waking day — last night.
        let earlyToday = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: TestSupport.day(0))!
        TestSupport.insertSleep(nightStart: earlyToday, stages: Array(repeating: .deep, count: 90), into: context)
        let latest = SleepService.latestSleep(context: context)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.deepMinutes, 90)
        }
    }

    func testStaleSleepHiddenFromToday() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-4), stages: Array(repeating: .light, count: 30), into: context)
        let summary = MetricsService.buildTodaySummary(context: context)
        // BUG-210: a 4-day-old night is not last night — it is only reachable as the captioned
        // "last recorded" state, and the Today hero sentence never quotes it.
        XCTAssertNil(summary.lastNight)
        guard case .lastRecorded = summary.sleepTile.kind else {
            return XCTFail("expected the captioned last-recorded state, got \(summary.sleepTile.kind)")
        }
        XCTAssertTrue(summary.sleepTile.caption?.hasPrefix("Last recorded: ") == true)
    }

    func testSummaryStageMinutes() throws {
        let context = try TestSupport.makeContext()
        let stages = Array(repeating: SleepStage.light, count: 40) + Array(repeating: .deep, count: 20) + Array(repeating: .awake, count: 5)
        let session = TestSupport.insertSleep(nightStart: night(0), stages: stages, into: context)
        let summary = SleepService.summary(for: session, context: context)
        XCTAssertEqual(summary.lightMinutes, 40)
        XCTAssertEqual(summary.deepMinutes, 20)
        XCTAssertEqual(summary.awakeMinutes, 5)
    }

    /// BUG-206 — the coach's sleep trends answer with the same numbers the card shows: one point per
    /// **day** (a night and its nap are one day, not two nights) and only the visible source (the paired
    /// ring's nights — never the emulator's or another ring's). Android's tool answered `3 / 233` for this
    /// fixture; iOS's `sleepRange` + `SleepInsights` answer `2 / 350`, which is the card's answer.
    func testTheCoachSleepTrendsCountDaysNotSessionsAndIgnoreOtherSources() throws {
        let context = try TestSupport.makeContext()
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: TestSupport.day(-1))
        let day2 = calendar.startOfDay(for: TestSupport.day(0))
        func night(_ start: Date, minutes: Int, source: String) {
            let session = SleepSession(date: calendar.wakingDay(forSleepStart: start, end: start.addingTimeInterval(Double(minutes) * 60)),
                                       startAt: start, endAt: start.addingTimeInterval(Double(minutes) * 60),
                                       totalMinutes: minutes, sourceAddress: source)
            context.insert(session)
            for index in 0..<minutes {
                context.insert(SleepStageBlock(sessionId: session.id,
                                               startAt: start.addingTimeInterval(Double(index) * 60),
                                               startMinute: index, durationMinutes: 1, stage: .light,
                                               sourceAddress: source))
            }
        }
        let ring = "00000000-0000-4000-8000-00000000000B"
        // Day 1: one 300-minute night.
        night(calendar.date(bySettingHour: 2, minute: 0, second: 0, of: day1)!, minutes: 300, source: ring)
        // …and a second source's shorter night on the same day, which the policy must not mix in.
        night(calendar.date(bySettingHour: 3, minute: 0, second: 0, of: day1)!, minutes: 100, source: "another-source")
        // Day 2: a 360-minute night and a 40-minute afternoon nap — one day, not two nights.
        night(calendar.date(bySettingHour: 23, minute: 50, second: 0, of: day1)!, minutes: 360, source: ring)
        night(calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day2)!, minutes: 40, source: ring)
        try context.save()

        let summary = SleepService.sleepRange(.week, context: context)
        let valid = SleepInsights.validSessions(summary.sessions)
        XCTAssertEqual(valid.count, 3, "the second source is not visible at all")
        XCTAssertEqual(SleepInsights.collapseByDay(valid).count, 2, "two days, not three nights")
        XCTAssertEqual(SleepInsights.averageDuration(valid), 350)
    }

    func testExpectedNightsPerRange() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(0), stages: Array(repeating: .light, count: 60), into: context)
        XCTAssertEqual(SleepService.sleepRange(.day, context: context).expectedNights, 1)
        XCTAssertEqual(SleepService.sleepRange(.week, context: context).expectedNights, 7)
        XCTAssertEqual(SleepService.sleepRange(.month, context: context).expectedNights, 30)
        XCTAssertEqual(SleepService.sleepRange(.year, context: context).expectedNights, 365)
    }

    func testWeekRangeWindowsSessions() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(0), stages: Array(repeating: .light, count: 60), into: context)
        TestSupport.insertSleep(nightStart: night(-2), stages: Array(repeating: .deep, count: 60), into: context)
        TestSupport.insertSleep(nightStart: night(-20), stages: Array(repeating: .light, count: 60), into: context)
        let week = SleepService.sleepRange(.week, context: context)
        XCTAssertEqual(week.sessions.count, 2, "only sessions within the 7-night window")
    }

    func testBlocksOnlyForDayRange() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-1), stages: Array(repeating: .light, count: 60), into: context)
        // Pin `now` to noon today so the Day window resolves to today regardless of when the suite runs
        // (before 4 AM the reference night is yesterday, which would exclude tonight's session).
        XCTAssertFalse(SleepService.sleepRange(.day, context: context, now: noonToday()).sessions.first?.blocks.isEmpty ?? true)
        XCTAssertTrue(SleepService.sleepRange(.week, context: context).sessions.first?.blocks.isEmpty ?? false)
    }

    /// The Day view used to show the last recorded sleep even when "last night"
    /// had no data — so a 3-day-old session masqueraded as last night. Now the
    /// day anchor is "today's reference night", so an old session is excluded.
    func testDayRangeShowsNoDataWhenLastNightMissing() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: night(-3), stages: Array(repeating: .light, count: 60), into: context)
        XCTAssertTrue(SleepService.sleepRange(.day, context: context).sessions.isEmpty)
        // But the week view still surfaces it.
        XCTAssertFalse(SleepService.sleepRange(.week, context: context).sessions.isEmpty)
    }

    func testDayReferenceNightFlipsAt4AM() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let at3am = cal.date(bySettingHour: 3, minute: 0, second: 0, of: today)!
        let at4am = cal.date(bySettingHour: 4, minute: 0, second: 0, of: today)!
        XCTAssertEqual(SleepService.dayReferenceNight(now: at3am), yesterday, "before 4 AM, still last night")
        XCTAssertEqual(SleepService.dayReferenceNight(now: at4am), today, "from 4 AM, flip to today")
    }

    /// BUG-207 — the boundary is the vendor app's **20:00**, not 19:00 (`SleepPrecisionData.setPresicionDate`),
    /// and a session that ends on a later date belongs to the morning it ended on whatever its start hour.
    func testWakingDayFollowsTheVendorBoundaryAndTheEndDate() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        // Small-hours sleep (2 AM) belongs to today's morning.
        let at2am = cal.date(bySettingHour: 2, minute: 0, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at2am), today, "2 AM is last night, stays on today")

        // A daytime nap (1 PM) stays on today — the whole point of moving the boundary off noon.
        let at1pm = cal.date(bySettingHour: 13, minute: 0, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at1pm), today, "afternoon nap stays on today")

        // 7:30 PM → 7:55 PM is an evening doze, not the next morning: the boundary is 20:00, as in the vendor
        // app. At 19 it was filed under tomorrow and surfaced as "+ nap 25 m" on the wrong day.
        let at730pm = cal.date(bySettingHour: 19, minute: 30, second: 0, of: today)!
        let at755pm = cal.date(bySettingHour: 19, minute: 55, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at730pm), today, "before 8 PM stays on today")
        XCTAssertEqual(cal.wakingDay(forSleepStart: at730pm, end: at755pm), today, "and its end is the same date")
        // 8:10 PM on the same date rolls to tomorrow's waking morning.
        let at810pm = cal.date(bySettingHour: 20, minute: 10, second: 0, of: today)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at810pm), tomorrow, "from 8 PM, sleep rolls to next morning")
        // A night that crosses midnight belongs to the morning it ended on, at any start hour.
        let at1030pm = cal.date(bySettingHour: 22, minute: 30, second: 0, of: today)!
        let at605am = cal.date(bySettingHour: 6, minute: 5, second: 0, of: tomorrow)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at1030pm, end: at605am), tomorrow)
        let at730pmNextDay = cal.date(bySettingHour: 7, minute: 30, second: 0, of: tomorrow)!
        XCTAssertEqual(cal.wakingDay(forSleepStart: at730pm, end: at730pmNextDay), tomorrow,
                       "the end date wins even for a 19:00-hour start that crosses midnight")
    }

    func testCrossMidnightSleepMerging() throws {
        let context = try TestSupport.makeContext()
        
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        
        // Use the subscriber directly to persist the sleep timeline packets synchronously:
        let subscriber = EventPersistenceSubscriber(context: context)
        
        // 1. A packet starting at 11:30 PM yesterday (June 22)
        let start1 = cal.date(bySettingHour: 23, minute: 30, second: 0, of: yesterday)!
        subscriber.persist(.sleepTimeline(timestamp: start1, stages: Array(repeating: SleepStage.light, count: 15)))
        
        // 2. A packet starting at 12:15 AM today (June 23)
        let start2 = cal.date(bySettingHour: 0, minute: 15, second: 0, of: today)!
        subscriber.persist(.sleepTimeline(timestamp: start2, stages: Array(repeating: SleepStage.deep, count: 15)))
        
        // There should be only ONE unified session for today
        let sessions = SleepRepository.sessions(context: context)
        XCTAssertEqual(sessions.count, 1)
        
        guard let session = sessions.first else {
            XCTFail("No session was created")
            return
        }
        
        // Verify that the session is dated today (waking morning)
        XCTAssertEqual(cal.startOfDay(for: session.date), today)
        
        // Check that blocks from both packets are present
        let blocks = SleepRepository.blocks(sessionId: session.id, context: context)
        XCTAssertTrue(blocks.contains { $0.startAt == start1 })
        XCTAssertTrue(blocks.contains { $0.startAt == start2 })
    }

    func testMigrateSplitSleepSessions() throws {
        // BUG-213: the sessions are dated "today", and `latestSleep` filters against the clock — before 07:00
        // local, a night that ends at 07:00 is still in the future and this read came back empty.
        try TestSupport.withClock("2026-10-30T09:00:00") {
            let context = try TestSupport.makeContext()
            // The migration is UserDefaults-gated; clear the flag so it runs in this test.
            UserDefaults.standard.removeObject(forKey: "sleepMidnightMerge.v1")
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

            // Create duplicate sessions like the ones in the bug:
            // Session 1: pre-midnight chunk dated yesterday (duration 45m, start 23:15, end 00:00)
            let start = cal.date(bySettingHour: 23, minute: 15, second: 0, of: yesterday)!
            let end1 = cal.date(bySettingHour: 0, minute: 0, second: 0, of: today)!
            let session1 = SleepSession(date: yesterday, startAt: start, endAt: end1, totalMinutes: 45)
            context.insert(session1)
            context.insert(SleepStageBlock(sessionId: session1.id, startAt: start, startMinute: 0, durationMinutes: 45, stage: .light))

            // Session 2: full night dated today (duration 7h 45m, start 23:15, end 07:00)
            let end2 = cal.date(bySettingHour: 7, minute: 0, second: 0, of: today)!
            let session2 = SleepSession(date: today, startAt: start, endAt: end2, totalMinutes: 465)
            context.insert(session2)
            context.insert(SleepStageBlock(sessionId: session2.id, startAt: start, startMinute: 0, durationMinutes: 465, stage: .deep))

            try context.save()

            // Assert they both exist initially
            XCTAssertEqual(try context.fetch(FetchDescriptor<SleepSession>()).count, 2)

            SleepService.migrateSplitSleepSessionsIfNeeded(context: context)

            // Only one session should remain, and it should be the 465-minute one (7h 45m)
            let sessions = try context.fetch(FetchDescriptor<SleepSession>())
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions.first?.totalMinutes, 465)
            XCTAssertEqual(SleepService.latestSleep(context: context)?.session.totalMinutes, 465)

            // The orphaned block for the deleted session should be cleaned up
            let blocks = try context.fetch(FetchDescriptor<SleepStageBlock>())
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?.sessionId, session2.id)
        }
    }

    func testMigrateTieBreakKeepsRicherSession() throws {
        let context = try TestSupport.makeContext()
        UserDefaults.standard.removeObject(forKey: "sleepMidnightMerge.v1")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 1, minute: 0, second: 0, of: today)!

        // Two sessions on the same waking day with EQUAL totalMinutes — the tie-break should keep
        // the one with more stage blocks (the fuller picture), not an arbitrary UUID winner.
        let sparse = SleepSession(date: today, startAt: start, endAt: start, totalMinutes: 400)
        context.insert(sparse)
        context.insert(SleepStageBlock(sessionId: sparse.id, startAt: start, startMinute: 0, durationMinutes: 400, stage: .light))

        let rich = SleepSession(date: today, startAt: start, endAt: start, totalMinutes: 400)
        context.insert(rich)
        for i in 0..<4 {
            let s = cal.date(byAdding: .minute, value: i * 100, to: start)!
            context.insert(SleepStageBlock(sessionId: rich.id, startAt: s, startMinute: i * 100, durationMinutes: 100, stage: .deep))
        }
        try context.save()

        SleepService.migrateSplitSleepSessionsIfNeeded(context: context)

        let sessions = try context.fetch(FetchDescriptor<SleepSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, rich.id, "tie on totalMinutes should keep the session with more blocks")
    }

    // MARK: - Sleep-session segmentation (issue #59)

    /// Build a detached `SleepStageBlock` for the pure `segment` tests. `segment` only
    /// reads `startAt`/`durationMinutes`, so `sessionId`/`startMinute` are placeholders.
    private func block(_ start: Date, minutes: Int, stage: SleepStage = .light) -> SleepStageBlock {
        SleepStageBlock(sessionId: UUID(), startAt: start, startMinute: 0, durationMinutes: minutes, stage: stage)
    }

    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let base = TestSupport.day(dayOffset)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    // 1. SleepSegmentation.segment — pure, no context

    func testSegmentEmptyReturnsEmpty() {
        XCTAssertTrue(SleepSegmentation.segment([]).isEmpty)
    }

    func testSegmentContiguousBlocksStayOneGroup() {
        // Block2 starts exactly when block1 ends (00:00 + 30m = 00:30) -> zero gap -> one group.
        let b1 = block(at(0, 0), minutes: 30)
        let b2 = block(at(0, 30), minutes: 30)
        let groups = SleepSegmentation.segment([b1, b2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testSegmentLargeGapSplitsIntoTwoGroups() {
        // Block1 [00:00, 60m] ends 01:00; block2 starts 14:00 -> ~13h gap >= 60m -> two groups.
        let b1 = block(at(0, 0), minutes: 60)
        let b2 = block(at(14, 0), minutes: 30)
        let groups = SleepSegmentation.segment([b1, b2])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertEqual(groups[1].count, 1)
    }

    func testSegmentShortAwakeningStaysOneGroup() {
        // Block1 [23:00, 120m] ends 01:00; block2 starts 01:30 -> 30m gap < 60m -> one group.
        let b1 = block(at(23, 0, dayOffset: -1), minutes: 120)
        let b2 = block(at(1, 30), minutes: 60)
        let groups = SleepSegmentation.segment([b1, b2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testSegmentThreeSleepsSplitIntoThreeGroupsInOrder() {
        let b1 = block(at(1, 0), minutes: 60)     // ends 02:00
        let b2 = block(at(9, 0), minutes: 30)     // gap 7h -> split; ends 09:30
        let b3 = block(at(15, 0), minutes: 30)    // gap ~5.5h -> split
        let groups = SleepSegmentation.segment([b1, b2, b3])
        XCTAssertEqual(groups.count, 3)
        // Chronological order preserved.
        XCTAssertEqual(groups[0].first?.startAt, b1.startAt)
        XCTAssertEqual(groups[1].first?.startAt, b2.startAt)
        XCTAssertEqual(groups[2].first?.startAt, b3.startAt)
    }

    func testSegmentUnsortedInputStillGroupsCorrectly() {
        let bNight1 = block(at(23, 0, dayOffset: -1), minutes: 60)  // ends 00:00
        let bNight2 = block(at(0, 0), minutes: 60)                  // contiguous with night1
        let bNap = block(at(14, 0), minutes: 30)                    // >60m gap -> own group
        // Pass out of chronological order.
        let groups = SleepSegmentation.segment([bNap, bNight2, bNight1])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2, "the two contiguous night blocks group together")
        XCTAssertEqual(groups[0].first?.startAt, bNight1.startAt, "groups come out sorted")
        XCTAssertEqual(groups[1].count, 1)
        XCTAssertEqual(groups[1].first?.startAt, bNap.startAt)
    }

    // 2. SleepService.reconcileWakingDay — in-memory context

    /// The seeded day and each segment's expected bounds, returned by `seedNightPlusNapSession`.
    private struct NightNapSeed {
        let day: Date
        let nightStart: Date
        let nightEnd: Date
        let napStart: Date
        let napEnd: Date
    }

    /// Insert ONE session whose blocks form a night run + a nap run separated by a >60m
    /// gap under a single row, then reconcile the waking day. Returns the (day, expected bounds).
    @discardableResult
    private func seedNightPlusNapSession(into context: ModelContext) -> NightNapSeed {
        let day = TestSupport.day(0)
        let nightStart = at(1, 0)                       // 01:00
        let napStart = at(14, 0)                        // 14:00, >60m after the night ends
        let session = SleepSession(date: day, startAt: nightStart, endAt: at(15, 0), totalMinutes: 0)
        context.insert(session)
        // Night: 3 contiguous 60-min blocks -> 01:00..04:00
        for i in 0..<3 {
            let s = Calendar.current.date(byAdding: .minute, value: i * 60, to: nightStart)!
            context.insert(SleepStageBlock(sessionId: session.id, startAt: s, startMinute: i * 60, durationMinutes: 60, stage: .deep))
        }
        // Nap: 2 contiguous 30-min blocks -> 14:00..15:00
        for i in 0..<2 {
            let s = Calendar.current.date(byAdding: .minute, value: i * 30, to: napStart)!
            context.insert(SleepStageBlock(sessionId: session.id, startAt: s, startMinute: i * 30, durationMinutes: 30, stage: .light))
        }
        try? context.save()
        let nightEnd = Calendar.current.date(byAdding: .minute, value: 180, to: nightStart)!  // 04:00
        let napEnd = Calendar.current.date(byAdding: .minute, value: 60, to: napStart)!        // 15:00
        return NightNapSeed(day: day, nightStart: nightStart, nightEnd: nightEnd, napStart: napStart, napEnd: napEnd)
    }

    private func sessions(on day: Date, in context: ModelContext) -> [SleepSession] {
        let cal = Calendar.current
        return ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { cal.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.startAt < $1.startAt }
    }

    func testReconcileSplitsNightAndNapIntoTwoSessions() throws {
        let context = try TestSupport.makeContext()
        let seed = seedNightPlusNapSession(into: context)

        SleepService.reconcileWakingDay(dateKey: seed.day, context: context)

        let rows = sessions(on: seed.day, in: context)
        XCTAssertEqual(rows.count, 2, "night + nap separated by a >60m gap split into two rows")

        let night = rows[0]
        let nap = rows[1]

        // Each row's blocks all belong to it, and the first block of each is rebased to minute 0.
        for row in rows {
            let blocks = SleepRepository.blocks(sessionId: row.id, context: context)
            XCTAssertFalse(blocks.isEmpty)
            XCTAssertTrue(blocks.allSatisfy { $0.sessionId == row.id })
            XCTAssertEqual(blocks.map { $0.startMinute }.min(), 0, "first block of each session rebased to startMinute 0")
        }

        // Bounds match each segment's first block start / last block end.
        XCTAssertEqual(night.startAt, seed.nightStart)
        XCTAssertEqual(night.endAt, seed.nightEnd)
        XCTAssertEqual(nap.startAt, seed.napStart)
        XCTAssertEqual(nap.endAt, seed.napEnd)

        // Own spans, not one merged ~14h span.
        XCTAssertEqual(night.totalMinutes, 180, "night span 01:00..04:00")
        XCTAssertEqual(nap.totalMinutes, 60, "nap span 14:00..15:00")
    }

    func testReconcileIsIdempotent() throws {
        let context = try TestSupport.makeContext()
        let seed = seedNightPlusNapSession(into: context)

        SleepService.reconcileWakingDay(dateKey: seed.day, context: context)
        let first = sessions(on: seed.day, in: context)
        XCTAssertEqual(first.count, 2)

        SleepService.reconcileWakingDay(dateKey: seed.day, context: context)
        let second = sessions(on: seed.day, in: context)
        XCTAssertEqual(second.count, 2, "re-running does not churn into 3+ or collapse to 1")
        XCTAssertEqual(second[0].startAt, seed.nightStart)
        XCTAssertEqual(second[0].endAt, seed.nightEnd)
        XCTAssertEqual(second[1].startAt, seed.napStart)
        XCTAssertEqual(second[1].endAt, seed.napEnd)
    }

    func testReconcileSingleContiguousNightStaysOneSession() throws {
        let context = try TestSupport.makeContext()
        let day = TestSupport.day(0)
        let start = at(1, 0)
        let session = SleepSession(date: day, startAt: start, endAt: at(7, 0), totalMinutes: 0)
        context.insert(session)
        // 6 contiguous 60-min blocks: 01:00..07:00, no gap >= 60m.
        for i in 0..<6 {
            let s = Calendar.current.date(byAdding: .minute, value: i * 60, to: start)!
            context.insert(SleepStageBlock(sessionId: session.id, startAt: s, startMinute: i * 60, durationMinutes: 60, stage: .light))
        }
        try? context.save()

        SleepService.reconcileWakingDay(dateKey: day, context: context)

        let rows = sessions(on: day, in: context)
        XCTAssertEqual(rows.count, 1, "a single contiguous night must not spuriously split")
        XCTAssertEqual(rows.first?.totalMinutes, 360, "01:00..07:00 span")
    }

    // 3. SleepService.migrateSleepSessionSegmentsIfNeeded

    func testMigrateSleepSessionSegmentsSplitsLegacyMergedRow() throws {
        let context = try TestSupport.makeContext()
        let key = "sleepSessionSegment.v1"
        // Capture and reset the gate so the migration runs; restore global state afterwards.
        let priorGate = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if priorGate { UserDefaults.standard.set(true, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Seed a legacy merged row: a night + a nap both under ONE session, separated by a >60m gap.
        seedNightPlusNapSession(into: context)
        let day = TestSupport.day(0)
        XCTAssertEqual(sessions(on: day, in: context).count, 1, "starts as one merged row")

        SleepService.migrateSleepSessionSegmentsIfNeeded(context: context)

        XCTAssertEqual(sessions(on: day, in: context).count, 2, "migration re-segmented the merged row into night + nap")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key), "gate is set true after the one-time pass")
    }

    // 4. Identity stability + change-gating (regression cover for the pre-merge review fixes)

    private func sleepTimelineUpdateCount(in context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<DerivedUpdateRow>())) ?? [])
            .filter { $0.kind == "sleep_timeline" }
            .count
    }

    /// A nap that syncs before the night it precedes lands under the day's earliest (container)
    /// row, exactly as `persistSleepTimeline` would attach it. Reconcile must keep that row's
    /// identity on the nap segment and spin the night into a fresh row — not flip the id onto the
    /// night (which positional, sort-by-startAt matching used to do, misattributing anything keyed
    /// to the SleepSession.id).
    func testReconcileKeepsSessionIdentityWhenNightSyncsAfterNap() throws {
        let context = try TestSupport.makeContext()
        let day = TestSupport.day(0)

        // Nap synced first: a single row at 14:00–15:00.
        let napStart = at(14, 0)
        let napRow = SleepSession(date: day, startAt: napStart, endAt: at(15, 0), totalMinutes: 60)
        context.insert(napRow)
        let napId = napRow.id
        for i in 0..<2 {
            let s = Calendar.current.date(byAdding: .minute, value: i * 30, to: napStart)!
            context.insert(SleepStageBlock(sessionId: napId, startAt: s, startMinute: i * 30, durationMinutes: 30, stage: .light))
        }
        // The night arrives later and attaches to that container row, like `persistSleepTimeline`.
        let nightStart = at(1, 0)
        for i in 0..<3 {
            let s = Calendar.current.date(byAdding: .minute, value: i * 60, to: nightStart)!
            context.insert(SleepStageBlock(sessionId: napId, startAt: s, startMinute: 0, durationMinutes: 60, stage: .deep))
        }
        try? context.save()

        SleepService.reconcileWakingDay(dateKey: day, context: context)

        let rows = sessions(on: day, in: context)   // sorted by startAt
        XCTAssertEqual(rows.count, 2)
        let night = rows[0]
        let nap = rows[1]
        XCTAssertEqual(nap.id, napId, "the pre-existing row keeps its id on the overlapping nap segment")
        XCTAssertNotEqual(night.id, napId, "the night gets a fresh row rather than stealing the nap's id")
        XCTAssertEqual(nap.startAt, napStart)
        XCTAssertEqual(night.startAt, nightStart)
    }

    /// Re-syncing an unchanged day must not spam the audit table: the second reconcile touches no
    /// bounds and re-points no block, so it emits zero new `DerivedUpdateRow`s.
    func testReconcileEmitsNoChangeSignalOnUnchangedResync() throws {
        let context = try TestSupport.makeContext()
        let seed = seedNightPlusNapSession(into: context)

        SleepService.reconcileWakingDay(dateKey: seed.day, context: context)
        let afterFirst = sleepTimelineUpdateCount(in: context)
        XCTAssertGreaterThan(afterFirst, 0, "the first reconcile splits the day and signals the change")

        SleepService.reconcileWakingDay(dateKey: seed.day, context: context)
        XCTAssertEqual(sleepTimelineUpdateCount(in: context), afterFirst, "an unchanged re-sync is a true no-op")
    }
}
