import Foundation

/// What *this* ring says it can do, decoded from the four `a7` capability packets it pushes right after
/// the `a1` handshake (no request needed). Byte meanings follow the vendor SDK's parser, re-described in
/// `docs/ring/veepoo-protocol.md` (§6) and the measure-hub research; the package number is byte 19.
///
/// Our ring's packets (identical on every connect):
/// ```
/// P1 a7 01 00 00 01 02 01 00 08 14 00 02 00 00 00 01 00 fe 03 01
/// P2 a7 00 03 04 00 03 00 00 06 00 05 01 00 06 02 00 05 00 00 02
/// P3 a7 02 00 00 00 01 00 00 01 00 00 00 01 00 00 04 03 00 02 03
/// P4 a7 02 00 00 00 00 00 00 00 00 00 00 01 01 00 00 00 00 00 04
/// ```
/// Persisted on the device row (`Device.ringCapabilitiesJSON`) and read by the measure hub, which lists a
/// test only when this says the ring supports it (flag `capability_probe`). Same fields as Android's
/// `RingCapabilities`.
struct RingCapabilities: Codable, Equatable, Sendable {
    var heartRate = false
    var bloodPressure = false
    var spo2 = false
    var fatigue = false
    /// Any HRV support (P2.8 ∉ {0, 5}); `hrvAllDay` for types 3/4/6/7; `hrvTest` only for type 7.
    var hrv = false
    var hrvAllDay = false
    var hrvTest = false
    var breathing = false
    var ecg = false
    var temperature = false
    var stress = false
    var met = false
    var bloodGlucose = false
    /// The raw glucose tag (P3.15): 4 = detection + multi-point calibration, no risk levels.
    var glucoseType = 0
    var bloodComponents = false
    /// Single-point calibration available (P4.1 == 2).
    var bloodComponentsCalibration = false
    var bodyComposition = false
    var sportModes = false
    var findDevice = false
    var cameraShutter = false
    var autoMeasure = false
    /// Firmware-update protocol type (P3.16, the vendor's "CPU type"). Our rings report 3: the update runs on
    /// GATT service `F003` (research 05 §2). Nil until package 3 has arrived (optional, so rows stored before
    /// this field existed still decode).
    var otaType: Int?
    /// Days of history the ring keeps (P2.2).
    var historyDays = 0
    /// Which packages (1–5) have been seen — a value built from fewer than four is still usable, the
    /// missing bytes simply read as "unsupported".
    var packages: [Int] = []

    /// Decode from the raw packets keyed by package number (byte 19). Unknown/absent bytes read as 0.
    static func decode(packages raw: [Int: [UInt8]]) -> RingCapabilities {
        func byte(_ package: Int, _ index: Int) -> Int {
            guard let frame = raw[package], index < frame.count else { return 0 }
            return Int(frame[index])
        }
        var caps = RingCapabilities()
        caps.packages = raw.keys.sorted()
        // Package 1
        caps.bloodPressure = byte(1, 1) != 0
        caps.cameraShutter = [1, 2].contains(byte(1, 6))
        caps.fatigue = byte(1, 7) == 1
        caps.spo2 = byte(1, 8) != 0
        // Rate tag: 1 means "no heart rate"; a ring that sent no package 1 claims nothing.
        caps.heartRate = raw[1] != nil && byte(1, 18) != 1
        // Package 2
        caps.historyDays = byte(2, 2)
        caps.sportModes = byte(2, 5) != 0
        caps.breathing = byte(2, 7) != 0
        let hrvType = byte(2, 8)
        caps.hrv = hrvType != 0 && hrvType != 5
        caps.hrvAllDay = [3, 4, 6, 7].contains(hrvType)
        caps.hrvTest = hrvType == 7
        caps.ecg = byte(2, 15) != 0
        // Package 3
        caps.temperature = byte(3, 7) != 0
        caps.findDevice = byte(3, 8) != 0
        caps.glucoseType = byte(3, 15)
        caps.bloodGlucose = [1, 2, 4, 5, 6, 7, 8, 9].contains(caps.glucoseType)   // 3 = calibration only
        caps.met = byte(3, 17) == 2
        caps.stress = byte(3, 18) == 2
        caps.otaType = raw[3] != nil ? byte(3, 16) : nil
        // Package 4
        let componentTag = byte(4, 1)
        caps.bloodComponents = componentTag != 0
        caps.bloodComponentsCalibration = componentTag == 2
        caps.bodyComposition = byte(4, 2) == 1
        caps.autoMeasure = byte(4, 12) == 1
        return caps
    }

