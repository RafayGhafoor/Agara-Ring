import Foundation
@preconcurrency import CoreBluetooth

/// GATT topology for the Veepoo / TK20 ring family (the "H Ring" vendor app, `cn.hring.veepoo`).
///
/// The ring carries **two** command channels: the FEE7 legacy data service (where the recon-phase
/// experiments were answered with silence and a ~10 s disconnect) and the F008 OTA/DFU service. Only
/// the **F008** channel accepts the session handshake — every verified read in this project went
/// through `F0080003` (write) + `F0080002` (notify), with `F0020002` subscribed as the password-notify
/// channel. `FEA1` (in FEE7) carries the ~1 Hz live-step notification.
///
/// The full transport story lives in `docs/hardware/veepoo.md`.
enum VeepooUUIDs {
    static let commandService = "F0080001-0451-4000-B000-000000000000"
    static let commandNotify = "F0080002-0451-4000-B000-000000000000"
    static let commandWrite = "F0080003-0451-4000-B000-000000000000"
    static let passwordService = "F0020001-0451-4000-B000-000000000000"
    static let passwordNotify = "F0020002-0451-4000-B000-000000000000"
    static let legacyService = "FEE7"
    /// 16-bit handle; `CBUUID(string:)` normalizes to the 128-bit form, so comparisons are safe.
    static let liveSteps = "FEA1"
}

/// Opcodes this app actually sends or decodes. The vendor frames a much wider map (A3/A6/A7/B8/D3/
/// DA/B3 — see the recon doc) — everything here is the verified working subset.
enum VeepooOpcode: UInt8 {
    /// Session open (app→ring) / identity (ring→app). Carries the local wall-clock.
    case open = 0xA1
    /// Device info — battery percent at payload byte 4.
    case deviceInfo = 0xA0
    /// Realtime sport: steps / distance m / calories×10, three LE u32s.
    case realtime = 0xD8
    /// Sleep history pages (E0 00/01 + day offset).
    case sleepHistory = 0xE0
    /// Daily history records (DF <recordIndex BE16> <part> <day-0 TLV>).
    case dailyHistory = 0xDF
    /// Session/app config, sent once right after auth.
    case sessionConfig = 0xF4
}

