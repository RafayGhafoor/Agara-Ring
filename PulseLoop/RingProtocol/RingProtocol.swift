import Foundation
enum RingProtocolError: Error {
    case invalidLength(Int)
    case invalidHex(String)
}
enum RingDecodedEvent: Sendable {
    case activityUpdate(timestamp: Date, steps: Int, distanceMeters: Double, calories: Double)
    /// One intraday activity bucket (e.g. a the ring quarter-hour history sample). Unlike the cumulative
    /// `activityUpdate`, buckets are *summed* into the day — so live vs. history aggregate correctly.
    /// Calories are intentionally omitted (the ring's calorie field is unverified).
    case activityBucket(timestamp: Date, steps: Int, distanceMeters: Double)
    case heartRateSample(bpm: Int, timestamp: Date)
    case heartRateComplete(timestamp: Date)
    case spo2Progress(percent: Int?, timestamp: Date)
    case spo2Result(value: Int, timestamp: Date)
    case spo2Complete(timestamp: Date)
    case sleepTimeline(timestamp: Date, stages: [SleepStage])
    case historyMeasurement(kind: MeasurementKind, value: Double, timestamp: Date)
    case stressSample(value: Int, timestamp: Date)
    case hrvSample(value: Int, timestamp: Date)            // milliseconds
    case temperatureSample(celsius: Double, timestamp: Date)
    // Extra metrics carried in a combined-sensor packet.
    case bloodPressureSample(systolic: Int, diastolic: Int, timestamp: Date)
    case fatigueSample(value: Int, timestamp: Date)        // 0–100 scale
    case bloodSugarSample(mgdl: Double, timestamp: Date)
    case historySyncProgress(stage: String)
    case historySyncFinished
    case battery(percent: Int)
    case status(address: String?)
    /// Firmware version string parsed from the 0x0c status / 0xf6 firmware payload.
    case firmware(version: String)
    /// Ring bind/unbind handshake frame (0x4B): `action`/`state` per the protocol state machine.
    case bind(action: UInt8, state: UInt8)
    /// The device's own capability bitmap, already mapped onto `WearableCapability` (the protocol's `02 01`; see
    /// `the support-function reply`). Consumed by `RingBLEClient` to refine the active capability set — the
    /// coordinator's baseline is what the *family* can do, this is what *this unit* claims. Produces no
    /// `PulseEvent`: capabilities reach persistence via the re-published `.deviceIdentified`, not here.
    case supportFunctions(Set<WearableCapability>)
    /// The chipset/OTA family (the protocol's `02 1b`). **Diagnostic only** — PulseLoop does no firmware updates,
    /// so nothing branches on it; it is decoded because it is the one frame that says whether the ring's
    /// OTA path is JieLi RCSP (3/4/5), which is what would gate the AE00 auth we deliberately don't
    /// implement. Produces no `PulseEvent`.
    case chipScheme(value: Int)
    /// The ring reports it went on/off the finger (the protocol's `06 13`). Debug-feed only for now — it produces
    /// no `PulseEvent`, because nothing in the app gates on wear state yet. It is decoded so the packet
    /// feed can show *why* a measurement returned nothing (the ring was off).
    case wearingStatus(worn: Bool, timestamp: Date)
    /// The ring **refused** to start the spot measurement we asked for (the protocol's `03 2f` answered with a
    /// non-zero status). `mode` is the measurement mode we started — the reply itself carries only a
    /// status byte, so the mode comes from the start `the driver` remembers sending.
    ///
    /// Produces no `PulseEvent`: it is a verdict on a command, not data. `RingSyncCoordinator` reads it
    /// off the raw-packet feed and aborts the matching in-flight measurement, which is the whole point —
    /// the owner's an earlier ring refuses HRV (mode `0x0a` → status `0x01`), and without this the app polls a ring
    /// that already said no for the full 45-second window before reporting a generic failure.
    case measurementRejected(mode: UInt8)
    case measurementStatus(type: UInt8, status: UInt8)
    /// One frame of a an earlier family all-day "timing" vital timeline just landed. The ring returns a day in
    /// fixed-size frames and only sends the next one when asked, so the sync engine's `handle` uses this
    /// as a cursor: request `frameIndex + 1` until the vital's terminal frame (the vendor's sequential
    /// `insertBleMessage(<query>.b(day, index + 1))` in `e1/{f,d,g,l}.java`). `cmd` identifies the
    /// vital, `day` is 0 = today.
    ///
    /// Produces no `PulseEvent` — the samples themselves arrive as separate `.historyMeasurement`
    /// events; this only advances the cursor.
    case timingHistoryFrame(cmd: Int, day: Int, frameIndex: Int)
    case timeSyncAck(timestamp: Date)
    case commandAck(commandId: UInt8)
    case unknown(commandId: UInt8, raw: Data)

