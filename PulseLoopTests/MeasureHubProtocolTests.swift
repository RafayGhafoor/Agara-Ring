import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Measure-hub protocol work (docs/process/plans/measure-hub-spec.md §1, §2, §4–§7), pinned on **real
/// frames from our ring** (`research/pulseloop.db`, table `raw_packets`) wherever the capture has them.
/// The stress / glucose / blood-component test replies have never been captured (no run on hardware yet),
/// so those use frames built from the vendor-SDK layout and say so. Android's tests use the same frames.
@MainActor
final class MeasureHubProtocolTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var decoder: VeepooDecoder { VeepooDecoder(calendar: calendar) }

    private final class NullWriter: RingCommandWriter {
        func enqueue(_ command: Data) {}
    }

    private let writer = NullWriter()

    /// A driver mid-measurement: the start frame flips its latch exactly as a real write does.
    private func driver(afterWriting start: Data? = nil) -> VeepooDriver {
        let driver = VeepooDriver(writer: writer)
        if let start { _ = driver.frame(start) }
        return driver
    }

    private func ingest(_ driver: VeepooDriver, _ hexFrame: String) -> [RingDecodedEvent] {
        driver.ingest(frameData(hexFrame), from: CBUUIDs.command)
    }

    // MARK: §1.1 HR busy reply

    /// Real: every re-asserted `d0 01` during a stream is answered `d0 01 00 00 00 0a` (394 of 394 in the
    /// capture). It is neither a 1 bpm reading nor "not worn".
    func testHeartRateBusyReplyIsIgnored() {
        XCTAssertEqual(decoder.heartRateReply(frame: frameData("d0010000000a0000000000000000000000000000")), .busy)
        XCTAssertNil(decoder.heartRate(frame: frameData("d0010000000a0000000000000000000000000000")))
        let events = ingest(driver(afterWriting: VeepooEncoder.heartRateStart()), "d0010000000a0000000000000000000000000000")
        XCTAssertTrue(events.isEmpty, "\(events.map(\.kind))")
    }

    /// Real: a plain `d0 01 00 …` (156 in the capture) means no finger → a not-worn refusal of the HR test.
    func testPlainD001MeansNotWorn() {
        XCTAssertEqual(decoder.heartRateReply(frame: frameData("d001000000000000000000000000000000000000")), .notWorn)
        let events = ingest(driver(afterWriting: VeepooEncoder.heartRateStart()), "d001000000000000000000000000000000000000")
        guard case let .measurementRejected(mode, reason)? = events.first else { return XCTFail("\(events.map(\.kind))") }
        XCTAssertEqual(mode, SpotMode.heartRate)
        XCTAssertEqual(reason, .notWorn)
    }

    /// Real bpm frames (`d0 59` = 89 bpm, 448 in the capture) and warm-up zeros (`d0 00`, 1,079).
    func testHeartRateBpmAndWarmUpFrames() {
        XCTAssertEqual(decoder.heartRateReply(frame: frameData("d059000000000000000000000000000000000000")), .bpm(89))
        XCTAssertEqual(decoder.heartRateReply(frame: frameData("d000000000000000000000000000000000000000")), .warmingUp)
        let events = ingest(driver(afterWriting: VeepooEncoder.heartRateStart()), "d059000000000000000000000000000000000000")
        guard case let .heartRateSample(bpm, _)? = events.first else { return XCTFail() }
        XCTAssertEqual(bpm, 89)
    }

    // MARK: §1.2 Blood pressure

    /// Real: after our stop the ring answered `90 01 00 00 00 01` — a stop ack, never 1/0 mmHg. Real
    /// progress frames `90 00 00 <progress> 00 01` decode to nothing too.
    func testBloodPressureStopAckAndProgressAreNotReadings() {
        XCTAssertNil(decoder.bloodPressure(frame: frameData("9001000000010000000000000000000000000000")))
        XCTAssertNil(decoder.bloodPressureRefusal(frame: frameData("9001000000010000000000000000000000000000")))
        XCTAssertNil(decoder.bloodPressure(frame: frameData("9000004c00010000000000000000000000000000")))
        let events = ingest(driver(afterWriting: VeepooEncoder.bloodPressureStart()), "9001000000010000000000000000000000000000")
        XCTAssertTrue(events.isEmpty)
    }

    func testBloodPressureFinalFrameNeedsProgress100AndPlausibleSystolic() {
        let final = decoder.bloodPressure(frame: frameData("9074536400010000000000000000000000000000"))
        XCTAssertEqual(final?.systolic, 116)
        XCTAssertEqual(final?.diastolic, 83)
        XCTAssertNil(decoder.bloodPressure(frame: frameData("9027536400010000000000000000000000000000")), "systolic 39 < 40")
        XCTAssertNil(decoder.bloodPressure(frame: frameData("9074536300010000000000000000000000000000")), "progress 99")
    }

    /// Status byte 4 (SDK layout): 252 not worn, 253 charging, 254 low battery, 1/2/4/5/255 busy.
    func testBloodPressureStatusCodesBecomeRefusals() {
        let cases: [(UInt8, MeasurementRefusal)] = [
            (252, .notWorn), (253, .charging), (254, .lowBattery),
            (1, .busy), (2, .busy), (4, .busy), (5, .busy), (255, .busy),
        ]
        for (status, reason) in cases {
            let frame = Data([0x90, 0, 0, 0, status, 1] + [UInt8](repeating: 0, count: 14))
            XCTAssertEqual(decoder.bloodPressureRefusal(frame: frame), reason, "status \(status)")
            let events = driver(afterWriting: VeepooEncoder.bloodPressureStart()).ingest(frame, from: CBUUIDs.command)
            guard case let .measurementRejected(mode, got)? = events.first else { return XCTFail("status \(status)") }
            XCTAssertEqual(mode, SpotMode.bloodPressure)
            XCTAssertEqual(got, reason)
        }
        XCTAssertNil(decoder.bloodPressureRefusal(frame: frameData("9000000800010000000000000000000000000000")), "real progress frame")
    }

    // MARK: §1.3 SpO₂ status

    func testOxygenStatusCodes() {
        // Real warm-up frame: open, free, value 0 → neither a reading nor a refusal.
        XCTAssertNil(decoder.oxygen(frame: frameData("8001000000640000000000000000000000000000")))
        XCTAssertNil(decoder.oxygenRefusal(frame: frameData("8001000000640000000000000000000000000000")))
        XCTAssertEqual(decoder.oxygenRefusal(frame: frameData("80010c0000640000000000000000000000000000")), .notWorn)
        XCTAssertEqual(decoder.oxygenRefusal(frame: frameData("80010a0000640000000000000000000000000000")), .chargingOrLowBattery)
        XCTAssertEqual(decoder.oxygenRefusal(frame: frameData("8001000100640000000000000000000000000000")), .notWorn, "value 1")
        XCTAssertNil(decoder.oxygen(frame: frameData("80010c6000640000000000000000000000000000")), "no value with a bad status")
        let events = ingest(driver(afterWriting: VeepooEncoder.oxygenStart()), "80010c0000640000000000000000000000000000")
        guard case let .measurementRejected(mode, reason)? = events.first else { return XCTFail() }
        XCTAssertEqual(mode, SpotMode.spo2)
        XCTAssertEqual(reason, .notWorn)
        XCTAssertEqual(MeasurementRefusal.chargingOrLowBattery.message(isCharging: true), MeasurementRefusal.chargingMessage)
        XCTAssertEqual(MeasurementRefusal.chargingOrLowBattery.message(isCharging: false), MeasurementRefusal.lowBatteryMessage)
    }

    // MARK: §1.4 Timezone in a1

    /// The real frame we sent at 2026-09-24 14:43:14 carried `01 00 d8` (a constant UTC−10). Now byte 12 is
    /// `01` and byte 13 the phone's offset in 15-minute steps.
    func testAuthenticationCarriesTheTimezone() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 14, minute: 43, second: 14))!
        let plus5 = VeepooEncoder.authentication(now: now, calendar: calendar,
                                                 timeZone: TimeZone(secondsFromGMT: 5 * 3600)!)
        XCTAssertEqual(plus5.hexString, "a100000007ea09180e2b0e01011400")
        let minus10 = VeepooEncoder.authentication(now: now, calendar: calendar,
                                                   timeZone: TimeZone(secondsFromGMT: -10 * 3600)!)
        XCTAssertEqual([UInt8](minus10)[12...13], [0x01, 0xD8])
        XCTAssertEqual(VeepooEncoder.utcOffsetQuarterHours(TimeZone(secondsFromGMT: 5 * 3600 + 1800)!), 22)
        XCTAssertEqual(VeepooEncoder.utcOffsetQuarterHours(TimeZone(secondsFromGMT: 0)!), 0)
    }

    // MARK: §1.5 DF integrity

    /// Real frames, 20-byte MTU (15 parts) and 125-byte MTU (2 parts) — both pass their CRC-16/MODBUS.
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

    private let largeMtuRecord = [
        "df010000190002000000e1eb187d010000000000",
        "df010001b10409181019b20a00000001000000003506b3060000000000ffb4050000000000b5050000000000b605ffffffff"
            + "ffb73300ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            + "ffffffffffb8020000b91e000000000000000000000000000000",
        "df010002000000000000000000000000000000ba050000000000bb2f00000000000000000000000000000000000000000000"
            + "00000000000000000000000000000000000000000000000000bc020010bd050000000000be020000bf010ac10100c20a0000"
            + "00000000000000000000000000000000000000000000000000",
    ]

    private func parts(_ frames: [String]) -> [Int: Data] {
        Dictionary(uniqueKeysWithValues: frames.map { let d = frameData($0); return (Int(d[3]), d) })
    }

    func testRealRecordsPassTheirChecksum() {
        for frames in [smallMtuRecord, largeMtuRecord] {
            guard case let .complete(payload) = VeepooSyncEngine.assemble(parts(frames)) else {
                return XCTFail("real record failed its CRC")
            }
            XCTAssertEqual(payload.count, 225, "trimmed to header byte 10")
        }
        XCTAssertEqual(veepooCRC16Modbus(Array("123456789".utf8)), 0x4B37, "CRC-16/MODBUS check value")
    }

    func testCorruptRecordIsDroppedAndCounted() {
        var frames = smallMtuRecord
        frames[7] = "df010007ffffffffb8027453b91e610000000000"   // systolic 115 → 116
        XCTAssertEqual(VeepooSyncEngine.assemble(parts(frames)), .checksumMismatch)
        XCTAssertNil(VeepooSyncEngine.assembleRecord(parts(frames)))

        let recorder = FrameRecorder()
        let engine = VeepooSyncEngine(writer: recorder, decoder: VeepooDecoder(), historyDays: 1)
        engine.isFeatureOn = { _ in false }
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        engine.handle(.unknown(commandId: 0xE0, raw: frameData("e0000000" + String(repeating: "00", count: 16))))
        for f in frames { engine.handle(.unknown(commandId: 0xDF, raw: frameData(f))) }
        engine.handle(.unknown(commandId: 0xDF, raw: frameData("dfffff58" + String(repeating: "00", count: 16))))
        XCTAssertEqual(engine.crcFailures, 1)
        XCTAssertFalse(recorder.emitted.contains { if case .activityBucket = $0 { return true }; return false })
        XCTAssertTrue(recorder.emitted.contains {
            if case let .historySyncProgress(stage) = $0 { return stage.contains("checksum") }
            return false
        })
        engine.connectionDidEnd()
    }

    // MARK: §2 Capability probe

    private let capabilityPackets = [
        "a701000001020100081400020000000100fe0301",
        "a700030400030000060005010006020005000002",
        "a702000000010000010000000100000403000203",
        "a702000000000000000000000101000000000004",
    ]

    /// Real `a7` packages 1–4 (identical on every connect) decode to what the vendor app offers: HR, SpO₂,
    /// BP, stress, glucose and blood components; all-day HRV but no HRV test; no temperature, ECG, MET.
    func testRealCapabilityPacketsDecode() {
        let raw = Dictionary(uniqueKeysWithValues: capabilityPackets.map { let b = [UInt8](frameData($0)); return (Int(b[19]), b) })
        let caps = RingCapabilities.decode(packages: raw)
        XCTAssertTrue(caps.heartRate)
        XCTAssertTrue(caps.bloodPressure)
        XCTAssertTrue(caps.spo2)
        XCTAssertTrue(caps.hrv)
        XCTAssertTrue(caps.hrvAllDay)
        XCTAssertFalse(caps.hrvTest)
        XCTAssertTrue(caps.stress)
        XCTAssertTrue(caps.bloodGlucose)
        XCTAssertEqual(caps.glucoseType, 4)
        XCTAssertTrue(caps.bloodComponents)
        XCTAssertTrue(caps.bloodComponentsCalibration)
        XCTAssertFalse(caps.temperature)
        XCTAssertFalse(caps.ecg)
        XCTAssertFalse(caps.met)
        XCTAssertFalse(caps.fatigue)
        XCTAssertFalse(caps.breathing)
        XCTAssertFalse(caps.bodyComposition)
        XCTAssertTrue(caps.sportModes)
        XCTAssertTrue(caps.findDevice)
        XCTAssertTrue(caps.cameraShutter)
        XCTAssertTrue(caps.autoMeasure)
        XCTAssertEqual(caps.historyDays, 3)
        XCTAssertEqual(caps.packages, [1, 2, 3, 4])
        XCTAssertEqual(RingCapabilities(json: caps.json), caps, "round-trips through the device row")
    }

    func testDriverEmitsCapabilitiesOnceAllFourPackagesArrived() {
        let driver = driver()
        for frame in capabilityPackets.dropLast() {
            XCTAssertTrue(ingest(driver, frame).isEmpty)
        }
        guard case let .ringCapabilities(caps)? = ingest(driver, capabilityPackets[3]).first else { return XCTFail() }
        XCTAssertTrue(caps.stress)
    }

    /// Real `a1` reply: status 06, device number 0x09DE = 2526, firmware 00.12.09.
    func testA1ReplyCarriesFirmware() {
        let info = decoder.firmware(frame: frameData("a100000609de00120900000114401e1c42410000"))
        XCTAssertEqual(info?.deviceNumber, 2526)
        XCTAssertEqual(info?.version, "00.12.09")
        XCTAssertEqual(info?.testVersion, "00.12.09.00")
        let events = ingest(driver(), "a100000609de00120900000114401e1c42410000")
        // The reply also carries the ring's own address (bytes 12…17, reversed): it becomes the AGB sensor id, hashed in the decoder.
        XCTAssertEqual(events.map(\.kind), ["command_ack", "firmware", "ring_identity"])
        guard case let .firmware(version, deviceNumber, testVersion) = events[1] else { return XCTFail() }
        XCTAssertEqual(version, "00.12.09")
        XCTAssertEqual(deviceNumber, 2526)
        XCTAssertEqual(testVersion, "00.12.09.00")
        guard case let .ringIdentity(sensorId) = events[2] else { return XCTFail() }
        XCTAssertEqual(sensorId, AGB.sensorId(ringMac: "41:42:1C:1E:40:14"))
        XCTAssertEqual(sensorId.count, AgaraConfig.Storage.sensorIdHexChars)
    }

    // MARK: §3/§6 Stress, glucose, blood components (SDK layout — no capture yet)

    func testStressReplies() {
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010032000000000000000000000000000000")), .progress(50))
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010064210000000000000000000000000000")), .result(33))
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010064000000000000000000000000000000")), .progress(100), "score 0")
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010100000000000000000000000000000000")), .refused(.busy))
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010200000000000000000000000000000000")), .refused(.lowBattery))
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010300000000000000000000000000000000")), .refused(.busy))
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906010400000000000000000000000000000000")), .refused(.notWorn))
        XCTAssertEqual(decoder.stressReply(frame: frameData("8906020000000000000000000000000000000000")), .stopped)
        let events = ingest(driver(afterWriting: VeepooEncoder.stressStart()), "8906010064210000000000000000000000000000")
        guard case let .stressSample(value, _)? = events.first else { return XCTFail() }
        XCTAssertEqual(value, 33)
    }

    func testGlucoseReplies() {
        // 5.41 mmol/L → 541 = 0x021d LE.
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901010064" + "1d02" + String(repeating: "00", count: 13))), .result(5.41))
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901010040" + "0000" + String(repeating: "00", count: 13))), .progress(64))
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901010200" + String(repeating: "00", count: 15))), .refused(.lowBattery))
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901010300" + String(repeating: "00", count: 15))), .refused(.busy))
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901010400" + String(repeating: "00", count: 15))), .refused(.notWorn))
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901000000" + String(repeating: "00", count: 15))), .refused(.refused))
        XCTAssertEqual(decoder.glucoseReply(frame: frameData("8901020000" + String(repeating: "00", count: 15))), .stopped)
        let events = ingest(driver(afterWriting: VeepooEncoder.glucoseStart()), "8901010064" + "1d02" + String(repeating: "00", count: 13))
        guard case let .bloodSugarSample(mgdl, _)? = events.first else { return XCTFail() }
        XCTAssertEqual(mgdl, 5.41 * 18.016, accuracy: 0.001)
    }

    /// Uric acid comes **first** in the `8a 01` reply (C2 puts it last). Values from the real 15:30 C2 record.
    func testBloodComponentsReplies() {
        let result = "8a01010064" + "2609" + "b401" + "9400" + "6200" + "fe00" + "0000000000"
        guard case let .result(reading)? = decoder.bloodComponentsReply(frame: frameData(result)) else { return XCTFail() }
        XCTAssertEqual(reading.uricAcid, 234.2, accuracy: 0.001)
        XCTAssertEqual(reading.totalCholesterol, 4.36, accuracy: 0.001)
        XCTAssertEqual(reading.triglycerides, 1.48, accuracy: 0.001)
        XCTAssertEqual(reading.hdl, 0.98, accuracy: 0.001)
        XCTAssertEqual(reading.ldl, 2.54, accuracy: 0.001)
        XCTAssertEqual(decoder.bloodComponentsReply(frame: frameData("8a01010032" + String(repeating: "00", count: 15))), .progress(50))
        XCTAssertEqual(decoder.bloodComponentsReply(frame: frameData("8a01010100" + String(repeating: "00", count: 15))), .refused(.busy))
        XCTAssertEqual(decoder.bloodComponentsReply(frame: frameData("8a01010200" + String(repeating: "00", count: 15))), .refused(.lowBattery))
        XCTAssertEqual(decoder.bloodComponentsReply(frame: frameData("8a01010400" + String(repeating: "00", count: 15))), .refused(.notWorn))
        XCTAssertEqual(decoder.bloodComponentsReply(frame: frameData("8a01020000" + String(repeating: "00", count: 15))), .stopped)
        let events = ingest(driver(afterWriting: VeepooEncoder.bloodComponentsStart()), result)
        guard case let .bloodComponentsSample(got, _)? = events.first else { return XCTFail() }
        XCTAssertEqual(got, reading)
    }

    /// Real calibration-read replies the ring pushes (`89 03 …`, `8a 02 …`) are never a test result, and
    /// no 0x89/0x8A frame decodes when no test is running.
    func testCalibrationReadsAreNotResults() {
        XCTAssertNil(decoder.glucoseReply(frame: frameData("8903020101020000000000000000000000000000")))
        XCTAssertNil(decoder.stressReply(frame: frameData("8903020101020000000000000000000000000000")))
        XCTAssertNil(decoder.bloodComponentsReply(frame: frameData("8a02020100000000000000000000000000000000")))
        XCTAssertEqual(ingest(driver(), "8906010064210000000000000000000000000000").map(\.kind), ["unknown"])
        XCTAssertEqual(ingest(driver(afterWriting: VeepooEncoder.glucoseStart()), "8903020101020000000000000000000000000000").map(\.kind),
                       ["unknown"])
        let stopped = driver(afterWriting: VeepooEncoder.stressStart())
        _ = stopped.frame(VeepooEncoder.stressStop())
        XCTAssertEqual(ingest(stopped, "8906010064210000000000000000000000000000").map(\.kind), ["unknown"])
    }

    func testTestFramesAreExact() {
        XCTAssertEqual(VeepooEncoder.stressStart().hexString, "890601" + String(repeating: "00", count: 17))
        XCTAssertEqual(VeepooEncoder.stressStop().hexString, "890602" + String(repeating: "00", count: 17))
        XCTAssertEqual(VeepooEncoder.glucoseStart().hexString, "89010100" + String(repeating: "00", count: 16))
        XCTAssertEqual(VeepooEncoder.glucoseStop().hexString, "89010200" + String(repeating: "00", count: 16))
        XCTAssertEqual(VeepooEncoder.bloodComponentsStart().hexString, "8a010100" + String(repeating: "00", count: 16))
        XCTAssertEqual(VeepooEncoder.bloodComponentsStop().hexString, "8a010200" + String(repeating: "00", count: 16))
        XCTAssertEqual(VeepooEncoder.findDeviceStart().hexString, "b50a" + String(repeating: "00", count: 18))
        XCTAssertEqual(VeepooEncoder.findDeviceStop().hexString, "b50b" + String(repeating: "00", count: 18))
    }

    // MARK: §4 Charging

    /// Real battery frame (`a0 00 …`, byte 1 = 0: every one of the 343 in the capture) and one with the
    /// charging byte set.
    func testChargingByte() {
        XCTAssertEqual(decoder.charging(frame: frameData("a000000010011001350e443dd20d0a0000000000")), false)
        XCTAssertEqual(decoder.charging(frame: frameData("a001000010011001350e443dd20d0a0000000000")), true)
        let events = ingest(driver(), "a001000039013901350e443dd20d0a0000000000")
        XCTAssertEqual(events.map(\.kind), ["battery", "charging_state"])
        guard case let .battery(percent) = events[0], case let .chargingState(charging) = events[1] else { return XCTFail() }
        XCTAssertEqual(percent, 57)
        XCTAssertTrue(charging)
    }

    // MARK: §5 New history metrics

    /// Real record 09-24 22:30 (`research/df_records.json`): B6 respiration, BF MET, B9 cardiac load, C2.
    func testNewHistoryTagsDecodeFromARealRecord() {
        let tlvs: [(UInt8, String)] = [
            (0xB1, "0918161e"), (0xB2, "00000000000000003600"), (0xB3, "0000000000ff"), (0xB4, "4000004040"),
            (0xB5, "0000000000"), (0xB6, "0bffffff0b"),
            (0xB7, "00ff5c64" + String(repeating: "ff", count: 47)),
            (0xB8, "7353"), (0xB9, "00000000000000000000000000000000000000001e00000000afeb40abab"),
            (0xBA, "0000000000"), (0xBE, "df01"), (0xBF, "0a"), (0xC1, "0d"), (0xC2, "a6018d006200f100fc07"),
        ]
        let payload = tlvs.flatMap { tag, value -> [UInt8] in
            let bytes = [UInt8](frameData(value))
            return [tag, UInt8(bytes.count)] + bytes
        }
        let record = decoder.dailyRecord(payload: payload)
        XCTAssertEqual(record?.respiration, [SlotSample(offset: 0, value: 11), SlotSample(offset: 4, value: 11)],
                       "0xFF = none, and the minute survives the filter (BUG-104)")
        XCTAssertEqual(record?.met ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(record?.cardiacLoad, [SlotSample(offset: 0, value: 30)])
        XCTAssertEqual(record?.oxygen, [], "SpO₂ group empty")
        let bc = record?.bloodComponents
        XCTAssertEqual(bc?.totalCholesterol ?? 0, 4.22, accuracy: 0.001)
        XCTAssertEqual(bc?.triglycerides ?? 0, 1.41, accuracy: 0.001)
        XCTAssertEqual(bc?.hdl ?? 0, 0.98, accuracy: 0.001)
        XCTAssertEqual(bc?.ldl ?? 0, 2.41, accuracy: 0.001)
        XCTAssertEqual(bc?.uricAcid ?? 0, 204.4, accuracy: 0.001)
    }

    func testAllZeroC2IsNoMeasurement() {
        let payload: [UInt8] = [0xB1, 0x04, 0x09, 0x18, 0x10, 0x19, 0xC2, 0x0A] + [UInt8](repeating: 0, count: 10)
        XCTAssertNil(decoder.dailyRecord(payload: payload)?.bloodComponents)
    }

    /// The 15-part real record flows through the engine into history samples for every new kind.
    func testEngineStoresTheNewKindsFromARealRecord() {
        let recorder = FrameRecorder()
        let engine = VeepooSyncEngine(writer: recorder, decoder: VeepooDecoder(), historyDays: 1)
        engine.isFeatureOn = { _ in false }
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        engine.handle(.unknown(commandId: 0xE0, raw: frameData("e0000000" + String(repeating: "00", count: 16))))
        for f in smallMtuRecord { engine.handle(.unknown(commandId: 0xDF, raw: frameData(f))) }
        engine.handle(.unknown(commandId: 0xDF, raw: frameData("dfffff58" + String(repeating: "00", count: 16))))
        XCTAssertEqual(recorder.values(.met), [1.0])
        XCTAssertEqual(recorder.values(.cardiacLoad), [30])
        XCTAssertEqual(recorder.values(.respiratoryRate), [], "B6 all 0xFF")
        XCTAssertEqual(recorder.values(.totalCholesterol).first ?? 0, 4.11, accuracy: 0.001)
        XCTAssertEqual(recorder.values(.triglycerides).first ?? 0, 1.34, accuracy: 0.001)
        XCTAssertEqual(recorder.values(.hdl).first ?? 0, 1.00, accuracy: 0.001)
        XCTAssertEqual(recorder.values(.ldl).first ?? 0, 2.31, accuracy: 0.001)
        XCTAssertEqual(recorder.values(.uricAcid).first ?? 0, 211.1, accuracy: 0.001)
        XCTAssertEqual(engine.crcFailures, 0)
        engine.connectionDidEnd()
    }

    func testHistoryGateAcceptsTheNewKinds() {
        let now = Date()
        for (kind, value) in [(MeasurementKind.met, 1.0), (.cardiacLoad, 30), (.totalCholesterol, 4.11),
                              (.triglycerides, 1.34), (.hdl, 1.0), (.ldl, 2.31), (.uricAcid, 211.1),
                              (.respiratoryRate, 16)] {
            XCTAssertEqual(RingEventBridge.events(for: .historyMeasurement(kind: kind, value: value, timestamp: now), now: now).count,
                           1, "\(kind)")
        }
        XCTAssertTrue(RingEventBridge.events(for: .historyMeasurement(kind: .met, value: 0.1, timestamp: now), now: now).isEmpty)
    }

    // MARK: §7 Auto-measure schedule

    /// Real `b3` read reply (three 125-byte frames): eight metric types; HR/BP/glucose/stress/HRV/blood
    /// components on every 30 min all day, SpO₂ every 60, the heart-rhythm scatter off (5 min, 00:00–06:00).
    func testRealAutoMeasureScheduleDecodes() {
        let frames = [
            "b3020101a0050318010000a121d00100d10100d20101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10101d20101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10102d20101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10103d2",
            "b30201020101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10104d20101d3023c00d4020101d50400000000d6023c00d70400000000a121d00100d10106d20100d3020500d4020000d50400000600d6020500d70400000600a121d00100d10107d20101d3021e00d4020101d50400000000",
            "b3020103d6021e00d70400000000a121d00100d10108d20101d3021e00d4020101d50400000000d6021e00d70400000000",
        ]
        let driver = driver()
        XCTAssertTrue(ingest(driver, frames[0]).isEmpty)
        XCTAssertTrue(ingest(driver, frames[1]).isEmpty)
        guard case let .autoMeasureSchedule(entries)? = ingest(driver, frames[2]).first else { return XCTFail() }
        XCTAssertEqual(entries.map(\.type), [0, 1, 2, 3, 4, 6, 7, 8])
        XCTAssertEqual(entries.first { $0.type == 0 }?.summary, "Every 30 min · all day")
        XCTAssertEqual(entries.first { $0.type == 4 }?.intervalMinutes, 60)
        let lorenz = entries.first { $0.type == 6 }
        XCTAssertEqual(lorenz?.enabled, false)
        XCTAssertEqual(lorenz?.intervalMinutes, 5)
        XCTAssertEqual(lorenz?.endHour, 6)
        XCTAssertEqual(lorenz?.summary, "Off")
        XCTAssertTrue(entries.filter { $0.type != 6 }.allSatisfy(\.enabled))
        XCTAssertEqual(AutoMeasureEntry.decodeList(AutoMeasureEntry.encodeList(entries)), entries)
    }

    func testAutoMeasureReadOnlyWhenFlagOn() {
        for flag in [false, true] {
            let recorder = FrameRecorder()
            let engine = VeepooSyncEngine(writer: recorder, decoder: VeepooDecoder(), historyDays: 1)
            engine.isFeatureOn = { $0 == .autoMeasureSettings ? flag : false }
            engine.connectionDidStart()
            engine.handle(.commandAck(commandId: 0xA1))
            XCTAssertEqual(recorder.commands.contains(VeepooEncoder.autoMeasureRead()), flag)
            engine.connectionDidEnd()
        }
        XCTAssertEqual(VeepooEncoder.autoMeasureRead().hexString, "b302" + String(repeating: "00", count: 18))
    }

    // MARK: §7 Profile sync

    func testProfileFrameLayout() {
        let values = UserProfileValues(metric: true, sex: "female", age: 34, heightCm: 168, weightKg: 61,
                                       stepGoal: 10000, sleepGoalMinutes: 450)
        // a3 <168> <61> <34> <0 = F> <10000 BE> <450 BE>
        XCTAssertEqual(VeepooEncoder.profile(values).hexString, "a3a83d2200271001c2" + String(repeating: "00", count: 11))
        XCTAssertEqual(decoder.profileAck(frame: frameData("a301000000000000000000000000000000000000")), true)
        XCTAssertEqual(decoder.profileAck(frame: frameData("a300000000000000000000000000000000000000")), false)
    }

    func testProfileSyncOnlyWhenFlagOn() {
        let profile = UserProfileValues(metric: true, sex: "male", age: 40, heightCm: 180, weightKg: 80)
        for flag in [false, true] {
            let recorder = FrameRecorder()
            let engine = VeepooSyncEngine(writer: recorder, decoder: VeepooDecoder(), historyDays: 1)
            engine.isFeatureOn = { $0 == .profileSync ? flag : false }
            engine.connectionDidStart()
            engine.setUserProfile(profile)
            engine.handle(.commandAck(commandId: 0xA1))
            XCTAssertEqual(recorder.commands.contains(VeepooEncoder.profile(profile)), flag)
            engine.applyUserProfile(profile)
            XCTAssertEqual(recorder.commands.filter { $0 == VeepooEncoder.profile(profile) }.count, flag ? 2 : 0)
            engine.connectionDidEnd()
        }
    }
}

// MARK: - Helpers

/// Records everything an engine writes / emits.
@MainActor
final class FrameRecorder: RingCommandWriter {
    var commands: [Data] = []
    var emitted: [RingDecodedEvent] = []
    func enqueue(_ command: Data) { commands.append(command) }
    func emit(_ event: RingDecodedEvent) { emitted.append(event) }

    func values(_ kind: MeasurementKind) -> [Double] {
        emitted.compactMap {
            if case let .historyMeasurement(k, value, _) = $0, k == kind { return value }
            return nil
        }
    }
}

enum CBUUIDs {
    static let command = CBUUID(string: VeepooUUIDs.commandNotify)
}

func frameData(_ value: String) -> Data {
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        data.append(UInt8(value[index..<next], radix: 16)!)
        index = next
    }
    return data
}
