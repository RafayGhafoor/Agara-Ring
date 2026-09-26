import Foundation

/// The auto-measure building block (consistency framework, block A — AGENTS.md Rule 10): the ring's own
/// automatic-measurement schedule (`b3`), per metric on/off + interval, written back to the ring.
///
/// Everything a screen needs comes from the schedule the ring reports, so a metric type the ring adds later
/// shows up with no new UI: its row, its allowed intervals (multiples of the row's `d3` step) and whether it is
/// locked (`d4`) all come from the read. Mirrors Android's `AutoMeasure` (pending).
///
/// Wire format (research `docs/ring/research/03-device-functions.md` §2.4, emulator `frames.parse_auto_measure_set`):
/// a set is one metric at a time — a 42-byte body `a0 05 01 <len=35 u32LE>` + `a1 21 {d0 d1 d2 d3 d4 d5 d6 d7}`,
/// split into 17-byte chunks behind `b3 01 <seq>` (3 frames: 20, 20, 11 bytes), with body byte 2 (frame-1 byte 5)
/// overwritten by the chunk count. The ring acks `b3 01 01` (ok) / `b3 01 00` (refused); we then read the table
/// back (`b3 02`), so the screen always shows what the ring actually holds.
enum AutoMeasure {
    /// The longest interval offered (decision 3: only what the ring accepts, up to a sensible ceiling).
    static let maxIntervalMinutes = 240
    /// Bytes of the set body, and the chunk each frame carries.
    static let setBodyLength = 42
    static let chunkLength = 17

    /// Intervals the ring accepts for `entry`: multiples of its step from the step up to 4 h (the current value
    /// is always included, so a ring set elsewhere to something unusual still shows it).
    static func intervals(for entry: AutoMeasureEntry) -> [Int] {
        let step = entry.stepMinutes
        var values: [Int] = []
        if step > 0 {
            values = Array(stride(from: step, through: max(step, maxIntervalMinutes), by: step))
        }
        if entry.intervalMinutes > 0, !values.contains(entry.intervalMinutes) { values.append(entry.intervalMinutes) }
        return values.sorted()
    }

    /// The row can't be changed: the ring marks the interval unmodifiable (Lorenz on ours), or a row stored
    /// before the step was decoded (no step → nothing we could offer).
    static func isLocked(_ entry: AutoMeasureEntry) -> Bool {
        !entry.intervalModifiable || entry.stepMinutes <= 0
    }

    /// The shortest interval drains the ring battery fastest — the screen warns on it.
    static func isShortest(_ minutes: Int, for entry: AutoMeasureEntry) -> Bool {
        guard let first = intervals(for: entry).first else { return false }
        return minutes <= first
    }

    /// "30 min" / "1 h" / "1 h 30 min".
    static func label(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    // MARK: Encoding

    /// The 33-byte value of the row's `a1 21` TLV.
    static func tlvValue(_ entry: AutoMeasureEntry) -> [UInt8] {
        func window(_ values: [Int]) -> [UInt8] {
            let padded = values + Array(repeating: 0, count: max(0, 4 - values.count))
            return padded.prefix(4).map { UInt8(clamping: $0) }
        }
        let interval = UInt16(clamping: entry.intervalMinutes)
        let step = UInt16(clamping: entry.stepMinutes)
        var out: [UInt8] = []
        out += [0xD0, 0x01, UInt8(clamping: entry.protocolVersion)]
        out += [0xD1, 0x01, UInt8(clamping: entry.type)]
        out += [0xD2, 0x01, entry.enabled ? 1 : 0]
        out += [0xD3, 0x02, UInt8(step & 0xFF), UInt8(step >> 8)]
        out += [0xD4, 0x02, entry.windowModifiable ? 1 : 0, entry.intervalModifiable ? 1 : 0]
        out += [0xD5, 0x04] + window(entry.allowedWindow)
        out += [0xD6, 0x02, UInt8(interval & 0xFF), UInt8(interval >> 8)]
        out += [0xD7, 0x04] + window([entry.startHour, entry.startMinute, entry.endHour, entry.endMinute])
        return out
    }

    /// The 42-byte set body, with the header's packet count already set to the chunk count.
    static func setBody(_ entry: AutoMeasureEntry) -> [UInt8] {
        let value = tlvValue(entry)
        let tlv = [0xA1, UInt8(value.count)] + value
        let length = UInt32(tlv.count)
        let chunks = UInt8((setBodyLength + chunkLength - 1) / chunkLength)
        return [0xA0, 0x05, chunks,
                UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8(length >> 24)] + tlv
    }

    /// The frames of one `b3 01` set, in order: `b3 01 <seq>` + a 17-byte chunk (the last one shorter,
    /// unpadded — the vendor app sends 20, 20, 11 bytes).
    static func setFrames(_ entry: AutoMeasureEntry) -> [Data] {
        let body = setBody(entry)
        return stride(from: 0, to: body.count, by: chunkLength).enumerated().map { index, start in
            Data([0xB3, 0x01, UInt8(index + 1)] + body[start..<min(body.count, start + chunkLength)])
        }
    }
}

/// App-wide state of auto-measure writes: the latest schedule the ring reported and, per metric, whether a
/// change is on its way, confirmed or refused. Views read this; writes go through `set(_:)`, which the
/// coordinator turns into `b3 01` frames. Fed from the event bus (the ring's ack and its read-back).
@MainActor
@Observable
final class AutoMeasureStore {
    nonisolated deinit {}