/// Outbound frames for the F008 channel. All 20 bytes, opcode first, zero-padded — except the A1
/// open frame, which the harness that cracked the channel sent **unpadded** (15 bytes) and which the
/// ring answered; keep it that way.
enum VeepooEncoder {
    /// Bytes 12–13 carry the phone's timezone the way the vendor SDK builds them: `01`, then the UTC
    /// offset in 15-minute steps as a signed byte (+05:00 → `01 14`, −10:00 → `01 d8`). The frame used to
    /// send a constant `00 d8` there (UTC−10) whatever the phone's zone was.
    static func authentication(now: Date = Date(), calendar: Calendar = .current,
                               timeZone: TimeZone? = nil) -> Data {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = UInt16(components.year ?? 0)
        let zone = timeZone ?? calendar.timeZone
        return Data([
            0xA1, 0x00, 0x00, 0x00,
            UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF),
            UInt8(components.month ?? 0), UInt8(components.day ?? 0),
            UInt8(components.hour ?? 0), UInt8(components.minute ?? 0),
            UInt8(components.second ?? 0),
            0x01, 0x01, utcOffsetQuarterHours(zone, at: now), 0x00,
        ])
    }

    /// The zone's UTC offset at `date` in 15-minute steps, as a two's-complement byte.
    static func utcOffsetQuarterHours(_ zone: TimeZone, at date: Date = Date()) -> UInt8 {
        let steps = zone.secondsFromGMT(for: date) / 900
        return UInt8(bitPattern: Int8(clamping: steps))
    }

    static func session() -> Data { padded([0xF4, 0x02, 0x02, 0x00, 0x01]) }
    static func battery() -> Data { padded([0xA0]) }
    static func steps() -> Data { padded([0xD8]) }
    static func sleepHistory(dayOffset: Int) -> Data { padded([0xE0, UInt8(clamping: dayOffset)]) }

    /// Daily-record request `DF <posLo> <posHi> <day>`: a 1-based record position (LE u16) to start from,
    /// then the day offset (spec §4; vendor SDK layout, decompile `kf/l1.java:1088-1092`). Position 1 = the
    /// whole day. The frame used to be `DF 01 <day> 00`, which the ring reads as position `day*256+1` of
    /// **day 0** — right for day 0 by accident, and for every past day an immediate `DF FF FF` with no
    /// records. Same builder as Android's `VeepooEncoder.dailyHistory`.
    static func dailyHistory(dayOffset: Int, position: Int = 1) -> Data {
        let pos = min(max(position, 1), 0xFFFF)
        return padded([0xDF, UInt8(pos & 0xFF), UInt8((pos >> 8) & 0xFF), UInt8(clamping: dayOffset)])
    }

    // One-shot measurements, from the SDK's per-test builders (veepooSDKTestHeartStart /
    // TestOxygenStart / TestBloodStart) — the same frames `tools/veepoo_live.py --measure` sends.
    // All starts share byte [1] == 0x01; stops use 0x00 (D0/0x90) or 0x02 (0x80). The driver keys its
    // measurement latch off that byte.
    static func heartRateStart() -> Data { padded([0xD0, 0x01]) }
    static func heartRateStop() -> Data { padded([0xD0, 0x00]) }
    static func oxygenStart() -> Data { padded([0x80, 0x01, 0x02]) }
    static func oxygenStop() -> Data { padded([0x80, 0x02, 0x02]) }
    static func bloodPressureStart() -> Data { padded([0x90, 0x01, 0x00]) }
    static func bloodPressureStop() -> Data { padded([0x90, 0x00, 0x00]) }

    // Tests that share opcodes with others route on byte 1 (0x89: 01 glucose, 06 stress; 0x8A: 01 blood
    // components); byte 2 is start (01) / stop (02). Standard (uncalibrated) mode throughout.
    static func stressStart() -> Data { padded([0x89, 0x06, 0x01]) }
    static func stressStop() -> Data { padded([0x89, 0x06, 0x02]) }
    static func glucoseStart() -> Data { padded([0x89, 0x01, 0x01, 0x00]) }
    static func glucoseStop() -> Data { padded([0x89, 0x01, 0x02, 0x00]) }
    static func bloodComponentsStart() -> Data { padded([0x8A, 0x01, 0x01, 0x00]) }
    static func bloodComponentsStop() -> Data { padded([0x8A, 0x01, 0x02, 0x00]) }

    /// Read the automatic-measurement schedule (`b3 02`); the ring answers with multi-frame `b3 02 01 <seq>`.
    static func autoMeasureRead() -> Data { padded([0xB3, 0x02]) }

    /// Find ring: the ring vibrates until `findDeviceStop` (or its own timeout).
    static func findDeviceStart() -> Data { padded([0xB5, 0x0A]) }
    static func findDeviceStop() -> Data { padded([0xB5, 0x0B]) }

    /// Profile + goals (`a3`): height cm, weight kg, age, sex (1 male / 0 female), step goal BE16, sleep
    /// goal in minutes BE16. The ring answers `a3 01` (ok) / `a3 00`.
    static func profile(_ values: UserProfileValues) -> Data {
        let steps = UInt16(clamping: max(0, values.stepGoal))
        let sleep = UInt16(clamping: max(0, values.sleepGoalMinutes))
        return padded([
            0xA3, values.heightCm, values.weightKg, values.age, values.gender == 0x00 ? 0x00 : 0x01,
            UInt8(steps >> 8), UInt8(steps & 0xFF), UInt8(sleep >> 8), UInt8(sleep & 0xFF),
        ])
    }

    private static func padded(_ bytes: [UInt8]) -> Data {
        var frame = bytes
        frame.append(contentsOf: repeatElement(0, count: max(0, 20 - frame.count)))
        return Data(frame.prefix(20))
    }
}

/// Parse a TLV stream (tag, length, payload). Stops at a zero tag or a truncated field — the same
/// walk the verified harness uses, so a trailing pixel of the frame is never misread as a tag.
func veepooTLVFields(_ bytes: [UInt8]) -> [UInt8: [UInt8]] {
    var fields: [UInt8: [UInt8]] = [:]
    var offset = 0
    while offset + 2 <= bytes.count {
        let tag = bytes[offset]
        let length = Int(bytes[offset + 1])
        guard tag != 0, offset + 2 + length <= bytes.count else { break }
        fields[tag] = Array(bytes[(offset + 2)..<(offset + 2 + length)])
        offset += 2 + length
    }
    return fields
}

func veepooUInt16LE(_ bytes: [UInt8], _ offset: Int) -> Int {
    guard bytes.count >= offset + 2 else { return 0 }
    return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
}

func veepooUInt16BE(_ bytes: [UInt8], _ offset: Int) -> Int {
    guard bytes.count >= offset + 2 else { return 0 }
    return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
}

/// CRC-16/MODBUS (poly 0xA001 reflected, init 0xFFFF) — the checksum in a DF record's part-00 header
/// (bytes 11–12, LE) over the reassembled payload's first `valid` bytes (byte 10).
func veepooCRC16Modbus(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
        crc ^= UInt16(byte)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
        }
    }
    return crc
}
