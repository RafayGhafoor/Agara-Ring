import Foundation

/// One decoded DF daily-history record (the B1…C2 TLV payload). This is a single 5-minute slot: the
/// ring stores 288 of them per day, and the verified capture decoded 107 such records for one day.
///
/// Values that PulseLoop has no `MeasurementKind` for (MET `BF`, the C2 lipid panel, B2 sport) are
/// deliberately **not** carried here — the standalone harness in `tools/` remains the complete
/// decoder; the app takes the metrics it can persist.
struct VeepooDailyRecord {
    /// Wall-clock slot start, month/day/hour/minute from B1 (the ring omits the year).
    let timestamp: Date
    var steps = 0
    var distanceMeters = 0
    var calories = 0.0
    /// Five one-minute HR values per slot (B4).
    var heartRates: [Int] = []
    /// HRV milliseconds (B7); 255 = absent sample.
    var hrv: [Int] = []
    var systolic = 0
    var diastolic = 0
    /// Five one-minute SpO₂ values per slot (B9, first five bytes only).
    var oxygen: [Int] = []
    /// Glucose in mg/dL (BE is mmol/L ×100; converted on decode).
    var glucoseMgdl = 0.0
    var stress = 0
}

/// E0 sleep summary (TLV field A3). The harness cross-check (Sep 11): start 00:41, end 05:24,
/// total 283 min, deep 60 / light 160 / awake 0 / other 63. The minute **counts** are hardware-
/// verified; the minute-by-minute *ordering* is not recoverable from this payload, so the engine
/// expands counts in the deep → light → awake → other order and documents the assumption.
struct VeepooSleepSummary {
    let start: Date
    let end: Date
    let totalMinutes: Int
    let deepMinutes: Int
    let lightMinutes: Int
    let awakeMinutes: Int
    let otherMinutes: Int
    let firstDeepMinutes: Int
    let quality: Int
    let efficiencyScore: Int
    let deepScore: Int

    var stages: [SleepStage] {
        [SleepStage](repeating: .deep, count: deepMinutes)
            + [SleepStage](repeating: .light, count: lightMinutes)
            + [SleepStage](repeating: .awake, count: awakeMinutes)
            + [SleepStage](repeating: .unknown, count: otherMinutes)
    }
}

/// Pure decode of the Veepoo frames this app ingests. No BLE, no state — mirrors the confirmed wire
/// mappings from `tasks/veepoo-protocol.md` / the hardware-verified harness in `tools/`.
struct VeepooDecoder {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// A0 reply: battery percent at payload byte 4.
    func battery(frame: Data) -> Int? {
        guard frame.count >= 5, frame[0] == VeepooOpcode.deviceInfo.rawValue else { return nil }
        return Int(frame[4])
    }

    /// D0 heartbeat-test stream (start `D0 01`): 1 Hz `D0 <bpm>`, 0 while warming up. Frame format
    /// pinned from live runs (the same decode `tools/veepoo_live.py` ships).
    func heartRate(frame: Data) -> Int? {
        guard frame.count >= 2, frame[0] == 0xD0 else { return nil }
        let bpm = Int(frame[1])
        return bpm > 0 ? bpm : nil
    }

    /// 0x80 blood-oxygen test stream (start `80 01 02`): `80 01 00 00 <spo2> 00 …`, warm-up frames
    /// read 0. Byte 4 as SpO₂ percent is byte-map-**assumed** (the live run saw it constant at 100) —
    /// the same caveat the python client carries; partial confidence until a varying reading lands.
    func oxygen(frame: Data) -> Int? {
        guard frame.count >= 5, frame[0] == 0x80 else { return nil }
        let spo2 = Int(frame[4])
        return (1...100).contains(spo2) ? spo2 : nil
    }

    /// 0x90 BP test stream (start `90 01 00`): progress % at byte 3 (4 %/s, ~25 s test), then the
    /// final frame `90 <systolic> <diastolic> 64 00 01 …`. Pinned from the live BP run.
    func bloodPressure(frame: Data) -> (systolic: Int, diastolic: Int)? {
        guard frame.count >= 6, frame[0] == 0x90, frame[3] == 100, frame[1] > 0, frame[2] > 0
        else { return nil }
        return (Int(frame[1]), Int(frame[2]))
    }

    /// D8 reply: steps / distance m / calories (×10), three LE u32s at payload bytes 2/6/10.
    /// Verified against the cloud record for the same minute (835 steps / 706 m / 41.1 kcal).
    func activity(frame: Data) -> (steps: Int, distanceMeters: Int, calories: Double)? {
        guard frame.count >= 14, frame[0] == VeepooOpcode.realtime.rawValue else { return nil }
        let steps = Int(frame[2]) | (Int(frame[3]) << 8) | (Int(frame[4]) << 16) | (Int(frame[5]) << 24)
        let distance = Int(frame[6]) | (Int(frame[7]) << 8) | (Int(frame[8]) << 16) | (Int(frame[9]) << 24)
        let caloriesTenths = Int(frame[10]) | (Int(frame[11]) << 8)
        return (steps, distance, Double(caloriesTenths) / 10)
    }