    static let shared = AutoMeasureStore()

    enum WriteState: Equatable {
        case saving
        case failed(String)
    }

    /// The last schedule the ring reported this session (empty until one arrives; views fall back to the
    /// persisted `Device.autoMeasureSchedule`).
    private(set) var schedule: [AutoMeasureEntry] = []
    /// Per metric type: a write in flight, or the reason the last one failed.
    private(set) var writes: [Int: WriteState] = [:]
    /// The value we asked for, per type, until the read-back confirms it.
    private(set) var requested: [Int: AutoMeasureEntry] = [:]

    /// Sends the frames; returns false when no ring is connected. Set by the app (the coordinator).
    var sender: ((AutoMeasureEntry) -> Bool)?
    /// How long a write may wait for the ring's ack + read-back before it is reported as failed.
    var timeout: TimeInterval = 12

    private var task: Task<Void, Never>?
    private var timeouts: [Int: Task<Void, Never>] = [:]

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            let stream = await AgaraEventBus.shared.stream()
            for await event in stream { self?.handle(event) }
        }
    }

    /// What the screen shows for `entry`: the requested value while a write is in flight, else the ring's.
    func displayed(_ entry: AutoMeasureEntry) -> AutoMeasureEntry { requested[entry.type] ?? entry }

    /// Write `entry` to the ring (only the on/off and interval differ from what it reported).
    func set(_ entry: AutoMeasureEntry) {
        guard !AutoMeasure.isLocked(entry) else { return }
        guard let sender, sender(entry) else {
            writes[entry.type] = .failed("Connect your ring to change this.")
            return
        }
        requested[entry.type] = entry
        writes[entry.type] = .saving
        timeouts[entry.type]?.cancel()
        let type = entry.type
        timeouts[type] = Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fail(type, "The ring didn't confirm the change.")
        }
    }

    func handle(_ event: AgaraEvent) {
        switch event {
        case let .autoMeasureSchedule(entries):
            schedule = entries
            // The read-back settles every write in flight: confirmed if the ring holds what we asked for.
            for (type, want) in requested {
                guard let have = entries.first(where: { $0.type == type }) else { continue }
                if have.enabled == want.enabled && have.intervalMinutes == want.intervalMinutes {
                    #if DEBUG
                    E2ETrace.log("auto-measure read-back: type \(type) \(have.enabled ? "on" : "off") every \(have.intervalMinutes) min")
                    #endif
                    settle(type)
                } else if writes[type] == .saving {
                    fail(type, "The ring kept its previous setting.")
                }
            }
        case let .decodedPacket(.settingAck(commandId, ok)) where commandId == 0xB3 && !ok:
            for type in requested.keys where writes[type] == .saving { fail(type, "The ring refused the change.") }
        case let .deviceStateChanged(state, _) where state != .connected:
            for type in requested.keys where writes[type] == .saving { fail(type, "The ring disconnected.") }
        default:
            break
        }
    }

    private func settle(_ type: Int) {
        timeouts[type]?.cancel()
        timeouts[type] = nil
        requested[type] = nil
        writes[type] = nil
    }

    private func fail(_ type: Int, _ message: String) {
        timeouts[type]?.cancel()
        timeouts[type] = nil
        requested[type] = nil
        writes[type] = .failed(message)
    }
}