    /// Compact JSON for the device row and the debug feed.
    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    init() {}

    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RingCapabilities.self, from: data) else { return nil }
        self = decoded
    }
}

/// One row of the ring's automatic-measurement schedule (`b3` "Health & Monitor" read reply). Carries every
/// field of the row's `a1 21` TLV, so a `b3 01` set (`AutoMeasure.setFrames`) can write it back byte-exact
/// with only the on/off and interval changed (flag `auto_measure_settings`, research 03 §2.4).
struct AutoMeasureEntry: Codable, Equatable, Sendable, Identifiable {
    /// Ring type code: 0 heart rate, 1 blood pressure, 2 glucose, 3 stress, 4 SpO₂, 5 temperature,
    /// 6 Lorenz (HRV scatter), 7 HRV, 8 blood components.
    let type: Int
    var enabled: Bool
    var intervalMinutes: Int
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
    /// `d0` protocol byte (0 on our ring).
    var protocolVersion: Int = 0
    /// `d3` interval step in minutes — the ring accepts multiples of it (30 on ours, 60 for SpO₂, 5 Lorenz).
    var stepMinutes: Int = 0
    /// `d4` byte 0: the time window may be changed.
    var windowModifiable: Bool = false
    /// `d4` byte 1: the interval (and on/off) may be changed. Lorenz on our ring is locked (00 00).
    var intervalModifiable: Bool = false
    /// `d5` allowed window (sh sm eh em); 00:00–00:00 = all day.
    var allowedWindow: [Int] = [0, 0, 0, 0]

    var id: Int { type }

    init(type: Int, enabled: Bool, intervalMinutes: Int, startHour: Int, startMinute: Int, endHour: Int,
         endMinute: Int, protocolVersion: Int = 0, stepMinutes: Int = 0, windowModifiable: Bool = false,
         intervalModifiable: Bool = false, allowedWindow: [Int] = [0, 0, 0, 0]) {
        self.type = type
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.protocolVersion = protocolVersion
        self.stepMinutes = stepMinutes
        self.windowModifiable = windowModifiable
        self.intervalModifiable = intervalModifiable
        self.allowedWindow = allowedWindow
    }

    private enum CodingKeys: String, CodingKey {
        case type, enabled, intervalMinutes, startHour, startMinute, endHour, endMinute
        case protocolVersion, stepMinutes, windowModifiable, intervalModifiable, allowedWindow
    }