    var kind: String {
        switch self {
        case .activityUpdate: return "activity"
        case .activityBucket: return "activity_bucket"
        case .heartRateSample: return "hr_sample"
        case .heartRateComplete: return "hr_complete"
        case .spo2Progress: return "spo2_progress"
        case .spo2Result: return "spo2_result"
        case .spo2Complete: return "spo2_complete"
        case .sleepTimeline: return "sleep_timeline"
        case .historyMeasurement: return "history_measurement"
        case .stressSample: return "stress_sample"
        case .hrvSample: return "hrv_sample"
        case .temperatureSample: return "temperature_sample"
        case .bloodPressureSample: return "blood_pressure_sample"
        case .fatigueSample: return "fatigue_sample"
        case .bloodSugarSample: return "blood_sugar_sample"
        case .historySyncProgress: return "history_sync_progress"
        case .historySyncFinished: return "history_sync_finished"
        case .battery: return "battery"
        case .status: return "status"
        case .firmware: return "firmware"
        case .bind: return "bind"
        case .supportFunctions: return "support_functions"
        case .chipScheme: return "chip_scheme"
        case .wearingStatus: return "wearing_status"
        case .measurementRejected: return "measurement_rejected"
        case .measurementStatus: return "measurement_status"
        case .timingHistoryFrame: return "timing_history_frame"
        case .timeSyncAck: return "time_sync_ack"
        case .commandAck: return "command_ack"
        case .unknown: return "unknown"
        }
    }

    var confidence: DecodeConfidence {
        switch self {
        case .unknown:
            return .unknown
        case .commandAck, .heartRateComplete, .spo2Complete, .spo2Progress, .bind, .firmware,
             .wearingStatus,         // layout is SDK-verified; the status byte's *polarity* is not
             .measurementRejected:   // 0x00 = accepted is hardware-confirmed; that *every* non-zero code
                                     // means "refused" is the SDK's generic `code` contract, unnamed by
                                     // any enum in it (we have seen exactly one: 0x01, refusing HRV)
            return .partial
        default:
            return .known
        }
    }

    var debugJSON: String {
        switch self {
        case let .activityUpdate(_, steps, distanceMeters, calories):
            return #"{"steps":\#(steps),"distance_m":\#(Int(distanceMeters)),"calories":\#(Int(calories))}"#
        case let .activityBucket(_, steps, distanceMeters):
            return #"{"steps":\#(steps),"distance_m":\#(Int(distanceMeters))}"#
        case let .heartRateSample(bpm, _):
            return #"{"bpm":\#(bpm)}"#
        case let .spo2Result(value, _):
            return #"{"spo2":\#(value)}"#
        case let .stressSample(value, _):
            return #"{"stress":\#(value)}"#
        case let .hrvSample(value, _):
            return #"{"hrv_ms":\#(value)}"#
        case let .temperatureSample(celsius, _):
            return #"{"temp_c":\#(celsius)}"#
        case let .bloodPressureSample(systolic, diastolic, _):
            return #"{"systolic":\#(systolic),"diastolic":\#(diastolic)}"#
        case let .fatigueSample(value, _):
            return #"{"fatigue":\#(value)}"#
        case let .bloodSugarSample(mgdl, _):
            return #"{"glucose_mgdl":\#(Int(mgdl))}"#
        case let .firmware(version):
            return #"{"firmware":"\#(version)"}"#
        case let .bind(action, state):
            return #"{"bind_action":\#(action),"bind_state":\#(state)}"#
        case let .supportFunctions(capabilities):
            return #"{"claimed":"\#(capabilities.csv)"}"#
        case let .chipScheme(value):
            return #"{"chip_scheme":\#(value)}"#
        case let .wearingStatus(worn, _):
            return #"{"worn":\#(worn)}"#
        case let .measurementRejected(mode):
            return #"{"rejected_mode":\#(mode)}"#
        case let .timingHistoryFrame(cmd, day, frameIndex):
            return #"{"cmd":\#(cmd),"day":\#(day),"frameIndex":\#(frameIndex)}"#
        case let .historySyncProgress(stage):
            return #"{"stage":"\#(stage)"}"#
        case let .battery(percent):
            return #"{"percent":\#(percent)}"#
        case let .status(address):
            return #"{"address":"\#(address ?? "")"}"#
        default:
            return #"{}"#
        }
    }
}
extension Data {
    init(hexString: String) throws {
        let clean = hexString.replacingOccurrences(of: " ", with: "")
        guard clean.count.isMultiple(of: 2) else { throw RingProtocolError.invalidHex(hexString) }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw RingProtocolError.invalidHex(hexString)
            }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
