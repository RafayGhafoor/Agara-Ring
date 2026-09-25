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
        var commands: [Data] = []
        var emitted: [RingDecodedEvent] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            commands.append(command)
            completion(.success(()))
        }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
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

    /// An authenticated engine whose day-0 sleep phase is done, so the DF read for day 0 is in flight.
    private func engineInDailyPhase() -> VeepooSyncEngine {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 2)
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
        XCTAssertEqual(values(.hrv), [93, 97])
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
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: buckets.first ?? .distantPast)
        XCTAssertEqual([c.month, c.day, c.hour, c.minute], [9, 24, 16, 25])
        XCTAssertFalse(skippedRecords)
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
