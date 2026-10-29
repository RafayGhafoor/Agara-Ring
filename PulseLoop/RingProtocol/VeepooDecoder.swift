import Foundation

/// One value of a per-minute series and the minute **of its 5-minute slot** it was measured in (0…4).
///
/// The offset is carried through the "no sample" filter (BUG-104): a slot whose first minute is empty
/// (`B4 = 00 62 51 53 00`) measured 98, 81 and 83 at minutes 1, 2 and 3 — numbering the *survivors* from
/// zero stamped them a minute early, so the app claimed a heart rate for a minute the ring never read.
/// Android carries the same pair (`VeepooDecoder.perMinute`).
struct SlotSample: Equatable, Sendable {
    /// Minute of the slot, 0…4.
    let offset: Int
    let value: Int
}

/// One decoded DF daily-history record (the B1…C2 TLV payload). This is a single 5-minute slot: the
/// ring stores 288 of them per day, and the verified capture decoded 107 such records for one day.
///
/// B2 sport codes, B3/BA/BB sleep side-channels and the B9 apnea groups (all zero on our ring) are not
/// carried; the standalone harness in `tools/` remains the complete decoder.
struct VeepooDailyRecord {
    /// Wall-clock slot start, month/day/hour/minute from B1 (the ring omits the year).
    let timestamp: Date
    var steps = 0
    var distanceMeters = 0
    var calories = 0.0
    /// Five one-minute HR values per slot (B4).
    var heartRates: [SlotSample] = []
    /// HRV milliseconds per minute (B7, the vendor's reduction); absent minutes are dropped.
    var hrv: [SlotSample] = []
    var systolic = 0
    var diastolic = 0
    /// Five one-minute SpO₂ values per slot (B9, first five bytes only).
    var oxygen: [SlotSample] = []
    /// Glucose in mg/dL (BE is mmol/L ×100; converted on decode).
    var glucoseMgdl = 0.0
    var stress = 0
    /// Five one-minute respiration rates (B6), breaths/min; 0 and 0xFF = no value, dropped.
    var respiration: [SlotSample] = []
    /// MET for the slot (BF ÷ 10); 0 = none.
    var met = 0.0
    /// Five one-minute cardiac-load values (B9 bytes 20–24); 0 = none, dropped.
    var cardiacLoad: [SlotSample] = []
    /// Blood-component estimates (C2); nil when the tag is absent or all zero ("no measurement").
    var bloodComponents: BloodComponentsReading?
}

/// E0 sleep summary (TLV field A3) plus the `A5` per-minute timeline. The A3 field at offset 23, once
/// read as "other", is **REM**: it matched the vendor app's REM minute for minute (98 on 2026-09-25).
struct VeepooSleepSummary {
    let start: Date
    let end: Date
    let totalMinutes: Int
    let deepMinutes: Int
    let lightMinutes: Int
    let awakeMinutes: Int
    let remMinutes: Int
    let firstDeepMinutes: Int
    let quality: Int
    let efficiencyScore: Int
    let deepScore: Int
    /// `A3` bytes 29–30 — the ring's **own** awake-minute count. On real firmware it equals the `A5`
    /// timeline's awake minutes exactly; nil on a short `A3` (BUG-202).
    var statedAwakeMinutes: Int? = nil
    /// The `A1` block's declared length ran past the transfer, so the block is clamped and its curve
    /// (if any) is partial — the sync engine must re-ask the day instead of storing it (BUG-108/201).
    var blockOverrun = false
    /// Per-minute stages from `A5`, starting at `start`; nil when the block had no bitmap.
    var timeline: [SleepStage]? = nil

    /// One stage per minute from `start` — **only** the ring's own `A5` timeline.
    ///
    /// BUG-108: the counts used to be laid out as deep → light → REM → awake when the curve was absent or
    /// truncated, which is an invented hypnogram with the right totals (so nothing downstream noticed) and
    /// a wrong stage order (so the score, the chart and the coach were wrong). A session with no usable
    /// curve now yields no stages; the caller emits its counts instead of a made-up night.
    var stages: [SleepStage] { timeline ?? [] }
}