    /// FEA1 live-step notification: `01 <steps u16 LE> 00`, ~1 Hz. The value is the ring's
    /// **cumulative day total**, not a delta.
    func liveSteps(frame: Data) -> Int? {
        guard frame.count >= 3, frame[0] == 0x01 else { return nil }
        return Int(frame[1]) | (Int(frame[2]) << 8)
    }

    /// Decode one DF record from its reassembled (part 1 + part 2) payload — the B1…C2 TLV stream
    /// after the 4-byte frame header. `nil` when the record has no B1 timestamp (incomplete frame).
    func dailyRecord(payload: [UInt8]) -> VeepooDailyRecord? {
        let fields = veepooTLVFields(payload)
        guard let time = fields[0xB1], time.count >= 4,
              let timestamp = dateFromMonthDayHourMinute(Array(time[0..<4]))
        else { return nil }

        var record = VeepooDailyRecord(timestamp: timestamp)

        // B2: steps / sport / distance m / calories×10 — BE u16 pairs. Sport is unused by the app
        // (no workout-type mapping exists for the ring's sport codes).
        if let activity = fields[0xB2], activity.count >= 10 {
            record.steps = veepooUInt16BE(activity, 0)
            record.distanceMeters = veepooUInt16BE(activity, 4)
            record.calories = Double(veepooUInt16BE(activity, 6)) / 10
        }

        if let heart = fields[0xB4] {
            record.heartRates = heart.map(Int.init).filter { $0 > 25 && $0 < 250 }
        }
        if let hrv = fields[0xB7] {
            record.hrv = hrv.map(Int.init).filter { $0 > 0 && $0 < 255 }
        }
        if let pressure = fields[0xB8], pressure.count >= 2, pressure[0] > 0, pressure[1] > 0 {
            record.systolic = Int(pressure[0])
            record.diastolic = Int(pressure[1])
        }
        if let oxygen = fields[0xB9] {
            // Only the first five bytes are SpO₂ — the tail is metadata, never oxygen.
            record.oxygen = oxygen.prefix(5).map(Int.init).filter { $0 >= 50 && $0 <= 100 }
        }
        if let glucose = fields[0xBE], glucose.count >= 2 {
            let hundredths = veepooUInt16LE(glucose, 0)
            if hundredths > 0 {
                // Ring reports mmol/L ×100; the app stores mg/dL.
                record.glucoseMgdl = Double(hundredths) / 100 * 18.016
            }
        }
        if let stress = fields[0xC1]?.first, stress > 0 {
            record.stress = Int(stress)
        }
        return record
    }

    /// Decode the E0 sleep summary from the concatenated page payloads — `0xA1` header, then the TLV
    /// stream, whose A3 field is the 36+ byte sleep summary.
    func sleepSummary(payload: [UInt8]) -> VeepooSleepSummary? {
        guard payload.count >= 3, payload[0] == 0xA1 else { return nil }
        let fields = veepooTLVFields(Array(payload.dropFirst(3)))
        guard let summary = fields[0xA3], summary.count >= 29,
              let start = dateFromMonthDayHourMinute(Array(summary[0..<4])),
              let end = dateFromMonthDayHourMinute(Array(summary[4..<8]))
        else { return nil }

        let deep = veepooUInt16LE(summary, 19)
        let light = veepooUInt16LE(summary, 21)
        let other = veepooUInt16LE(summary, 23)
        let total = veepooUInt16LE(summary, 25)
        return VeepooSleepSummary(
            start: start,
            end: end,
            totalMinutes: total,
            deepMinutes: deep,
            lightMinutes: light,
            awakeMinutes: max(0, total - deep - light - other),
            otherMinutes: other,
            firstDeepMinutes: veepooUInt16LE(summary, 27),
            quality: Int(summary[15]),
            efficiencyScore: Int(summary[11]),
            deepScore: Int(summary[10])
        )
    }

    /// B1 payloads carry month/day/hour/minute with **no year**. Build the date in the current year;
    /// if that lands in the future, roll back a year (the ring's day-0 record covers today).
    private func dateFromMonthDayHourMinute(_ bytes: [UInt8]) -> Date? {
        guard bytes.count >= 4 else { return nil }
        let month = Int(bytes[0]), day = Int(bytes[1]), hour = Int(bytes[2]), minute = Int(bytes[3])
        guard (1...12).contains(month), (1...31).contains(day), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }

        let year = calendar.component(.year, from: Date())
        var components = DateComponents(
            calendar: calendar, year: year, month: month, day: day, hour: hour, minute: minute
        )
        guard let date = calendar.date(from: components), date <= Date() else {
            components.year = year - 1
            return calendar.date(from: components)
        }
        return date
    }
}