    /// Rows stored before the set fields existed decode with them zero (read-only until the next read).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Int.self, forKey: .type)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        startHour = try c.decode(Int.self, forKey: .startHour)
        startMinute = try c.decode(Int.self, forKey: .startMinute)
        endHour = try c.decode(Int.self, forKey: .endHour)
        endMinute = try c.decode(Int.self, forKey: .endMinute)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
        stepMinutes = try c.decodeIfPresent(Int.self, forKey: .stepMinutes) ?? 0
        windowModifiable = try c.decodeIfPresent(Bool.self, forKey: .windowModifiable) ?? false
        intervalModifiable = try c.decodeIfPresent(Bool.self, forKey: .intervalModifiable) ?? false
        allowedWindow = try c.decodeIfPresent([Int].self, forKey: .allowedWindow) ?? [0, 0, 0, 0]
    }

    /// A zero-length window (00:00–00:00) means all day, which is how the ring encodes it.
    var isAllDay: Bool { startHour == endHour && startMinute == endMinute }

    var title: String {
        switch type {
        case 0: return "Heart rate"
        case 1: return "Blood pressure"
        case 2: return "Blood glucose"
        case 3: return "Stress"
        case 4: return "Blood oxygen"
        case 5: return "Temperature"
        case 6: return "Heart-rhythm scatter"
        case 7: return "HRV"
        case 8: return "Blood components"
        default: return "Type \(type)"
        }
    }

    /// "Every 30 min · all day" / "Every 5 min · 00:00–06:00" / "Off".
    var summary: String {
        guard enabled else { return "Off" }
        let window = isAllDay
            ? "all day"
            : String(format: "%02d:%02d–%02d:%02d", startHour, startMinute, endHour, endMinute)
        return "Every \(intervalMinutes) min · \(window)"
    }

    static func encodeList(_ entries: [AutoMeasureEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeList(_ json: String?) -> [AutoMeasureEntry] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AutoMeasureEntry].self, from: data)) ?? []
    }
}

/// The five blood-component estimates (lipid panel + uric acid) — from the DF `C2` history tag or the
/// on-demand `8a 01` test. Raw integers are kept alongside the scaled values so reference-range checks
/// compare integers (the vendor's float compare flags HDL 0.96 as abnormal; we must not).
struct BloodComponentsReading: Equatable, Sendable {
    /// mmol/L ×100.
    let totalCholesterolRaw: Int
    let triglyceridesRaw: Int
    let hdlRaw: Int
    let ldlRaw: Int
    /// µmol/L ×10.
    let uricAcidRaw: Int

    var totalCholesterol: Double { Double(totalCholesterolRaw) / 100 }
    var triglycerides: Double { Double(triglyceridesRaw) / 100 }
    var hdl: Double { Double(hdlRaw) / 100 }
    var ldl: Double { Double(ldlRaw) / 100 }
    var uricAcid: Double { Double(uricAcidRaw) / 10 }

    var isEmpty: Bool {
        totalCholesterolRaw == 0 && triglyceridesRaw == 0 && hdlRaw == 0 && ldlRaw == 0 && uricAcidRaw == 0
    }

    /// The five values as (kind, canonical value) pairs — what persistence stores.
    var measurements: [(MeasurementKind, Double)] {
        [
            (.totalCholesterol, totalCholesterol), (.triglycerides, triglycerides),
            (.hdl, hdl), (.ldl, ldl), (.uricAcid, uricAcid),
        ]
    }
}

/// Why the ring refused (or abandoned) an on-demand measurement. Carried by
/// `RingDecodedEvent.measurementRejected`; the measurement sheet turns it into the shared wording.
enum MeasurementRefusal: String, Sendable, Equatable {
    case notWorn
    case busy
    case lowBattery
    case charging
    /// SpO₂ status 10: the ring does not say which — the app resolves it from the battery frame.
    case chargingOrLowBattery
    /// The ring answered "not supported" or a code we don't know.
    case refused

    /// The shared failure wording (spec §6), identical on Android.
    static let notWornMessage = "The ring isn't detecting your finger. Put it on snugly, then try again."
    static let busyMessage = "The ring is busy — try again in a moment."
    static let lowBatteryMessage = "The ring's battery is too low to measure."
    static let chargingMessage = "The ring is charging — measure when it's on your finger."

    /// The message for this refusal; nil for `.refused`, where the per-kind failure copy fits better.
    func message(isCharging: Bool) -> String? {
        switch self {
        case .notWorn: return Self.notWornMessage
        case .busy: return Self.busyMessage
        case .lowBattery: return Self.lowBatteryMessage
        case .charging: return Self.chargingMessage
        case .chargingOrLowBattery: return isCharging ? Self.chargingMessage : Self.lowBatteryMessage
        case .refused: return nil
        }
    }
}
