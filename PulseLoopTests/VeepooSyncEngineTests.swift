import XCTest
@testable import PulseLoop

/// The per-day history loop's stall watchdog (workspace `docs/process/plans/android-history-watchdog.md`).
///
/// On a real ring a day's DF transfer outlasts a poll tick; the watchdog used to cut it at the first
/// tick. The same scenarios run in Android's `VeepooSyncEngineTest`.
@MainActor
final class VeepooSyncEngineTests: XCTestCase {

    private final class RecordingWriter: RingCommandWriter {
        var deviceIdentifier: String? { nil }
        /// The link's identity (a peripheral UUID on BLE) — sleep records are stamped with it.
        var source: String?
        var commands: [Data] = []
        var emitted: [RingDecodedEvent] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            commands.append(command)
            completion(.success(()))
        }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
        var connectionSource: String? { source }
        func asked(_ frame: Data) -> Bool { commands.contains(frame) }

        var heartRates: [Double] {
            emitted.compactMap {
                if case let .historyMeasurement(.heartRate, value, _) = $0 { return value }
                return nil
            }
        }
    }

    /// The decoder test's DF fixture (B1 09-11 10:05, five HR samples), split into part 1 / part 2.
    private let part1 = hex("df000001" + "b104090b0a05b20a0343000002c2019b0000b4053c4b605550")
    private let part2 = hex("df000002" + "b7042c5b6dffb8027453b907606162636400ffbe02b601c10114")
    private let sleepNoData = hex("e0000000" + String(repeating: "00", count: 16))

    /// Keeps the engine alive for the test — the writer is held weakly by the engine.
    private var writer = RecordingWriter()

    /// The evening the fixtures' records were captured; the pass's "today" is pinned to it so a record's
    /// date is the day the loop asked for (BUG-102) rather than the day the suite happens to run.
    static let fixtureDay = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!

    /// An authenticated engine whose day-0 sleep phase is done, so the DF read for day 0 is in flight.
    private func engineInDailyPhase() -> VeepooSyncEngine {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 2)
        engine.now = { Self.fixtureDay }
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        engine.handle(.unknown(commandId: 0xE0, raw: sleepNoData))
        XCTAssertTrue(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0)))
        return engine
    }

    private func frame(_ engine: VeepooSyncEngine, _ data: Data) {
        engine.handle(.unknown(commandId: data[0], raw: data))
    }

    func testStreamingTransferIsNotCutByTheWatchdog() {
        let engine = engineInDailyPhase()
        // Frames keep arriving between ticks — the day must stay open however many ticks pass.
        for _ in 0..<5 {
            frame(engine, part1)
            engine.pollTickFired()
        }
        XCTAssertFalse(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)), "day 1 requested mid-transfer")
        XCTAssertTrue(writer.heartRates.isEmpty)
        engine.connectionDidEnd()
    }

    func testWatchdogCompletedDayStillPublishesItsRecords() {
        let engine = engineInDailyPhase()
        frame(engine, part1)
        frame(engine, part2)

        // No end marker: one tick with recent progress, then a whole silent tick.
        engine.pollTickFired()
        XCTAssertFalse(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)))
        engine.pollTickFired()

        XCTAssertTrue(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)), "watchdog did not advance")
        XCTAssertEqual(writer.heartRates, [60, 75, 96, 85, 80])
        engine.connectionDidEnd()
    }

    func testEndMarkerCompletesTheDay() {
        let engine = engineInDailyPhase()
        frame(engine, part1)
        frame(engine, part2)
        frame(engine, hex("dfffff58" + String(repeating: "00", count: 16)))

        XCTAssertEqual(writer.heartRates.count, 5)
        XCTAssertTrue(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)))
        engine.connectionDidEnd()
    }

    // MARK: Spot HR during a history pass

    /// The day loop issues no new E0/DF while a spot HR test runs (its samples would queue behind the
    /// transfer); the held request goes out when the test stops, and the watchdog doesn't fire meanwhile.
    func testSpotHeartRatePausesTheDayLoopUntilItStops() {
        let engine = engineInDailyPhase()                          // DF for day 0 is on the wire
        engine.measureHeartRateSpot()
        XCTAssertEqual(writer.commands.last, VeepooEncoder.heartRateStart())
        frame(engine, part1)
        frame(engine, part2)
        frame(engine, hex("dfffff58" + String(repeating: "00", count: 16)))   // day 0 finishes
        XCTAssertEqual(writer.heartRates.count, 5, "the finished day is still published")
        XCTAssertFalse(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)), "day 1 asked mid-test")
        for _ in 0..<4 { engine.pollTickFired() }                  // a long test: no watchdog advance
        XCTAssertFalse(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)))
        XCTAssertTrue(engine.isHistorySyncing)

        engine.stopHeartRate()
        XCTAssertEqual(Array(writer.commands.suffix(2)),
                       [VeepooEncoder.heartRateStop(), VeepooEncoder.sleepHistory(dayOffset: 1)])
        engine.connectionDidEnd()
    }

    /// A pass kicked while the test runs starts paused and begins when it stops.
    func testSyncHistoryDuringASpotHeartRateStartsWhenItEnds() {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 1)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        frame(engine, hex("e0000000" + String(repeating: "00", count: 16)))
        frame(engine, hex("dfffff58" + String(repeating: "00", count: 16)))   // startup pass done
        XCTAssertFalse(engine.isHistorySyncing)
        engine.measureHeartRateSpot()
        writer.commands.removeAll()
        engine.syncHistory()
        XCTAssertTrue(writer.commands.isEmpty, "\(writer.commands.map { [UInt8]($0) })")
        engine.stopHeartRate()
        XCTAssertEqual(writer.commands, [VeepooEncoder.heartRateStop(), VeepooEncoder.sleepHistory(dayOffset: 0)])
        engine.connectionDidEnd()
    }

    /// Workout / live streams use `startHeartRate` and never hold the loop.
    func testWorkoutStreamDoesNotPauseTheDayLoop() {
        let engine = engineInDailyPhase()
        engine.startHeartRate()
        frame(engine, hex("dfffff58" + String(repeating: "00", count: 16)))
        XCTAssertTrue(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)))
        engine.connectionDidEnd()
    }

    /// The contact-gap rule: 3 s normally, 10 s while a transfer shares the link, and widened to a few of
    /// the stream's own intervals for a slow-but-steady stream.
    func testHeartRateContactGapFollowsSyncAndCadence() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var window = HRSampleWindow()
        window.begin(at: t0)
        window.collect(70, at: t0.addingTimeInterval(6))
        XCTAssertFalse(window.contactLost(at: t0.addingTimeInterval(8.9)))
        XCTAssertTrue(window.contactLost(at: t0.addingTimeInterval(9.5)), "3 s gap outside a sync")

        var syncing = HRSampleWindow()
        syncing.begin(at: t0, historySyncing: true)
        syncing.collect(70, at: t0.addingTimeInterval(6))
        XCTAssertFalse(syncing.contactLost(at: t0.addingTimeInterval(14)), "burst gap during a sync is not contact loss")
        XCTAssertTrue(syncing.contactLost(at: t0.addingTimeInterval(16.5)))

        // A steady 2.5 s cadence: the gap widens to 7.5 s, still capped.
        var slow = HRSampleWindow()
        slow.begin(at: t0)
        for i in 0..<8 { slow.collect(70 + i % 2, at: t0.addingTimeInterval(6 + Double(i) * 2.5)) }
        XCTAssertEqual(slow.contactGap, 7.5, accuracy: 0.01)
        XCTAssertEqual(slow.stableValue.map { $0 >= 70 && $0 <= 71 }, true)
        let last = t0.addingTimeInterval(6 + 7 * 2.5)
        XCTAssertFalse(slow.contactLost(at: last.addingTimeInterval(5)))
        XCTAssertTrue(slow.contactLost(at: last.addingTimeInterval(8)))
    }

    // MARK: History request layout (A0)

    /// `DF <posLo> <posHi> <day>` (vendor SDK layout). Same assertions as Android's `VeepooDecoderTest`.
    func testDailyHistoryRequestIsPositionThenDay() {
        let daily = [UInt8](VeepooEncoder.dailyHistory(dayOffset: 3))
        XCTAssertEqual(daily.count, 20)
        XCTAssertEqual(Array(daily.prefix(4)), [0xDF, 0x01, 0x00, 0x03])
        XCTAssertEqual(Array([UInt8](VeepooEncoder.dailyHistory(dayOffset: 0)).prefix(4)), [0xDF, 0x01, 0x00, 0x00])
        // Position is a little-endian u16; out-of-range positions clamp to 1…65535.
        XCTAssertEqual(Array([UInt8](VeepooEncoder.dailyHistory(dayOffset: 6, position: 0x0123)).prefix(4)),
                       [0xDF, 0x23, 0x01, 0x06])
        XCTAssertEqual(Array([UInt8](VeepooEncoder.dailyHistory(dayOffset: 2, position: 0)).prefix(4)),
                       [0xDF, 0x01, 0x00, 0x02])
        XCTAssertEqual(Array([UInt8](VeepooEncoder.dailyHistory(dayOffset: 2, position: 70_000)).prefix(4)),
                       [0xDF, 0xFF, 0xFF, 0x02])
        // Regression guard: never the old `DF 01 <day> 00` (= position day*256+1 of day 0).
        for day in 1...6 {
            XCTAssertNotEqual(Array([UInt8](VeepooEncoder.dailyHistory(dayOffset: day)).prefix(4)),
                              [0xDF, 0x01, UInt8(day), 0x00])
        }
        // A day offset outside a byte clamps instead of trapping.
        XCTAssertEqual([UInt8](VeepooEncoder.dailyHistory(dayOffset: 300))[3], 0xFF)
        XCTAssertEqual([UInt8](VeepooEncoder.sleepHistory(dayOffset: -1))[1], 0x00)
    }

    /// The whole day loop asks each day for its records from position 1: `DF 01 00 <day>`.
    func testDayLoopAsksEachDayFromPositionOne() {
        writer = RecordingWriter()
        let days = 7
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: days)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        let end = hex("dfffff58" + String(repeating: "00", count: 16))
        for day in 0..<days {
            XCTAssertTrue(writer.asked(VeepooEncoder.sleepHistory(dayOffset: day)), "E0 for day \(day)")
            frame(engine, hex("e00000" + String(format: "%02x", day) + String(repeating: "00", count: 16)))
            var expected = Data([0xDF, 0x01, 0x00, UInt8(day)])
            expected.append(Data(count: 16))
            XCTAssertTrue(writer.asked(expected), "DF for day \(day)")
            let before = writer.heartRates.count
            frame(engine, part1)
            frame(engine, part2)
            frame(engine, end)
            XCTAssertEqual(writer.heartRates.count - before, 5, "day \(day)'s records")
        }
        XCTAssertTrue(writer.emitted.contains { if case .historySyncFinished = $0 { return true }; return false })
        let df = writer.commands.filter { $0.first == 0xDF }.map { [UInt8]($0) }
        XCTAssertEqual(df.map { Int($0[3]) }, Array(0..<days))
        XCTAssertTrue(df.allSatisfy { $0[1] == 0x01 && $0[2] == 0x00 })
        engine.connectionDidEnd()
    }


    /// Each day of the loop reports its start and, on its end marker, what came down (`SyncProgress` rows).
    func testDayLoopReportsPerDayProgressWithCounts() {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 2)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        let end = hex("dfffff58" + String(repeating: "00", count: 16))
        for day in 0..<2 {
            frame(engine, hex("e00000" + String(format: "%02x", day) + String(repeating: "00", count: 16)))
            frame(engine, part1)
            frame(engine, part2)
            frame(engine, end)
        }
        let progress: [SyncDayProgress] = writer.emitted.compactMap {
            if case let .historyDayProgress(p) = $0 { return p }
            return nil
        }
        XCTAssertEqual(progress.map(\.day), [0, 0, 1, 1])
        XCTAssertEqual(progress.map { $0.counts == nil }, [true, false, true, false])
        XCTAssertTrue(progress.allSatisfy { $0.totalDays == 2 })
        XCTAssertEqual(progress[1].counts?.heartRate, 5, "the fixture record carries five HR samples")
        engine.connectionDidEnd()
    }

    // MARK: Day-loop guards

    func testStrayEndMarkerDuringSleepPhaseDoesNotAdvance() {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 2)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))                   // E0 00 is now outstanding
        frame(engine, hex("dfffff58" + String(repeating: "00", count: 16)))
        XCTAssertFalse(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)))
        XCTAssertFalse(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0)))
        engine.connectionDidEnd()
    }

    func testSyncHistoryDuringAPassDoesNotRestartIt() {
        let engine = engineInDailyPhase()
        engine.syncHistory()
        XCTAssertEqual(writer.commands.filter { $0 == VeepooEncoder.sleepHistory(dayOffset: 0) }.count, 1)
        engine.connectionDidEnd()
    }

    /// Real ring, 2026-09-25: the tick's `D0 01` (live-HR re-assert) switched the ring to heart rate, and the
    /// SpO₂ test ended itself / the BP test froze at 40 %. Nothing may be written mid-test. Same as Android.
    func testSpotTestsWriteTheirStartAndStopFrames() {
        for (start, stop, startFrame, stopFrame) in [
            ({ (e: VeepooSyncEngine) in e.startStress() }, { (e: VeepooSyncEngine) in e.stopStress() },
             VeepooEncoder.stressStart(), VeepooEncoder.stressStop()),
            ({ (e: VeepooSyncEngine) in e.startGlucose() }, { (e: VeepooSyncEngine) in e.stopGlucose() },
             VeepooEncoder.glucoseStart(), VeepooEncoder.glucoseStop()),
            ({ (e: VeepooSyncEngine) in e.startBloodComponents() }, { (e: VeepooSyncEngine) in e.stopBloodComponents() },
             VeepooEncoder.bloodComponentsStart(), VeepooEncoder.bloodComponentsStop()),
        ] {
            let engine = engineInDailyPhase()
            writer.commands.removeAll()
            start(engine)
            XCTAssertEqual(writer.commands, [startFrame])
            stop(engine)
            XCTAssertEqual(writer.commands, [startFrame, stopFrame])
            engine.connectionDidEnd()
        }
    }

    func testPollTickLeavesTheRingAloneDuringASpO2OrBPTest() {
        for (start, stop) in [
            ({ (e: VeepooSyncEngine) in e.startSpO2() }, { (e: VeepooSyncEngine) in e.stopSpO2() }),
            ({ (e: VeepooSyncEngine) in e.startBloodPressure() }, { (e: VeepooSyncEngine) in e.stopBloodPressure() }),
            // Measure hub (measure-hub-spec §3/§6): stress, glucose and blood components hold the sensor too.
            ({ (e: VeepooSyncEngine) in e.startStress() }, { (e: VeepooSyncEngine) in e.stopStress() }),
            ({ (e: VeepooSyncEngine) in e.startGlucose() }, { (e: VeepooSyncEngine) in e.stopGlucose() }),
            ({ (e: VeepooSyncEngine) in e.startBloodComponents() }, { (e: VeepooSyncEngine) in e.stopBloodComponents() }),
        ] {
            let engine = engineInDailyPhase()
            start(engine)
            writer.commands.removeAll()
            engine.pollTickFired()
            engine.pollTickFired()
            XCTAssertTrue(writer.commands.isEmpty, "\(writer.commands.map { [UInt8]($0) })")
            stop(engine)
            writer.commands.removeAll()
            engine.pollTickFired()
            XCTAssertTrue(writer.asked(VeepooEncoder.steps()))
            engine.connectionDidEnd()
        }
    }

    // MARK: DF records span parts 1…N (df-multipart-records.md)

    /// Real frames, 20-byte MTU: header `a0 00 0f` → 15 data parts. Same fixture as Android's test.
    private let smallMtuRecord = [
        "df010000a0000f000000e13b8714000000000000", "df010001b10409190000b20a0000000900000000",
        "df0100024900b3060000000000ffb40540000000", "df01000300b5050000000000b605ffffffffffb7",
        "df0100043300ff5d61ffffffffffffffffffffff", "df010005ffffffffffffffffffffffffffffffff",
        "df010006ffffffffffffffffffffffffffffffff", "df010007ffffffffb8027353b91e610000000000",
        "df01000800000000000000000000000000001e00", "df010009000000afefebabafba050000080100bb",
        "df01000a2f000000000000000000000000000001", "df01000b000000000000090000002f0009000000",
        "df01000c0000000081e900194a00008c00000c00", "df01000dbc020024bd050000000000be02a401bf",
        "df01000e010ac1010bc20a9b0186006400e7003f", "df01000f08000000000000000000000000000000",
    ]

    /// Real frames, large MTU: header `19 00 02` → 2 data parts of 125 bytes.
    private let largeMtuRecord = [
        "df010000190002000000e1eb187d010000000000",
        "df010001b10409181019b20a00000001000000003506b3060000000000ffb4050000000000b5050000000000b605ffffffff"
            + "ffb73300ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            + "ffffffffffb8020000b91e000000000000000000000000000000",
        "df010002000000000000000000000000000000ba050000000000bb2f00000000000000000000000000000000000000000000"
            + "00000000000000000000000000000000000000000000000000bc020010bd050000000000be020000bf010ac10100c20a0000"
            + "00000000000000000000000000000000000000000000000000",
    ]

    private func completeDay(_ frames: [String]) {
        let engine = engineInDailyPhase()
        for f in frames { frame(engine, hex(f)) }
        frame(engine, hex("dfffff58" + String(repeating: "00", count: 16)))
        engine.connectionDidEnd()
    }

    private func values(_ kind: MeasurementKind) -> [Double] {
        writer.emitted.compactMap {
            if case let .historyMeasurement(k, value, _) = $0, k == kind { return value }
            return nil
        }
    }

    private var buckets: [Date] {
        writer.emitted.compactMap { if case let .activityBucket(t, _, _) = $0 { return t }; return nil }
    }

    private var skippedRecords: Bool {
        writer.emitted.contains { if case .historySyncProgress = $0 { return true }; return false }
    }

    func testFifteenPartRecordAtDefaultMTUYieldsAllVitals() {
        completeDay(smallMtuRecord)
        XCTAssertEqual(values(.heartRate), [64])
        XCTAssertEqual(values(.hrv), [40], "BUG-103: the vendor reduction, one value for minute 0")
        XCTAssertEqual(values(.bloodPressureSystolic), [115])
        XCTAssertEqual(values(.bloodPressureDiastolic), [83])
        XCTAssertEqual(values(.spo2), [97])
        XCTAssertEqual(values(.stress), [11])
        XCTAssertEqual(values(.bloodSugar).first ?? 0, 4.20 * 18.016, accuracy: 0.01)
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: buckets.first ?? .distantPast)
        XCTAssertEqual([c.month, c.day, c.hour, c.minute], [9, 25, 0, 0])
    }

    func testTwoPartRecordAtLargeMTUStillAssembles() {
        completeDay(largeMtuRecord)
        // BUG-102: the slot is dated by the day the loop asked for (day 0 = 09-25 here), taking only the
        // time of day from `B1` (`09 18 10 19` = 16:25).
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: buckets.first ?? .distantPast)
        XCTAssertEqual([c.month, c.day, c.hour, c.minute], [9, 25, 16, 25])
        XCTAssertFalse(skippedRecords)
    }

    // MARK: Sleep transfer completeness (BUG-201 / BUG-108 / BUG-202 / SEC-301)

    private var sleepTimelines: [(start: Date, stages: Int)] {
        writer.emitted.compactMap {
            if case let .sleepTimeline(start, stages, _) = $0 { return (start, stages.count) }
            return nil
        }
    }

    /// An authenticated engine with day 0's `E0` transfer outstanding.
    private func engineAwaitingSleep(days: Int = 2) -> VeepooSyncEngine {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: days)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        XCTAssertTrue(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 0)))
        return engine
    }

    private func feedSleepPages(_ engine: VeepooSyncEngine, _ pages: [String]) {
        for page in pages { frame(engine, hex(page)) }
    }

    /// BUG-201 — the real 17-page night with page 9 lost on the way up decoded to a 620-minute curve that
    /// was stored as if the ring had said so. It must be refused instead: nothing stored, the day not
    /// advanced (so it is asked for again), and the failure counted for diagnostics.
    func testSleepTransferMissingAPageStoresNothingAndKeepsTheDayOpen() {
        let engine = engineAwaitingSleep()
        feedSleepPages(engine, SleepTransferFixtures.ringB1111.filter { !$0.hasPrefix("e009") })
        XCTAssertTrue(sleepTimelines.isEmpty, "an incomplete transfer is not a night")
        XCTAssertEqual(engine.sleepIncompleteTransfers, 1)
        XCTAssertFalse(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0)), "the day must not be advanced")
        XCTAssertFalse(writer.asked(VeepooEncoder.sleepHistory(dayOffset: 1)))
        engine.connectionDidEnd()
    }

    /// The complete transfer is stored exactly once, and completes the sleep phase itself.
    func testCompleteSleepTransferStoresOneSession() {
        let engine = engineAwaitingSleep()
        feedSleepPages(engine, SleepTransferFixtures.ringB1111)
        XCTAssertEqual(sleepTimelines.map(\.stages), [650])
        XCTAssertEqual(engine.sleepIncompleteTransfers, 0)
        XCTAssertTrue(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0)), "the DF half follows")
        engine.connectionDidEnd()
    }

    /// BUG-201 — a page-0-only answer (`e0 00 01 <day>` with an `A6` trailer and no `A1`) announces one
    /// session and carries none: the old code stored nothing *and* closed the day, so the night was lost.
    func testPageZeroOnlyTransferAnnouncesASessionAndDecodesNone() {
        let engine = engineAwaitingSleep()
        frame(engine, hex("e0000100a60200ff000000000000000000"))
        XCTAssertTrue(sleepTimelines.isEmpty)
        XCTAssertEqual(engine.sleepIncompleteTransfers, 1)
        XCTAssertFalse(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0)))
        engine.connectionDidEnd()
    }

    /// BUG-201 — `e0 00 00 <day>` (page 0, **no** sessions) is the only no-data answer. A real page whose
    /// byte 2 happens to be 0 (`e0 10 00 04 …`, page 0x10 of day 4) used to be swallowed as one.
    func testARealPageWithAZeroSessionByteIsNotANoDataMarker() {
        let engine = engineAwaitingSleep()
        // Page 0x10 out of order: it must be buffered, not treated as "the ring kept no sleep".
        frame(engine, hex("e0100004a10c01a208515230cf28f13897a32409"))
        XCTAssertFalse(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0)), "the sleep phase is still open")
        engine.connectionDidEnd()
    }

    /// BUG-108 — a session with no `A5` curve used to be stored as deep → light → REM → awake runs. The
    /// counts are real, the order is not: the record is skipped (and counted) instead of invented.
    func testSleepSessionWithoutACurveIsNotStoredAsAFabricatedNight() {
        let engine = engineAwaitingSleep()
        frame(engine, Self.curveLessPage)
        XCTAssertTrue(sleepTimelines.isEmpty, "no curve, no hypnogram")
        XCTAssertEqual(engine.sleepRejectedSessions, 1)
        engine.connectionDidEnd()
    }

    /// BUG-202 / A2 (migration-free) — the ring's own `A3` numbers are compared with the decoded curve at
    /// emit time. On the real 17-page night they agree exactly, so nothing is reported…
    func testTheRingsOwnCountsAgreeWithTheRealCurve() {
        let engine = engineAwaitingSleep()
        feedSleepPages(engine, SleepTransferFixtures.ringB1111)
        XCTAssertEqual(sleepTimelines.map(\.stages), [650])
        XCTAssertEqual(engine.sleepCountMismatches, 0)
        engine.connectionDidEnd()
    }

    /// …and a curve that lost minutes against the ring's own window is *reported*, never silently accepted.
    /// Diagnostic only: the night is still stored, and the retry signals stay A1/A4.
    func testACurveShorterThanTheRingsOwnWindowIsReported() {
        let engine = engineAwaitingSleep()
        // A complete transfer (no overrun) whose A3 says 650 minutes while its A5 curve covers 90.
        frame(engine, Self.page(total: 650, awake: 38, curveMinutes: 90))
        XCTAssertEqual(engine.sleepIncompleteTransfers, 0, "the synthetic transfer must pass the completeness checks")
        XCTAssertEqual(sleepTimelines.map(\.stages), [90])
        XCTAssertEqual(engine.sleepCountMismatches, 1)
        XCTAssertTrue(writer.emitted.contains {
            if case let .historySyncProgress(stage) = $0 { return stage.contains("the ring's own count differs") }
            return false
        })
        engine.connectionDidEnd()
    }

    /// One `E0` page: a single `A1` block with an `A3` summary and an `A5` curve of `curveMinutes`.
    private static func page(total: Int, awake: Int, curveMinutes: Int) -> Data {
        var summary = [UInt8](repeating: 0, count: 31)
        summary[0...3] = [0x09, 0x19, 0x00, 0x21]
        summary[4...7] = [0x09, 0x19, 0x0B, 0x0B]
        summary[25] = UInt8(total & 0xFF)
        summary[26] = UInt8(total >> 8)
        summary[29] = UInt8(awake & 0xFF)
        summary[30] = UInt8(awake >> 8)
        // `A5` is the one tag with a 2-byte LE minute count instead of a 1-byte length.
        let bitmap = [UInt8](repeating: 0x00, count: (curveMinutes + 3) / 4)   // all deep
        let curve: [UInt8] = [0xA5, UInt8(curveMinutes & 0xFF), UInt8(curveMinutes >> 8)] + bitmap
        let body: [UInt8] = [0xA3, 0x1F] + summary + curve
        let declared = UInt16(3 + body.count)
        let block: [UInt8] = [0xA1, UInt8(declared & 0xFF), UInt8(declared >> 8)] + body
        return Data([0xE0, 0x00, 0x01, 0x00] + block)
    }

    /// SEC-301 (report-only, decision D4) — three cases: a matching `a1` identity, none at all, and one that
    /// contradicts what this peripheral first reported. All three still store the night; the counts are the
    /// diagnostic.
    func testSleepProvenanceIsCountedButTheRecordIsStillStored() {
        // A link with no `a1` identity at all (the null-MAC case Android's guard skips).
        let silent = engineAwaitingSleep()
        feedSleepPages(silent, SleepTransferFixtures.ringB1111)
        XCTAssertEqual(sleepTimelines.count, 1, "report-only: the night is still stored")
        XCTAssertEqual(silent.sleepProvenance.checked, 1)
        XCTAssertEqual(silent.sleepProvenance.nullIdentity, 1)
        XCTAssertEqual(silent.sleepProvenance.mismatched, 0)
        silent.connectionDidEnd()

        // The same peripheral reports one identity, then a different one: a replayed `a1` (SEC-301).
        writer = RecordingWriter()
        writer.source = "peripheral-A"
        let ring = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 1)
        ring.connectionDidStart()
        ring.handle(.ringIdentity(sensorId: "aaaa000000000001"))
        ring.handle(.commandAck(commandId: 0xA1))
        feedSleepPages(ring, SleepTransferFixtures.ringB1111)
        XCTAssertEqual(ring.sleepProvenance.mismatched, 0, "the first identity pins the link")
        ring.connectionDidEnd()

        writer.commands.removeAll()
        writer.emitted.removeAll()
        ring.connectionDidStart()
        ring.handle(.ringIdentity(sensorId: "bbbb000000000002"))
        ring.handle(.commandAck(commandId: 0xA1))
        feedSleepPages(ring, SleepTransferFixtures.ringB1111)
        XCTAssertEqual(ring.sleepProvenance.checked, 2)
        XCTAssertEqual(ring.sleepProvenance.mismatched, 1, "a contradictory a1 MAC on the same peripheral")
        XCTAssertEqual(writer.emitted.filter { if case .sleepTimeline = $0 { return true }; return false }.count, 1,
                       "report-only: still stored")
        ring.connectionDidEnd()
    }

    /// One `E0` page carrying a single `A3`-only `A1` block (no `A5`): a real summary, no curve.
    private static var curveLessPage: Data {
        var summary = [UInt8](repeating: 0, count: 31)
        summary[0...3] = [0x09, 0x19, 0x00, 0x21]      // start
        summary[4...7] = [0x09, 0x19, 0x0B, 0x0B]      // end
        summary[19] = 0x87                              // deep 135
        summary[21] = 0x7B                              // light 379
        summary[22] = 0x01
        summary[23] = 0x62                              // REM 98
        summary[25] = 0x8A                              // total 650
        summary[26] = 0x02
        summary[29] = 0x26                              // awake 38
        let body: [UInt8] = [0xA3, 0x1F] + summary
        let declared = UInt16(3 + body.count)
        let block: [UInt8] = [0xA1, UInt8(declared & 0xFF), UInt8(declared >> 8)] + body
        return Data([0xE0, 0x00, 0x01, 0x00] + block + [UInt8](repeating: 0, count: max(0, 16 - block.count)))
    }

    /// The diagnostics report says **why** a night is missing: the sleep counters reach the export
    /// (BUG-201/108/202, SEC-301), which is what makes one release of report-only provenance usable.
    func testSleepSyncCountersReachTheDiagnosticsExport() {
        SleepSyncDiagnostics.shared.reset()
        let engine = engineAwaitingSleep()
        feedSleepPages(engine, SleepTransferFixtures.ringB1111.filter { !$0.hasPrefix("e009") })
        let snapshot = SleepSyncDiagnostics.shared.snapshot()
        XCTAssertEqual(snapshot["incomplete_transfers"], 1)
        XCTAssertEqual(snapshot["rejected_sessions"], 0)
        XCTAssertNotNil(snapshot["provenance_null_identity"], "every field is present, zeros included")
        engine.connectionDidEnd()
    }

    func testRecordMissingADeclaredPartIsSkipped() {
        completeDay(smallMtuRecord.filter { !$0.hasPrefix("df010007") })
        XCTAssertTrue(buckets.isEmpty)
        XCTAssertTrue(skippedRecords)
    }
}

private func hex(_ value: String) -> Data {
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        data.append(UInt8(value[index..<next], radix: 16)!)
        index = next
    }
    return data
}
