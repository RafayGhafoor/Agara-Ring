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

    /// BUG-104 — a slot's five samples keep their own minutes through the "no sample" filter. Record 167
    /// of the 2026-09-25 capture (`B1 09 19 07 2d`, `B4 00 62 51 53 00`, slot 13:50) measured 98, 81 and
    /// 83 at minutes 1–3; numbering the survivors from zero stored them at 13:50–13:52.
    func testPerMinuteSeriesKeepTheirMinutesThroughTheFilter() {
        func record(_ tags: [UInt8]) -> VeepooDailyRecord? {
            decoder().dailyRecord(payload: [0xB1, 0x04, 0x09, 0x19, 0x07, 0x2D] + tags)
        }
        // B4 = `00 62 51 53 00`: measured at minutes 1, 2, 3 — not at 0, 1, 2.
        XCTAssertEqual(record([0xB4, 0x05, 0x00, 0x62, 0x51, 0x53, 0x00])?.heartRates,
                       [SlotSample(offset: 1, value: 98), SlotSample(offset: 2, value: 81),
                        SlotSample(offset: 3, value: 83)])
        // B9's first five bytes are SpO₂: the only value sat in minute 2.
        XCTAssertEqual(record([0xB9, 0x05, 0x00, 0x00, 0x61, 0x00, 0x00])?.oxygen,
                       [SlotSample(offset: 2, value: 97)])
        // B6 respiration keeps its minutes too (iOS lost these offsets entirely).
        XCTAssertEqual(record([0xB6, 0x05, 0x00, 0x0E, 0x0F, 0x10, 0x00])?.respiration,
                       [SlotSample(offset: 1, value: 14), SlotSample(offset: 2, value: 15),
                        SlotSample(offset: 3, value: 16)])
    }

    /// BUG-201/X1 — an `A1` block whose declared length runs past the payload is clamped, and the clamp is
    /// flagged: the transfer is partial, so the night it decodes cannot be trusted (BUG-108) and the day has
    /// to be re-asked.
    func testSleepBlockWhoseDeclaredLengthOverrunsThePayloadIsFlagged() {
        let full = SleepTransferFixtures.ringB1111
        let complete = decoder().sleepSummaries(payload: Self.payload(from: full))
        XCTAssertEqual(complete.count, 1)
        XCTAssertFalse(complete[0].blockOverrun, "a complete transfer is not flagged")
        XCTAssertEqual(complete[0].stages.count, 650)
        // The same 17-page run with page 9 missing: the `A1` length now runs past the payload.
        let truncated = full.filter { !$0.hasPrefix("e009") }
        let short = decoder().sleepSummaries(payload: Self.payload(from: truncated))
        XCTAssertEqual(short.count, 1)
        XCTAssertTrue(short[0].blockOverrun, "a clamped block must be flagged (X1/BUG-108)")
        XCTAssertEqual(short[0].totalMinutes, 650, "the ring's own A3 total is still 650")
    }

    /// BUG-202 — `A3` bytes 29–30 are the ring's own awake-minute count; iOS never read them, so the app's
    /// only "awake" number was the one it derived from the curve.
    func testSleepSummaryCarriesTheRingsOwnAwakeCount() {
        var summaryBytes = [UInt8](repeating: 0, count: 31)
        summaryBytes[0...3] = [0x09, 0x19, 0x00, 0x21]
        summaryBytes[4...7] = [0x09, 0x19, 0x0B, 0x0B]
        summaryBytes[19] = 0x87          // deep 135
        summaryBytes[21] = 0x7B          // light 379
        summaryBytes[22] = 0x01
        summaryBytes[23] = 0x62          // REM 98
        summaryBytes[25] = 0x8A          // total 650
        summaryBytes[26] = 0x02
        summaryBytes[29] = 0x26          // awake 38
        summaryBytes[30] = 0x00
        var payload: [UInt8] = [0xA1, 0x01, 0x02, 0xA3, 0x1F]
        payload += summaryBytes
        let summary = decoder().sleepSummary(payload: payload)
        XCTAssertEqual(summary?.totalMinutes, 650)
        XCTAssertEqual(summary?.statedAwakeMinutes, 38)
    }

    /// BUG-102 — a `B1` whose ring clock is a minute *ahead* used to be filed a **year** back (roll the
    /// year) and then dropped by the history-window gate. The day of a DF record is the day the loop asked
    /// for: only the time of day comes from the frame, exactly as the vendor SDK's date builder does.
    func testDailyRecordTakesItsDateFromTheRequestedDay() {
        let zone = TimeZone(identifier: "Asia/Karachi")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        // The phone is at 16:24:16 local; the ring's clock says 16:25 in the same slot.
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 16, minute: 24, second: 16))!
        let requestedDay = cal.startOfDay(for: now)
        let decoder = VeepooDecoder(calendar: cal, now: { now })
        let payload: [UInt8] = [0xB1, 0x04, 0x09, 0x18, 0x10, 0x19]
        let record = decoder.dailyRecord(payload: payload, day: requestedDay)
        XCTAssertEqual(record?.timestamp, cal.date(from: DateComponents(year: 2026, month: 9, day: 24,
                                                                      hour: 16, minute: 25))!)
    }

    /// BUG-102, the other half: a sleep `A3` with no day request. A start within ten minutes of the phone's
    /// clock is the ring running a little fast — take `now`; anything further in the future is undateable
    /// and the record is **dropped** rather than filed a year back.
    func testSleepRecordFarInTheFutureIsDroppedNotRolledBackAYear() {
        func summary(start: [UInt8], end: [UInt8]) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 31)
            for (i, byte) in start.enumerated() { bytes[i] = byte }
            for (i, byte) in end.enumerated() { bytes[4 + i] = byte }
            bytes[25] = 0x10
            var payload: [UInt8] = [0xA1, 0x01, 0x02, 0xA3, 0x1F]
            payload += bytes
            return payload
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Ring clock 30 hours ahead of the phone (a unit set in another timezone).
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 10, minute: 0))!
        let skewed = VeepooDecoder(calendar: cal, now: { now })
        XCTAssertNil(skewed.sleepSummary(payload: summary(start: [0x09, 0x1A, 0x16, 0x00],
                                                         end: [0x09, 0x1B, 0x06, 0x00])))
        // Two minutes ahead: the ring's clock, not a different night — the record is kept and dated `now`.
        let nearFuture = summary(start: [0x09, 0x18, 0x0A, 0x02], end: [0x09, 0x18, 0x09, 0x30])
        let kept = VeepooDecoder(calendar: cal, now: { now })
        XCTAssertEqual(kept.sleepSummary(payload: nearFuture)?.start, now, "a 2-minute lead is the ring's clock")
    }

    private static func payload(from pages: [String]) -> [UInt8] {
        pages.map(SleepTransferFixtures.bytes).sorted { $0[1] > $1[1] }.flatMap { $0.dropFirst(4) }
    }

    /// A0 reply: `a0 <pad×3> <percent> …` — battery from the harness capture (`a0 00 00 00 62 …`).
    func testBatteryFrameDecodesPercent() {
        let percent = decoder().battery(frame: Data([0xA0, 0x00, 0x00, 0x00, 0x4C]))
        XCTAssertEqual(percent, 76)
    }

    /// BUG-101 — the vendor's `A0` byte rule: byte 4 is the **level** (0–4), byte 5 == 1 says byte 6 is the
    /// percentage, byte 7 == 2 is the ring's own low-battery flag. A unit whose firmware fills the level
    /// honestly used to read `3 %` (a false critical-battery alert).
    func testBatteryFollowsTheVendorByteRule() {
        // Level 3, "byte 6 is a percentage", 63 %: the percentage, not the level.
        let vendor = Data([0xA0, 0x00, 0x00, 0x00, 0x03, 0x01, 0x3F, 0x01])
        XCTAssertEqual(decoder().battery(frame: vendor), 63)
        // No percentage flag: byte 4 is a level — 2 of 4 → a rough 50 %.
        let level = Data([0xA0, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(decoder().battery(frame: level), 50)
        // This firmware's shape (`a0 00 00 00 25 01 25 01`): both bytes agree at 37.
        let capture = Data([0xA0, 0x00, 0x00, 0x00, 0x25, 0x01, 0x25, 0x01])
        XCTAssertEqual(decoder().battery(frame: capture), 37)
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
        // B7 — a full 51-byte HRV field; the reduction itself is pinned by `testHRVUsesTheVendorReduction`.
        // A short B7 is malformed (the ring always sends 51 bytes) and yields no HRV rather than raw samples.
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
        XCTAssertEqual(record?.heartRates, [60, 75, 96, 85, 80].enumerated().map { SlotSample(offset: $0.offset, value: $0.element) })
        XCTAssertEqual(record?.hrv, [], "a 4-byte B7 is malformed — no per-minute HRV in it")
        XCTAssertEqual(record?.systolic, 116)
        XCTAssertEqual(record?.diastolic, 83)
        XCTAssertEqual(record?.oxygen.map(\.value), [96, 97, 98, 99, 100]) // tail (0x00 0xFF) not oxygen
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
        var summaryBytes = [UInt8](repeating: 0, count: 29)
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
        XCTAssertEqual(summary?.remMinutes, 63)     // A3 offset 23 — REM, not "other"
        XCTAssertEqual(summary?.awakeMinutes, 0)    // total - deep - light - REM
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

        // BUG-108: no A5 bitmap in this synthetic payload — the summary's counts are real, the *order* is
        // not, so no stage list is produced at all. Fabricating deep → light → REM → awake put a straight
        // four-run hypnogram (and a score computed from it) where the ring gave no curve.
        XCTAssertNil(summary?.timeline)
        XCTAssertTrue(summary!.stages.isEmpty)
    }

    /// BUG-103 — `B7` is 51 bytes: byte 0 = per-minute flags, bytes 1–50 = ten raw samples per minute. The
    /// vendor reduces a minute to `round(10 × mean|Δ|)` over the samples in 30…210, `% 211`. Reading each
    /// sample byte as "HRV ms" is what made the card show 93 and 97 for a minute the ring called 40.
    func testHRVUsesTheVendorReduction() {
        var payload: [UInt8] = [0xB1, 0x04, 0x09, 0x19, 0x00, 0x00]
        payload += [0xB7, 0x33, 0x00, 0xFF, 0x5D, 0x61] + [UInt8](repeating: 0xFF, count: 47)
        let record = decoder().dailyRecord(payload: payload)
        XCTAssertNotNil(record)
        // Minute 0's samples are 93, 97 → |93 − 97| × 10 = 40; every other minute is `FF` filler → dropped.
        XCTAssertEqual(record!.hrv, [SlotSample(offset: 0, value: 40)])
        // 0x5C 0x58 = 92, 88 → |Δ| 4 → 40.
        var second: [UInt8] = [0xB1, 0x04, 0x09, 0x19, 0x01, 0x00]
        second += [0xB7, 0x33, 0x00, 0x5C, 0x58, 0x4F, 0x57] + [UInt8](repeating: 0xFF, count: 46)
        XCTAssertEqual(decoder().dailyRecord(payload: second)?.hrv, [SlotSample(offset: 0, value: 70)])
    }

    /// Real pages, 2026-09-25 night, cross-checked against the vendor app: deep 2h15, light 6h19, REM 1h38,
    /// awake 38m over 00:21–11:11. Same fixture as Android's `VeepooDecoderTest`.
    func testSleepA5BitmapDecodesTheRealTimelineWithREM() {
        let pages = [
            "e00001000000000000555555a602000000000000", "e00101000000000000000015555555aaaaa00000",
            "e0020100aaaaa5555000005555555555aaaaaaa8", "e0030100aaa55500157fffffffff555555aaaaaa",
            "e0040100aa9555555555557fffff55555555aaaa", "e0050100555555556aaa800000005555555555aa",
            "e006010000001555555555555555555555500155", "e007010055555555555400556aaaaaaaaa800000",
            "e008010055540055400555555555555555555555", "e0090100400ffff5555555555555555555555555",
            "e00a01000000a58a025555555555555555555555", "e00b010000000000000000000000000000000000",
            "e00c010000000000000000000000000000000000", "e00d01003c0002a42d0000000000000000000000",
            "e00e0100000087007b0162008a022d0026002f00", "e00f010019001509190b0b030000000101000003",
            "e0100100a10c01a208bf1730cf28f1396ea32409",
        ].map { hex -> [UInt8] in
            stride(from: 0, to: hex.count, by: 2).map {
                let i = hex.index(hex.startIndex, offsetBy: $0)
                return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
            }
        }
        // Assemble like the engine: descending page index, 4-byte frame header stripped.
        let payload = pages.sorted { $0[1] > $1[1] }.flatMap { $0.dropFirst(4) }

        let summary = decoder().sleepSummary(payload: payload)
        let timeline = summary?.timeline ?? []
        XCTAssertEqual(timeline.count, 650)
        XCTAssertEqual(timeline.filter { $0 == .deep }.count, 135)
        XCTAssertEqual(timeline.filter { $0 == .light }.count, 379)
        XCTAssertEqual(timeline.filter { $0 == .rem }.count, 98)
        XCTAssertEqual(timeline.filter { $0 == .awake }.count, 38)
        XCTAssertEqual(summary?.remMinutes, 98)
        XCTAssertEqual(summary?.awakeMinutes, 38)
        XCTAssertTrue(timeline.prefix(45).allSatisfy { $0 == .light })   // first deep after 45 min
        XCTAssertEqual(timeline[45], .deep)
        XCTAssertEqual(summary?.stages, timeline)
        XCTAssertEqual(zip(timeline, timeline.dropFirst()).filter { $0 != $1 }.count + 1, 38)
    }

    /// One-shot measurement streams, pinned by `tools/veepoo_live.py --measure`: D0 heart rate
    /// (1 Hz, 0 while warming up → nil), 0x80 oxygen (byte 4, warm-up 0 → nil), 0x90 BP (progress
    /// until the final frame).
    func testHeartRateStreamDecodes() {
        XCTAssertEqual(decoder().heartRate(frame: Data([0xD0, 0x4B])), 75)
        XCTAssertNil(decoder().heartRate(frame: Data([0xD0, 0x00])), "warm-up frames read 0")
    }

    func testOxygenStreamDecodes() {
        // Real frames, 2026-09-25: the value is byte 3; byte 4 is always 0.
        XCTAssertEqual(decoder().oxygen(frame: Data([0x80, 0x01, 0x00, 0x60, 0x00, 0x64])), 96)
        XCTAssertEqual(decoder().oxygen(frame: Data([0x80, 0x01, 0x00, 0x63, 0x00, 0x64])), 99)
        XCTAssertNil(decoder().oxygen(frame: Data([0x80, 0x01, 0x00, 0x00, 0x00, 0x64])), "warm-up reads 0")
        XCTAssertNil(decoder().oxygen(frame: Data([0x80, 0x02, 0x02, 0x62, 0x00, 0x64])), "the ring's stop reply")
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

    /// BUG-102: without a requested day there is nothing to anchor a `B1` to, so a slot that decodes more
    /// than ten minutes into the future is **dropped**. It used to be rolled back a year, which stored a
    /// phantom day and then had the record thrown away by the history-window gate.
    func testDailyRecordWithoutARequestedDayDropsAFutureSlot() {
        let components = calendar.dateComponents([.year, .month], from: Date())
        var futureMonth = components.month! + 1
        if futureMonth > 12 { futureMonth = 1 }
        let payload: [UInt8] = [0xB1, 0x04, UInt8(futureMonth), 0x01, 0x00, 0x00]
        XCTAssertNil(decoder().dailyRecord(payload: payload))
    }
}