/// Pure decode of the Veepoo frames this app ingests. No BLE, no state — mirrors the confirmed wire
/// mappings from `tasks/veepoo-protocol.md` / the hardware-verified harness in `tools/`.
struct VeepooDecoder {
    var calendar: Calendar
    /// "Now" for the year the ring leaves out of every date. Injectable so a stored transfer (the raw
    /// packet repair) and the tests decode against the moment the frames were received, not today.
    var now: @Sendable () -> Date

    init(calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { AppClock.now }) {
        self.calendar = calendar
        self.now = now
    }

    /// A0 reply → battery percentage, by the vendor's byte rule (BUG-101): byte 4 is the **level** (0–4),
    /// byte 5 == 1 says byte 6 is the percentage, byte 7 == 2 is the ring's own low flag. This firmware
    /// (`a0 00 00 00 25 01 25 01`) copies the percentage into the level byte as well, which is why reading
    /// byte 4 alone looked right — on a unit that fills the level honestly it reads `3 %`, firing the
    /// critical-battery alert and blocking a firmware install.
    func battery(frame: Data) -> Int? {
        guard frame.count >= 5, frame[0] == VeepooOpcode.deviceInfo.rawValue else { return nil }
        let bytes = [UInt8](frame)
        if bytes.count >= 7, bytes[5] == 0x01 { return Int(bytes[6]) }
        let level = Int(bytes[4])
        return (0...4).contains(level) ? level * 25 : level
    }

