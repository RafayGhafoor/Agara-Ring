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
    /// The same latch for the tests on shared opcodes (0x89 stress/glucose, 0x8A blood components):
    /// the opcode + sub-op of the running test, nil when none. The ring also answers 0x89/0x8A with
    /// calibration reads (`89 03`, `8a 02`) that must never read as a result.
    private var spotTest: (opcode: UInt8, sub: UInt8)?
    /// `a7` capability packets seen on this link, by package number (byte 19).
    private var capabilityPackets: [Int: [UInt8]] = [:]
    /// `b3` auto-measure read-reply frames on this link, by sequence number (byte 3).
    private var autoMeasureFrames: [Int: [UInt8]] = [:]

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
        // Stress / glucose / blood components: `89|8a <sub> 01|02 …` — byte 2 is start (01) / stop (02).
        if let opcode = command.first, [0x89, 0x8A].contains(opcode), command.count >= 3,
           [0x01, 0x06].contains(command[command.startIndex + 1]) {
            spotTest = command[command.startIndex + 2] == 0x01 ? (opcode, command[command.startIndex + 1]) : nil
        }
        return command   // already 20 bytes, no checksum
    }

    func connectionDidStart() {
        sentAuthentication = false
        lastLiveMinute = nil
        measuring = false
        spotTest = nil
        capabilityPackets.removeAll()
        autoMeasureFrames.removeAll()
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
            // The auth ack — the engine's gate for the whole post-auth sequence — plus the firmware it
            // carries (bytes 6–8).
            var events: [RingDecodedEvent] = [.commandAck(commandId: data[0])]
            if let info = decoder.firmware(frame: data) {
                events.append(.firmware(version: info.version, deviceNumber: info.deviceNumber, testVersion: info.testVersion))
            }
            return events
        case VeepooOpcode.deviceInfo.rawValue:
            guard let percent = decoder.battery(frame: data) else { return [] }
            var events: [RingDecodedEvent] = [.battery(percent: percent)]
            if let charging = decoder.charging(frame: data) { events.append(.chargingState(isCharging: charging)) }
            return events
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
            return heartRateEvents(data)
        case 0x80 where measuring:
            // One-shot oxygen stream: 80 01 <status> <spo2> 00 64 … (value at byte 3, status at byte 2).
            if let refusal = decoder.oxygenRefusal(frame: data) {
                return [.measurementRejected(mode: SpotMode.spo2, reason: refusal)]
            }
            return decoder.oxygen(frame: data).map { [.spo2Result(value: $0, timestamp: Date())] } ?? []
        case 0x90 where measuring:
            // One-shot BP stream: progress %, then the final 90 <sys> <dia> 64 00 01 …
            if let refusal = decoder.bloodPressureRefusal(frame: data) {
                return [.measurementRejected(mode: SpotMode.bloodPressure, reason: refusal)]
            }
            return decoder.bloodPressure(frame: data).map {
                [.bloodPressureSample(systolic: $0.systolic, diastolic: $0.diastolic, timestamp: Date())]
            } ?? []
        case 0x89 where spotTest?.opcode == 0x89:
            return spotTestEvents(data)
        case 0x8A where spotTest?.opcode == 0x8A:
            return bloodComponentsEvents(data)
        case 0xA7:
            return capabilityEvents(data)
        case 0xB3:
            return autoMeasureEvents(data)
        case 0xA3:
            guard let ok = decoder.profileAck(frame: data) else { return [.unknown(commandId: data[0], raw: data)] }
            return [.settingAck(commandId: 0xA3, ok: ok)]
        default:
            return [.unknown(commandId: data[0], raw: data)]
        }
    }

    /// D0 frames: a bpm, or a verdict. The busy reply (`d0 01 00 00 00 0a`, the answer to a re-asserted
    /// start) is dropped; a plain `d0 01`/`d0 02` means no finger.
    private func heartRateEvents(_ data: Data) -> [RingDecodedEvent] {
        switch decoder.heartRateReply(frame: data) {
        case let .bpm(value)?: return [.heartRateSample(bpm: value, timestamp: Date())]
        case .notWorn?: return [.measurementRejected(mode: SpotMode.heartRate, reason: .notWorn)]
        case .busy?, .warmingUp?, nil: return []
        }
    }

    /// 0x89 replies while a stress (sub 06) or glucose (sub 01) test runs.
    private func spotTestEvents(_ data: Data) -> [RingDecodedEvent] {
        guard data.count >= 2 else { return [] }
        let sub = data[data.startIndex + 1]
        guard sub == spotTest?.sub else { return [.unknown(commandId: data[0], raw: data)] }
        if sub == 0x06 {
            switch decoder.stressReply(frame: data) {
            case let .result(value)?: return [.stressSample(value: Int(value), timestamp: Date())]
            case let .refused(reason)?: return [.measurementRejected(mode: SpotMode.stress, reason: reason)]
            default: return []
            }
        }
        switch decoder.glucoseReply(frame: data) {
        case let .result(mmol)?:
            // The app stores glucose in mg/dL (the DF path converts the same way).
            return [.bloodSugarSample(mgdl: mmol * 18.016, timestamp: Date())]
        case let .refused(reason)?: return [.measurementRejected(mode: SpotMode.glucose, reason: reason)]
        default: return []
        }
    }

    private func bloodComponentsEvents(_ data: Data) -> [RingDecodedEvent] {
        switch decoder.bloodComponentsReply(frame: data) {
        case let .result(reading)?: return [.bloodComponentsSample(reading, timestamp: Date())]
        case let .refused(reason)?: return [.measurementRejected(mode: SpotMode.bloodComponents, reason: reason)]
        case .progress?, .stopped?: return []
        case nil: return [.unknown(commandId: data[0], raw: data)]
        }
    }

    /// `a7` capability packets (package number at byte 19). Emits the decoded capabilities once packages
    /// 1–4 (all our ring sends) have arrived, and again on any later package (persistence is idempotent).
    private func capabilityEvents(_ data: Data) -> [RingDecodedEvent] {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, (1...5).contains(bytes[19]) else { return [.unknown(commandId: data[0], raw: data)] }
        let package = Int(bytes[19])
        capabilityPackets[package] = bytes
        guard (1...4).allSatisfy({ capabilityPackets[$0] != nil }) else { return [] }
        return [.ringCapabilities(RingCapabilities.decode(packages: capabilityPackets))]
    }

    /// `b3 02 01 <seq>` read-reply frames; the header TLV in frame 1 says how many to expect.
    private func autoMeasureEvents(_ data: Data) -> [RingDecodedEvent] {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[1] == 0x02, bytes[2] == 0x01 else { return [.unknown(commandId: data[0], raw: data)] }
        let seq = Int(bytes[3])
        if seq == 1 { autoMeasureFrames.removeAll() }
        autoMeasureFrames[seq] = Array(bytes.dropFirst(4))
        guard let first = autoMeasureFrames[1], first.count >= 3, first[0] == 0xA0 else { return [] }
        let expected = Int(first[2])
        guard expected > 0, (1...expected).allSatisfy({ autoMeasureFrames[$0] != nil }) else { return [] }
        let body = (1...expected).flatMap { autoMeasureFrames[$0] ?? [] }
        autoMeasureFrames.removeAll()
        let entries = VeepooDecoder.autoMeasureSchedule(body: body)
        return entries.isEmpty ? [] : [.autoMeasureSchedule(entries)]
    }

    func makeSyncEngine() -> RingSyncEngine {
        VeepooSyncEngine(writer: writer, decoder: decoder, historyDays: Self.configuredHistoryDays)
    }

    /// How many days the history loop walks. The ring retains ~3 and answers no-data past that, so 7
    /// costs almost nothing; `-historyDays N` (launch argument) widens it for tooling — e.g. rendering a
    /// two-month week/month/year view against the ring emulator.
    static var configuredHistoryDays: Int {
        let requested = DebugLaunch.integer("historyDays")
        return (1...400).contains(requested) ? requested : AgaraConfig.Ring.historyDays
    }
}