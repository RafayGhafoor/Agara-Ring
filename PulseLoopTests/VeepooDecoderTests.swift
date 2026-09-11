import XCTest
@testable import PulseLoop

/// Veepoo/TK20 decoder parity against the hardware-verified wire mappings in
/// `tasks/veepoo-protocol.md` and the `tools/` BLE harness. Pure — no hardware. The asserted values
/// are the ones the harness decoded from the real ring (battery 76 %, D8 835 steps / 706 m /
/// 41.1 kcal, sleep deep 60 / light 160 / other 63, etc.).
final class VeepooDecoderTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func decoder() -> VeepooDecoder {
        VeepooDecoder(calendar: calendar)
    }

    /// A0 reply: `a0 <pad×3> <percent> …` — battery from the harness capture (`a0 00 00 00 62 …`).
    func testBatteryFrameDecodesPercent() {
        let percent = decoder().battery(frame: Data([0xA0, 0x00, 0x00, 0x00, 0x4C]))
        XCTAssertEqual(percent, 76)
    }

    /// D8 reply, verbatim from the capture: three LE u32s — steps 835, distance 706 m, calories 41.1.
    func testRealtimeFrameDecodesActivity() {
        let frame = Data([0xD8, 0x00, 0x43, 0x03, 0x00, 0x00, 0xC2, 0x02, 0x00, 0x00, 0x9B, 0x01, 0x00, 0x00])
        let activity = decoder().activity(frame: frame)
        XCTAssertEqual(activity?.steps, 835)
        XCTAssertEqual(activity?.distanceMeters, 706)
        XCTAssertEqual(activity?.calories ?? 0, 41.1, accuracy: 0.01)
    }

    /// FEA1 live-step notification: `01 <u16 LE> 00` — 835 in the capture.
    func testLiveStepsFrameDecodes() {
        XCTAssertEqual(decoder().liveSteps(frame: Data([0x01, 0x43, 0x03, 0x00])), 835)
    }

    /// One DF record's TLV payload (parts 1+2 concatenated, headers stripped) — exercises every
    /// verified field mapping: B1 timestamp, B2 activity, B4 HR, B7 HRV, B8 BP, B9 SpO₂, BE glucose,
    /// C1 stress.
    func testDailyRecordDecodesAllFields() {
        var payload: [UInt8] = []
        // B1 — month 9, day 11, hour 10, minute 5 (UTC in tests).
        payload += [0xB1, 0x04, 0x09, 0x0B, 0x0A, 0x05]
        // B2 — steps 835, sport 0, distance 706, calories×10 411 (BE u16 pairs).
        payload += [0xB2, 0x0A, 0x03, 0x43, 0x00, 0x00, 0x02, 0xC2, 0x01, 0x9B, 0x00, 0x00]
        // B4 — five HR samples.
        payload += [0xB4, 0x05, 0x3C, 0x4B, 0x60, 0x55, 0x50]
        // B7 — HRV ms, 255 = absent.
        payload += [0xB7, 0x04, 0x2C, 0x5B, 0x6D, 0xFF]
        // B8 — systolic 116 / diastolic 83.
        payload += [0xB8, 0x02, 0x74, 0x53]
        // B9 — SpO₂ values in the first five bytes; the tail is metadata and must NOT decode as oxygen.
        payload += [0xB9, 0x07, 0x60, 0x61, 0x62, 0x63, 0x64, 0x00, 0xFF]
        // BE — glucose mmol/L ×100 LE (4.38 → 438 → 0x01B6).
        payload += [0xBE, 0x02, 0xB6, 0x01]
        // C1 — stress.
        payload += [0xC1, 0x01, 0x14]

        let record = decoder().dailyRecord(payload: payload)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.steps, 835)
        XCTAssertEqual(record?.distanceMeters, 706)
        XCTAssertEqual(record?.calories ?? 0, 41.1, accuracy: 0.01)
        XCTAssertEqual(record?.heartRates, [60, 75, 96, 85, 80])
        XCTAssertEqual(record?.hrv, [44, 91, 109])          // 255 dropped
        XCTAssertEqual(record?.systolic, 116)
        XCTAssertEqual(record?.diastolic, 83)
        XCTAssertEqual(record?.oxygen, [96, 97, 98, 99, 100]) // tail (0x00 0xFF) not oxygen
        XCTAssertEqual(record?.glucoseMgdl ?? 0, 4.38 * 18.016, accuracy: 0.01)
        XCTAssertEqual(record?.stress, 20)

        let components = calendar.dateComponents(
            [.month, .day, .hour, .minute], from: record!.timestamp
        )
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 5)
    }

    /// A record without a B1 timestamp (an incomplete frame pair) decodes to nil.
    func testDailyRecordWithoutTimestampIsNil() {
        let payload: [UInt8] = [0xB2, 0x0A, 0x03, 0x43, 0x00, 0x00, 0x02, 0xC2, 0x01, 0x9B, 0x00, 0x00]
        XCTAssertNil(decoder().dailyRecord(payload: payload))
    }

    /// E0 sleep pages → A3 summary. Counts match the verified harness decode (Sep 9→11 captures):
    /// 283 total, deep 60, light 160, other 63 → awake 0; start `09 0B 00 29` (Sep 11 00:41),
    /// end `09 0B 05 18` (05:24).
    func testSleepSummaryDecodesA3Durations() {
        var summaryBytes: [UInt8] = [0] * 29
        summaryBytes[0...3] = [0x09, 0x0B, 0x00, 0x29]    // start 09-11 00:41
        summaryBytes[4...7] = [0x09, 0x0B, 0x05, 0x18]    // end   09-11 05:24
        summaryBytes[11] = 90                            // efficiency score
        summaryBytes[15] = 3                             // quality
        summaryBytes[19] = 0x3C                          // deep 60 (LE16)
        summaryBytes[20] = 0x00
        summaryBytes[21] = 0xA0                          // light 160 (LE16)
        summaryBytes[22] = 0x00
        summaryBytes[23] = 0x3F                          // other 63 (LE16)
        summaryBytes[24] = 0x00
        summaryBytes[25] = 0x1B                          // total 283 (LE16)
        summaryBytes[26] = 0x01
        summaryBytes[27] = 0x23                          // first deep 35 (LE16)
        summaryBytes[28] = 0x00

        // Page payload: `a1 ?? ??` header then the TLV stream (`a3 1d <29-byte summary>`).
        var payload: [UInt8] = [0xA1, 0x01, 0x02, 0xA3, 0x1D]
        payload += summaryBytes

        let summary = decoder().sleepSummary(payload: payload)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.totalMinutes, 283)
        XCTAssertEqual(summary?.deepMinutes, 60)
        XCTAssertEqual(summary?.lightMinutes, 160)
        XCTAssertEqual(summary?.otherMinutes, 63)
        XCTAssertEqual(summary?.awakeMinutes, 0)    // total - deep - light - other
        XCTAssertEqual(summary?.quality, 3)
        XCTAssertEqual(summary?.efficiencyScore, 90)
        XCTAssertEqual(summary?.firstDeepMinutes, 35)

        let start = calendar.dateComponents([.day, .hour, .minute], from: summary!.start)
        XCTAssertEqual(start.day, 11)
        XCTAssertEqual(start.hour, 0)
        XCTAssertEqual(start.minute, 41)
        let end = calendar.dateComponents([.day, .hour, .minute], from: summary!.end)
        XCTAssertEqual(end.hour, 5)
        XCTAssertEqual(end.minute, 24)

        // Stage expansion keeps the verified counts, one minute each.
        let stages = summary!.stages
        XCTAssertEqual(stages.filter { $0 == .deep }.count, 60)
        XCTAssertEqual(stages.filter { $0 == .light }.count, 160)
        XCTAssertEqual(stages.filter { $0 == .awake }.count, 0)
        XCTAssertEqual(stages.filter { $0 == .unknown }.count, 63)
        XCTAssertEqual(stages.count, 283)
    }

    /// One-shot measurement streams, pinned by `tools/veepoo_live.py --measure`: D0 heart rate
    /// (1 Hz, 0 while warming up → nil), 0x80 oxygen (byte 4, warm-up 0 → nil), 0x90 BP (progress
    /// until the final frame).
    func testHeartRateStreamDecodes() {
        XCTAssertEqual(decoder().heartRate(frame: Data([0xD0, 0x4B])), 75)
        XCTAssertNil(decoder().heartRate(frame: Data([0xD0, 0x00])), "warm-up frames read 0")
    }

    func testOxygenStreamDecodes() {
        XCTAssertEqual(decoder().oxygen(frame: Data([0x80, 0x01, 0x00, 0x00, 0x61, 0x00])), 97)
        XCTAssertNil(decoder().oxygen(frame: Data([0x80, 0x01, 0x00, 0x00, 0x00, 0x00])), "warm-up reads 0")
        XCTAssertNil(decoder().oxygen(frame: Data([0x80, 0x01])), "too short")
    }

    func testBloodPressureStreamDecodes() {
        // Progress frames (byte 3 < 100) decode to nil; only the final 90 <sys> <dia> 64 00 01 … does.
        XCTAssertNil(decoder().bloodPressure(frame: Data([0x90, 0x00, 0x00, 0x4B, 0x00, 0x01])))
        let final = decoder().bloodPressure(frame: Data([0x90, 0x74, 0x53, 0x64, 0x00, 0x01]))
        XCTAssertEqual(final?.systolic, 116)
        XCTAssertEqual(final?.diastolic, 83)
        XCTAssertNil(decoder().bloodPressure(frame: Data([0x90, 0x00, 0x00, 0x64, 0x00, 0x01])),
                     "zero reading is not a final frame")
    }

    /// B1 dates land in the current year; a month/day that would be in the future rolls back a year.
    /// The contract asserted here is the shape that holds year-round: the requested month is kept and
    /// the decoded date is never in the future.
    func testDailyRecordTimestampNeverInTheFuture() {
        let components = calendar.dateComponents([.year, .month], from: Date())
        var futureMonth = components.month! + 1
        if futureMonth > 12 { futureMonth = 1 }
        let payload: [UInt8] = [0xB1, 0x04, UInt8(futureMonth), 0x01, 0x00, 0x00]
        let record = decoder().dailyRecord(payload: payload)
        XCTAssertNotNil(record)
        XCTAssertEqual(calendar.component(.month, from: record!.timestamp), futureMonth)
        XCTAssertLessThanOrEqual(record!.timestamp, Date())
        let decodedYear = calendar.component(.year, from: record!.timestamp)
        XCTAssertTrue(decodedYear == components.year! || decodedYear == components.year! - 1)
    }
}