    /// A0 byte 7 == 2: the ring's own "low battery" flag (BUG-101). Nil for a frame too short to carry it.
    func batteryLow(frame: Data) -> Bool? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 8, bytes[0] == VeepooOpcode.deviceInfo.rawValue else { return nil }
        return bytes[7] == 0x02
    }

    /// A0 byte 1: the ring's power mode — 1 = on the charger.
    func charging(frame: Data) -> Bool? {
        guard frame.count >= 2, frame[frame.startIndex] == VeepooOpcode.deviceInfo.rawValue else { return nil }
        return frame[frame.startIndex + 1] == 0x01
    }

    /// What one D0 frame means. Pinned against the real capture (`research/pulseloop.db`).
    enum HeartRateReply: Equatable {
        /// A bpm reading (warm-up zeros excluded).
        case bpm(Int)
        /// 0 while the sensor warms up.
        case warmingUp
        /// `d0 01 00 00 00 0a` — the ring's "already running / busy" answer to a re-asserted `d0 01`
        /// (394 of 394 in the capture, each within 1.5 s of our start). Never a bpm, never "not worn".
        case busy
        /// A plain `d0 01` / `d0 02` with nothing else: the sensor sees no finger.
        case notWorn
    }

    /// D0 heartbeat-test stream (start `D0 01`): 1 Hz `D0 <bpm> 00 00 00 <status>`.
    func heartRateReply(frame: Data) -> HeartRateReply? {
        guard frame.count >= 2, frame[frame.startIndex] == 0xD0 else { return nil }
        let bytes = [UInt8](frame)
        let value = Int(bytes[1])
        let status = bytes.count > 5 ? bytes[5] : 0
        if value == 1, status == 0x0A { return .busy }
        if value == 0 { return .warmingUp }
        if value == 1 || value == 2 { return status == 0 ? .notWorn : .busy }
        return .bpm(value)
    }

    /// The bpm in a D0 frame, or nil for warm-up / busy / not-worn frames.
    func heartRate(frame: Data) -> Int? {
        if case let .bpm(value)? = heartRateReply(frame: frame) { return value }
        return nil
    }

    /// 0x80 blood-oxygen stream (start `80 01 02`): `80 01 00 <spo2> 00 64 …` at ~1 Hz. **Byte 3** is the
    /// percentage — pinned from a real run on 2026-09-25: 0 for the first ~16 s (warm-up, dropped), then
    /// 96–99. Byte 4 (the earlier assumption) stays 0 throughout, which is why no SpO₂ ever decoded on the
    /// real ring. The ring's own stop reply `80 02 02 <spo2> …` repeats the last value; it is not a sample.
    func oxygen(frame: Data) -> Int? {
        guard frame.count >= 4, frame[frame.startIndex] == 0x80, frame[frame.startIndex + 1] == 0x01 else { return nil }
        guard oxygenRefusal(frame: frame) == nil else { return nil }
        let spo2 = Int(frame[frame.startIndex + 3])
        return (70...100).contains(spo2) ? spo2 : nil
    }

    /// SpO₂ device status (byte 2): 12 not worn, 10 charging / low battery; a value of 1 also means
    /// not worn. Only the running-test frames (`80 01 …`) carry it.
    func oxygenRefusal(frame: Data) -> MeasurementRefusal? {
        guard frame.count >= 4, frame[frame.startIndex] == 0x80, frame[frame.startIndex + 1] == 0x01 else { return nil }
        switch frame[frame.startIndex + 2] {
        case 12: return .notWorn
        case 10: return .chargingOrLowBattery
        default: break
        }
        return frame[frame.startIndex + 3] == 1 ? .notWorn : nil
    }

    /// 0x90 BP test stream (start `90 01 00`): `90 <sys> <dia> <progress %> <status> <has-progress>`,
    /// progress at +4 %/s (~25 s). A reading counts only at progress 100 **and** systolic ≥ 40 — the
    /// ring's answer to our stop, `90 01 00 00 00 01`, must never read as 1/0 mmHg.
    func bloodPressure(frame: Data) -> (systolic: Int, diastolic: Int)? {
        guard frame.count >= 6, frame[frame.startIndex] == 0x90 else { return nil }
        let bytes = [UInt8](frame)
        guard bytes[3] == 100, bytes[1] >= 40, bytes[2] > 0, bloodPressureRefusal(frame: frame) == nil else { return nil }
        return (Int(bytes[1]), Int(bytes[2]))
    }

    /// BP status byte 4: 252 not worn, 253 charging, 254 low battery, 1/2/4/5/255 busy.
    func bloodPressureRefusal(frame: Data) -> MeasurementRefusal? {
        guard frame.count >= 5, frame[frame.startIndex] == 0x90 else { return nil }
        switch frame[frame.startIndex + 4] {
        case 252: return .notWorn
        case 253: return .charging
        case 254: return .lowBattery
        case 1, 2, 4, 5, 255: return .busy
        default: return nil
        }
    }

    /// Progress or result of an on-demand test that reports `<status> <progress %> <value…>`.
    enum SpotTestReply: Equatable {
        case progress(Int)
        case result(Double)
        case refused(MeasurementRefusal)
        case stopped
    }

    /// Stress test (`89 06 …`): `89 06 01 <status> <progress %> <stress>`; status 0 = running, 1/3 busy,
    /// 2 low battery, 4 not worn. Final when progress hits 100 with a non-zero score. `89 06 02` = stopped.
    func stressReply(frame: Data) -> SpotTestReply? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 3, bytes[0] == 0x89, bytes[1] == 0x06 else { return nil }
        if bytes[2] == 0x02 { return .stopped }
        guard bytes[2] == 0x01, bytes.count >= 6 else { return nil }
        switch bytes[3] {
        case 0:
            let progress = Int(bytes[4])
            return progress >= 100 && bytes[5] > 0 ? .result(Double(bytes[5])) : .progress(progress)
        case 1, 3: return .refused(.busy)
        case 2: return .refused(.lowBattery)
        case 4: return .refused(.notWorn)
        default: return .refused(.refused)
        }
    }

    /// Glucose test (`89 01 …`): `89 01 <op> <status> <progress %> <value LE16>`; op 0 unsupported,
    /// 1 running, 2 stopped; status 2 low battery, 3 busy, 4 not worn. The value's low 13 bits ÷ 100 are
    /// mmol/L (the top 3 bits are a risk level our ring never sets). Final at progress ≥ 100.
    func glucoseReply(frame: Data) -> SpotTestReply? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 3, bytes[0] == 0x89, bytes[1] == 0x01 else { return nil }
        switch bytes[2] {
        case 0x00: return .refused(.refused)
        case 0x02: return .stopped
        case 0x01: break
        default: return nil
        }
        guard bytes.count >= 7 else { return nil }
        switch bytes[3] {
        case 2: return .refused(.lowBattery)
        case 3: return .refused(.busy)
        case 4: return .refused(.notWorn)
        default: break
        }
        let progress = Int(bytes[4])
        let hundredths = veepooUInt16LE(bytes, 5) & 0x1FFF
        return progress >= 100 && hundredths > 0 ? .result(Double(hundredths) / 100) : .progress(progress)
    }

    /// Blood-components test (`8a 01 …`): `8a 01 <b2> <state> <progress %> <UA> <TCHO> <TG> <HDL> <LDL>`,
    /// each LE16 from byte 5 — **uric acid first** (÷10 µmol/L), the lipids ÷100 mmol/L. This order differs
    /// from the DF `C2` tag, which puts uric acid last. `b2` 2 = stopped; state 1/3 busy, 2 low battery,
    /// 4 not worn. Final at progress 100 with any non-zero value.
    enum BloodComponentsReply: Equatable {
        case progress(Int)
        case result(BloodComponentsReading)
        case refused(MeasurementRefusal)
        case stopped
    }

    func bloodComponentsReply(frame: Data) -> BloodComponentsReply? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 3, bytes[0] == 0x8A, bytes[1] == 0x01 else { return nil }
        if bytes[2] == 0x02 { return .stopped }
        guard bytes.count >= 5 else { return nil }
        switch bytes[3] {
        case 0: break
        case 1, 3: return .refused(.busy)
        case 2: return .refused(.lowBattery)
        case 4: return .refused(.notWorn)
        default: return .refused(.refused)
        }
        let progress = Int(bytes[4])
        guard progress >= 100, bytes.count >= 15 else { return .progress(progress) }
        let reading = BloodComponentsReading(
            totalCholesterolRaw: veepooUInt16LE(bytes, 7), triglyceridesRaw: veepooUInt16LE(bytes, 9),
            hdlRaw: veepooUInt16LE(bytes, 11), ldlRaw: veepooUInt16LE(bytes, 13),
            uricAcidRaw: veepooUInt16LE(bytes, 5)
        )
        return reading.isEmpty ? .progress(progress) : .result(reading)
    }

    /// The `a1` handshake reply: `a1 00 00 <status> <device number BE16> <fw major> <minor> <patch> <test> …`.
    /// Firmware prints each byte as two hex digits, dot-joined — `00 12 09` → "00.12.09"; byte 9 extends it
    /// to the test version `00.12.09.00` (the key the firmware-update lookup sends). A frame too short to
    /// carry byte 9 reports the release version plus `.00`.
    func firmware(frame: Data) -> (deviceNumber: Int, version: String, testVersion: String)? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 9, bytes[0] == VeepooOpcode.open.rawValue else { return nil }
        let version = bytes[6...8].map { String(format: "%02x", $0) }.joined(separator: ".")
        let testByte = bytes.count >= 10 ? bytes[9] : 0
        return (veepooUInt16BE(bytes, 4), version, version + "." + String(format: "%02x", testByte))
    }

    /// The ring's identity from an `a1` reply, as the 16-hex AGB sensor id (docs/ring/storage-format.md §4): the MAC is
    /// bytes 12…17 **reversed** — the BLE-address order Android's `VeepooDecoder.ringMac` returns — hashed with the
    /// `agara.sensor.v1|ring|` prefix. Nil for a refusal (status byte 0), a short frame or an all-zero field.
    func ringSensorId(frame: Data) -> String? {
        AGB.ringMac(fromA1: [UInt8](frame)).flatMap { AGB.sensorId(ringMac: $0) }
    }

    /// The `a3` profile ack: `a3 01` ok, `a3 00` refused.
    func profileAck(frame: Data) -> Bool? {
        guard frame.count >= 2, frame[frame.startIndex] == 0xA3 else { return nil }
        return frame[frame.startIndex + 1] == 0x01
    }

    /// Decode the `b3` automatic-measurement read reply. Each frame is `b3 02 01 <seq>` + a slice of the
    /// body; joined, the body is a header TLV `a0 05 <frames> <len u32 LE>` then one `a1 21 {…}` block per
    /// metric type holding `d0` protocol · `d1` type · `d2` on · `d3` step LE16 · `d4` modifiable ·
    /// `d5` allowed window · `d6` interval min LE16 · `d7` active window (sh sm eh em).
    static func autoMeasureSchedule(body: [UInt8]) -> [AutoMeasureEntry] {
        var entries: [AutoMeasureEntry] = []
        var offset = 0
        while offset + 2 <= body.count {
            let tag = body[offset]
            let length = Int(body[offset + 1])
            guard tag != 0, offset + 2 + length <= body.count else { break }
            let value = Array(body[(offset + 2)..<(offset + 2 + length)])
            if tag == 0xA1 {
                let fields = veepooTLVFields(value)
                if let type = fields[0xD1]?.first {
                    let window = fields[0xD7] ?? fields[0xD5] ?? [0, 0, 0, 0]
                    entries.append(AutoMeasureEntry(
                        type: Int(type),
                        enabled: fields[0xD2]?.first == 1,
                        intervalMinutes: veepooUInt16LE(fields[0xD6] ?? [], 0),
                        startHour: window.count > 0 ? Int(window[0]) : 0,
                        startMinute: window.count > 1 ? Int(window[1]) : 0,
                        endHour: window.count > 2 ? Int(window[2]) : 0,
                        endMinute: window.count > 3 ? Int(window[3]) : 0,
                        protocolVersion: Int(fields[0xD0]?.first ?? 0),
                        stepMinutes: veepooUInt16LE(fields[0xD3] ?? [], 0),
                        windowModifiable: (fields[0xD4]?.first ?? 0) == 1,
                        intervalModifiable: (fields[0xD4].flatMap { $0.count > 1 ? $0[1] : nil } ?? 0) == 1,
                        allowedWindow: (fields[0xD5] ?? [0, 0, 0, 0]).prefix(4).map(Int.init)
                    ))
                }
            }
            offset += 2 + length
        }
        return entries
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
    ///
    /// `day` is the date the loop **asked the ring for** (see BUG-102); it is what dates the record.
    func dailyRecord(payload: [UInt8], day: Date? = nil) -> VeepooDailyRecord? {
        let fields = veepooTLVFields(payload)
        guard let time = fields[0xB1], time.count >= 4,
              let timestamp = dateFromMonthDayHourMinute(Array(time[0..<4]), on: day)
        else { return nil }

        var record = VeepooDailyRecord(timestamp: timestamp)

        // B2: steps / sport / distance m / calories×10 — BE u16 pairs. Sport is unused by the app
        // (no workout-type mapping exists for the ring's sport codes).
        if let activity = fields[0xB2], activity.count >= 10 {
            record.steps = veepooUInt16BE(activity, 0)
            record.distanceMeters = veepooUInt16BE(activity, 4)
            record.calories = Double(veepooUInt16BE(activity, 6)) / 10
        }

        // BUG-104: the minute is the sample's own index in the slot, carried through the "no sample"
        // filter. Numbering the survivors from zero moved every later value to the wrong minute as soon
        // as a slot's first minute was empty (record 167: `00 62 51 53 00` → minutes 1, 2, 3).
        if let heart = fields[0xB4] {
            record.heartRates = Self.perMinute(heart, in: 26...249)
        }
        if let hrv = fields[0xB7] {
            record.hrv = Self.hrvPerMinute(hrv)
        }
        if let pressure = fields[0xB8], pressure.count >= 2, pressure[0] > 0, pressure[1] > 0 {
            record.systolic = Int(pressure[0])
            record.diastolic = Int(pressure[1])
        }
        if let oxygen = fields[0xB9] {
            // Only the first five bytes are SpO₂ — the rest are other per-minute series, never oxygen.
            record.oxygen = Self.perMinute(Array(oxygen.prefix(5)), in: 50...100)
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
        // B6: five one-minute respiration rates; 0 and 0xFF are "no value".
        if let breath = fields[0xB6] {
            record.respiration = Self.perMinute(breath, in: 1...254)
        }
        // BF: MET ×10.
        if let met = fields[0xBF]?.first, met > 0, met < 255 {
            record.met = Double(met) / 10
        }
        // B9 is six groups of five per-minute values; group 5 (bytes 20–24) is cardiac load.
        if let group = fields[0xB9], group.count >= 25 {
            record.cardiacLoad = Self.perMinute(Array(group[20..<25]), in: 1...254)
        }
        // C2: five LE16 — cholesterol, triglycerides, HDL, LDL (÷100 mmol/L), uric acid (÷10 µmol/L).
        if let panel = fields[0xC2], panel.count >= 10 {
            let reading = BloodComponentsReading(
                totalCholesterolRaw: veepooUInt16LE(panel, 0), triglyceridesRaw: veepooUInt16LE(panel, 2),
                hdlRaw: veepooUInt16LE(panel, 4), ldlRaw: veepooUInt16LE(panel, 6),
                uricAcidRaw: veepooUInt16LE(panel, 8)
            )
            record.bloodComponents = reading.isEmpty ? nil : reading
        }
        return record
    }

    /// Decode the first session of an E0 transfer. Kept for callers that only ever expect one;
    /// the sync engine uses `sleepSummaries`, which returns every session.
    func sleepSummary(payload: [UInt8]) -> VeepooSleepSummary? {
        sleepSummaries(payload: payload).first
    }

    /// Every session in one E0 transfer, in order. The concatenated page payloads hold one `A1` block per
    /// session: `a1 <length LE16>` then that session's TLVs (`A2`, `A3` summary, `A4`, `A5` timeline, `A6`).
    /// The length counts the block's own 3-byte header, so the next block starts `length` bytes on. A
    /// declared length past the end of the data is clamped (the emulator's builds before 2026-09-25
    /// declared 268 for every block); a length under 3 ends the walk after this block. Page padding
    /// (zeros) after the last block ends it too. The vendor parser walks the same way (research 04 §A3).
    func sleepSummaries(payload: [UInt8]) -> [VeepooSleepSummary] {
        var summaries: [VeepooSleepSummary] = []
        var offset = 0
        while offset + 3 <= payload.count, payload[offset] == 0xA1 {
            let declared = veepooUInt16LE(payload, offset + 1)
            // X1 — an `A1` whose declared length runs past the payload means the transfer lost a page:
            // the block is clamped (as Android does) and **flagged**, so the engine can re-ask the day
            // instead of storing a night that is missing minutes (BUG-201, BUG-108).
            let overrun = offset + declared > payload.count
            let end = declared >= 3 ? min(payload.count, offset + declared) : payload.count
            if var summary = sessionSummary(block: Array(payload[(offset + 3)..<end])) {
                summary.blockOverrun = overrun
                summaries.append(summary)
            }
            guard declared >= 3 else { break }
            offset += declared
        }
        return summaries
    }

    /// One session's TLV stream (the body of an `A1` block), whose A3 field is the 36+ byte summary.
    private func sessionSummary(block: [UInt8]) -> VeepooSleepSummary? {
        let fields = veepooTLVFields(block)
        guard let summary = fields[0xA3], summary.count >= 29,
              let start = dateFromMonthDayHourMinute(Array(summary[0..<4])),
              let end = dateFromMonthDayHourMinute(Array(summary[4..<8]))
        else { return nil }

        let deep = veepooUInt16LE(summary, 19)
        let light = veepooUInt16LE(summary, 21)
        let rem = veepooUInt16LE(summary, 23)
        let total = veepooUInt16LE(summary, 25)
        // A2 (BUG-202): bytes 29–30 are the ring's **own** awake count — the number the app could only
        // derive from the curve before, so a short curve was invisible. Nil on a short (29-byte) `A3`.
        let statedAwake = summary.count >= 31 ? veepooUInt16LE(summary, 29) : nil
        return VeepooSleepSummary(
            start: start,
            end: end,
            totalMinutes: total,
            deepMinutes: deep,
            lightMinutes: light,
            awakeMinutes: max(0, total - deep - light - rem),
            remMinutes: rem,
            firstDeepMinutes: veepooUInt16LE(summary, 27),
            quality: Int(summary[15]),
            efficiencyScore: Int(summary[11]),
            deepScore: Int(summary[10]),
            statedAwakeMinutes: statedAwake,
            timeline: Self.sleepTimeline(block)
        )
    }

    /// The per-minute stage timeline from the `A5` bitmap: a **2-byte** LE minute count, then 2 bits per
    /// minute, MSB first — `0` deep, `1` light, `2` REM, `3` awake. Verified against the vendor app on
    /// 2026-09-25 (135/379/98/38 min, 38 runs; docs/process/plans/ui-charts-sleep.md). Every other tag
    /// in the block has a 1-byte length, which is why the generic TLV walker can't read this one.
    static func sleepTimeline(_ block: [UInt8]) -> [SleepStage]? {
        var offset = 0
        while offset + 2 <= block.count {
            let tag = block[offset]
            if tag == 0 { return nil }
            if tag == 0xA5 {
                guard offset + 3 <= block.count else { return nil }
                let minutes = veepooUInt16LE(block, offset + 1)
                let bitmap = offset + 3
                guard minutes > 0, bitmap + (minutes + 3) / 4 <= block.count else { return nil }
                return (0..<minutes).map { minute in
                    let byte = block[bitmap + minute / 4]
                    switch (byte >> (6 - 2 * UInt8(minute % 4))) & 0x03 {
                    case 0: return .deep
                    case 1: return .light
                    case 2: return .rem
                    default: return .awake
                    }
                }
            }
            offset += 2 + Int(block[offset + 1])
        }
        return nil
    }

    /// The per-minute series filter: every sample's **own** minute (0…4 in its slot) survives, so a slot
    /// whose first minute is empty keeps its later values on the minutes the ring measured them (BUG-104).
    private static func perMinute<S: Sequence>(_ values: S, in allowed: ClosedRange<Int>) -> [SlotSample]
    where S.Element == UInt8 {
        values.enumerated().compactMap { index, byte in
            let value = Int(byte)
            return allowed.contains(value) ? SlotSample(offset: index, value: value) : nil
        }
    }

    /// `B7` → the vendor's per-minute HRV (BUG-103). Byte 0 is the per-minute flags, bytes 1–50 are **ten
    /// raw samples per minute**; the vendor (`vp_ao.java:641-658`) reduces a minute to
    /// `round(10 × mean|successive Δ|)` over its samples in 30…210, `% 211`, and calls 0 "not computed".
    /// Reading each sample byte as "HRV ms" made every card value a raw amplitude, about twice the
    /// vendor's number (93/97 where the ring says 40) and 1–4 values per slot instead of one.
    private static func hrvPerMinute(_ hrv: [UInt8]) -> [SlotSample] {
        guard hrv.count >= 51 else { return [] }
        let samples = hrv[1..<51].map(Int.init)
        return (0..<5).compactMap { minute in
            var total = 0, pairs = 0, previous: Int?
            for value in samples[(minute * 10)..<(minute * 10 + 10)] where (30...210).contains(value) {
                if let previous { total += abs(previous - value); pairs += 1 }
                previous = value
            }
            let value = pairs == 0 ? 0 : Int((Double(total) * 10 / Double(pairs)).rounded()) % 211
            return value > 0 ? SlotSample(offset: minute, value: value) : nil
        }
    }

    /// The B1/A3 date carries month/day/hour/minute with **no year**; the ring never says which.
    ///
    /// * `on day` — a DF record is always answered inside the day the loop asked for, and the vendor SDK
    ///   dates it exactly that way (`vp_ao.java:563-577`: the requested day's date, B1's time of day). The
    ///   old rule built the date in the current year and rolled it back a **year** whenever it landed in
    ///   the future, so a ring clock a minute fast filed the newest records 365 days back and the
    ///   history-window gate then threw them away (BUG-102: 115 of 192 records in the real capture).
    /// * no day — a sleep `A3` arrives with no day request. A start a little ahead of the phone is the
    ///   ring's clock; take `now`. Anything further in the future cannot be dated, and a missing night is
    ///   recoverable where a year-old one is poison — so it is **dropped**.
    private func dateFromMonthDayHourMinute(_ bytes: [UInt8], on day: Date? = nil) -> Date? {
        guard bytes.count >= 4 else { return nil }
        let month = Int(bytes[0]), dayOfMonth = Int(bytes[1]), hour = Int(bytes[2]), minute = Int(bytes[3])
        guard (1...12).contains(month), (1...31).contains(dayOfMonth), (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }

        let reference = day ?? now()
        let components = DateComponents(
            calendar: calendar,
            year: calendar.component(.year, from: reference),
            // The requested day's month and day win: we asked for that day, so that is the day of the slot.
            month: day.map { _ in calendar.component(.month, from: reference) } ?? month,
            day: day.map { _ in calendar.component(.day, from: reference) } ?? dayOfMonth,
            hour: hour, minute: minute
        )
        guard let date = calendar.date(from: components) else { return nil }
        if day != nil { return date }
        let current = now()
        if date <= current { return date }
        // `< 10 min` ahead is the ring's RTC having drifted, not a different night.
        return date.timeIntervalSince(current) <= Self.futureTolerance ? current : nil
    }

    /// How far ahead of the phone a date-only field (`A3`) may be before it is treated as undateable.
    static let futureTolerance: TimeInterval = 10 * 60
}