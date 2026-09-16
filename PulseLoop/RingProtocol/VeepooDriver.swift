import Foundation
@preconcurrency import CoreBluetooth

/// Driver for the Veepoo / TK20 ring (H Ring app). A thin wrapper over `VeepooDecoder` /
/// `VeepooEncoder` so the device-agnostic `RingBLEClient` can drive it like any other wearable.
///
/// Two things are unlike the other families:
///
/// - **The session handshake must lead.** The A1 open frame is the one command the ring answers on
///   the F008 channel — everything else is met with silence and a ~10 s disconnect until it lands.
///   It is therefore sent as an `immediatePostSubscriptionCommands` write, ahead of the sync
///   engine's startup, and the engine gates its whole sequence on the auth ack.
/// - **E0/DF history is reassembled by the engine.** The frames carry no requested-day echo, so the
///   reassembler must know which day is in flight — only the engine (which issues the queries) knows.
///   The driver forwards each history frame as an `.unknown` event and the engine mirrors the
///   verified harness's per-day grouping verbatim.
@MainActor
final class VeepooDriver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder = VeepooDecoder()
    /// The A1 frame is sent once per GATT link (reset in `connectionDidStart`, which auto-reconnect
    /// re-uses the same instance).
    private var sentAuthentication = false
    /// FEA1 notifies ~1 Hz with the ring's **cumulative day total**; one ratchet update per minute is
    /// enough for the live tile (the app's `.activityUpdate` is a monotonic-max ratchet, so the last
    /// total wins without ever regressing).
    private var lastLiveMinute: Int?
    /// True between a measurement start frame and its stop frame; the ring only streams D0/0x80/0x90
    /// measurement frames while measuring, and the latch keeps ambient frames from decoding as ones.
    private var measuring = false

    init(writer: RingCommandWriter) {
        self.writer = writer
    }

    // MARK: BLE topology

    let serviceUUIDs: [CBUUID] = [
        CBUUID(string: VeepooUUIDs.commandService),
        CBUUID(string: VeepooUUIDs.passwordService),
        CBUUID(string: VeepooUUIDs.legacyService),
    ]
    let writeUUID = CBUUID(string: VeepooUUIDs.commandWrite)
    let notifyUUIDs: [CBUUID] = [
        CBUUID(string: VeepooUUIDs.commandNotify),
        CBUUID(string: VeepooUUIDs.passwordNotify),
        CBUUID(string: VeepooUUIDs.liveSteps),
    ]
    let batteryServiceUUID: CBUUID? = nil    // battery arrives in-band via A0
    let batteryCharUUID: CBUUID? = nil

    // MARK: Framing / handshake

    func frame(_ command: Data) -> Data {
        // Every measurement start frame has byte [1] == 0x01 (D0 01, 80 01 02, 90 01 00); stops use
        // 0x00 or 0x02. Flip the latch so `ingest` decodes the stream frames only mid-measurement.
        if let opcode = command.first, [0xD0, 0x80, 0x90].contains(opcode), command.count >= 2 {
            measuring = command[1] == 0x01
        }
        return command   // already 20 bytes, no checksum
    }

    func connectionDidStart() {
        sentAuthentication = false
        lastLiveMinute = nil
    }

    /// The ring answers exactly one thing before auth: the A1 open frame. It must be the first write
    /// on the channel, so it rides the pre-startup hook rather than the engine's startup sequence.
    func immediatePostSubscriptionCommands() -> [Data] {
        guard !sentAuthentication else { return [] }
        sentAuthentication = true
        return [VeepooEncoder.authentication()]
    }

    // MARK: Decoding

    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        guard !data.isEmpty else { return [] }

        // FEA1 (live steps) arrives as `01 <u16 LE> 00`, ~1 Hz, carrying the **cumulative day total**
        // — check the channel before the opcode switch. This is emitted as a throttled `.activityUpdate`
        // ratchet (not a bucket): a bucket of the full total would double-count today's DF history
        // slots, which cover the same ground, while the ratchet converges on the same number.
        if characteristic == CBUUID(string: VeepooUUIDs.liveSteps) {
            guard let total = decoder.liveSteps(frame: data) else { return [] }
            let minute = Calendar.current.component(.minute, from: Date())
            guard minute != lastLiveMinute else { return [] }
            lastLiveMinute = minute
            return [.activityUpdate(timestamp: Date(), steps: total, distanceMeters: 0, calories: 0)]
        }

        switch data[0] {
        case VeepooOpcode.open.rawValue:
            // The auth ack — the engine's gate for the whole post-auth sequence.
            return [.commandAck(commandId: data[0])]
        case VeepooOpcode.deviceInfo.rawValue:
            guard let percent = decoder.battery(frame: data) else { return [] }
            return [.battery(percent: percent)]
        case VeepooOpcode.realtime.rawValue:
            guard let activity = decoder.activity(frame: data) else { return [] }
            return [.activityUpdate(
                timestamp: Date(),
                steps: activity.steps,
                distanceMeters: Double(activity.distanceMeters),
                calories: activity.calories
            )]
        case VeepooOpcode.sleepHistory.rawValue, VeepooOpcode.dailyHistory.rawValue:
            // Reassembled by the engine, which owns the per-day history state machine.
            return [.unknown(commandId: data[0], raw: data)]
        case 0xD0 where measuring:
            // One-shot heart-rate stream: D0 <bpm>, 1 Hz, 0 while warming up.
            return decoder.heartRate(frame: data).map { [.heartRateSample(bpm: $0, timestamp: Date())] } ?? []
        case 0x80 where measuring:
            // One-shot oxygen stream: 80 01 00 00 <spo2> 00 … (byte-map partial, see decoder).
            return decoder.oxygen(frame: data).map { [.spo2Result(value: $0, timestamp: Date())] } ?? []
        case 0x90 where measuring:
            // One-shot BP stream: progress %, then the final 90 <sys> <dia> 64 00 01 …
            return decoder.bloodPressure(frame: data).map {
                [.bloodPressureSample(systolic: $0.systolic, diastolic: $0.diastolic, timestamp: Date())]
            } ?? []
        default:
            return [.unknown(commandId: data[0], raw: data)]
        }
    }

    func makeSyncEngine() -> RingSyncEngine {
        VeepooSyncEngine(writer: writer, decoder: decoder, historyDays: Self.configuredHistoryDays)
    }

    /// How many days the history loop walks. The ring retains ~3 and answers no-data past that, so 7
    /// costs almost nothing; `-historyDays N` (launch argument) widens it for tooling — e.g. rendering a
    /// two-month week/month/year view against the ring emulator.
    static var configuredHistoryDays: Int {
        let requested = UserDefaults.standard.integer(forKey: "historyDays")
        return (1...400).contains(requested) ? requested : AgaraConfig.Ring.historyDays
    }
}