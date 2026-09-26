#if DEBUG
import Foundation
@preconcurrency import CoreBluetooth
import Network
import SwiftData

/// Debug-only transport that lets the app talk to `ring-emulator` on this Mac instead of the physical
/// ring — the one-laptop test loop.
///
/// **Why a socket and not BLE:** a Mac never routes its own advertisement back to its own central, so
/// an emulator on the same machine is unreachable over the Bluetooth stack (measured both in one
/// process and across two; see `ring-emulator/loopback_probe.py`). The app already keeps "how we talk
/// to it" behind `RingCommandWriter` / `WearableDriver.ingest`, so swapping the transport leaves every
/// decode, storage, UI and cloud path untouched.
///
/// The wire format is deliberately boring, newline-delimited text so a capture is readable:
///
///     app → emulator    W <characteristic-uuid> <hex>      (a GATT write)
///     emulator → app    N <characteristic-uuid> <hex>      (a GATT notification)
///
/// Enable with either the scheme argument `-virtualRing 9909` (or any port) or the environment
/// variable `PULSELOOP_VIRTUAL_RING=9909`. When it is configured, CoreBluetooth is not started at all
/// (see `AgaraApp`), so a remembered physical ring can never be dragged into the session.
/// E2E tooling: plain-text trace lines appended to `Documents/e2e.log` and stderr. The unified log redacts
/// `NSLog` interpolations as `<private>`, and a Mac "Designed for iPad" run has no UI-test runner to read the
/// screen, so this file is how a scripted run proves what happened (`tools/e2e_ios.sh --mac`).
enum E2ETrace {
    nonisolated static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("e2e.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

@MainActor
final class VirtualRingLink {
    static let shared = VirtualRingLink()

    /// The port from the launch argument or environment, or nil when the virtual transport is off.
    static var configuredPort: UInt16? {
        if let raw = DebugLaunch.string("virtualRing"), let port = UInt16(raw) {
            return port
        }
        if let raw = DebugLaunch.environment("PULSELOOP_VIRTUAL_RING"), let port = UInt16(raw) {
            return port
        }
        // A bare `-virtualRing` (no value) means "on, default port".
        if DebugLaunch.isSet("virtualRing") { return UInt16(AgaraConfig.Emulator.defaultPort) }
        return nil
    }

    private var connection: NWConnection?
    private var buffer = Data()
    private weak var client: RingBLEClient?
    private var isAttached = false
    /// A connection attempt is under way (between `attach` and ready/failed).
    private var isConnecting = false
    /// The 2 s retry after a failure is pending.
    private var reconnectScheduled = false
    /// Bumped per `attach`, so a late callback from a previous connection can't tear down the current one.
    private var generation = 0

    private let writeUUID = CBUUID(string: VeepooUUIDs.commandWrite)

    private init() {}

    /// `-virtualRingOnPair YES`: don't connect at launch; wait for the pairing screen's scan.
    static let onPairKey = "virtualRingOnPair"
    private weak var deferredClient: RingBLEClient?

    func deferAttach(client: RingBLEClient) {
        deferredClient = client
        E2ETrace.log("virtualRing deferred until the pairing scan")
    }

    /// Settings › Wearable › Disconnect on the virtual ring: drop the socket like a real link going down and
    /// keep the client, so "Reconnect last ring" (→ `attachDeferredIfNeeded`) can bring it back. True if the
    /// virtual link handled it.
    func userDisconnect() -> Bool {
        guard isAttached || isConnecting, let client else { return false }
        generation += 1   // late callbacks from the dropped connection are ignored
        connection?.cancel()
        connection = nil
        isAttached = false
        isConnecting = false
        client.endVirtualConnection()
        deferredClient = client
        deferredByUser = true
        E2ETrace.log("virtualRing disconnected by the user")
        return true
    }

    /// A virtual ring is waiting to be (re)connected — the virtual stand-in for a remembered peripheral.
    /// (Not for `-virtualRingOnPair`: that one must wait for the pairing scan, not the foreground reconnect.)
    var hasDeferredRing: Bool { deferredClient != nil && deferredByUser }
    private var deferredByUser = false

    /// Called by `RingBLEClient.startScanning()`: connect the deferred link (once). True if it did.
    func attachDeferredIfNeeded() -> Bool {
        guard let client = deferredClient, let port = Self.configuredPort else { return false }
        deferredClient = nil
        deferredByUser = false
        attach(client: client, port: port)
        return true
    }

    /// Start the virtual link if the launch arguments ask for it. Safe to call unconditionally.
    @discardableResult
    func attachIfConfigured(client: RingBLEClient) -> Bool {
        guard let port = Self.configuredPort else { return false }
        attach(client: client, port: port)
        return true
    }

    /// Skip the onboarding flow when the virtual ring is already connected.
    ///
    /// Onboarding's pairing step exists to run a BLE scan and wait for a tap on a discovered ring; a
    /// virtual link is connected before the first frame of UI, so there is nothing to scan and nothing
    /// to tap. Marking setup complete (creating a minimal profile when the flow had not) opens the app
    /// on the live tabs — no BLE, no pairing screen, no demo data.
    static func completeOnboardingIfNeeded(context: ModelContext) throws {
        let profiles = try context.fetch(FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))
        if let profile = profiles.first {
            guard !profile.onboardingCompleted else { return }
            profile.onboardingCompleted = true
            profile.baselineCompleted = true
            profile.updatedAt = Date()
        } else {
            // Fill plausible physiology too: an empty profile makes the calorie estimator and HR-zone
            // math produce nonsense (a 7 500-step day read as ~1 500 kcal in testing).
            context.insert(UserProfile(
                name: "Emulator",
                age: 32,
                sex: "male",
                heightCm: 178,
                weightKg: 74,
                onboardingCompleted: true,
                baselineCompleted: true
            ))
        }
        try context.save()
        NSLog("[VirtualRing] onboarding marked complete for the virtual link")
    }

    /// Seed the two things the pairing/onboarding flow would normally create, so the virtual link
    /// produces a complete picture rather than an empty widget:
    ///
    /// * a `UserGoal` row — without one the weekly-goal widget silently falls back to 8 000 steps;
    /// * one finished workout for today — active minutes are only ever written by a workout session
    ///   (the TK20 ring reports no active-minutes metric at all), so the weekly-goal ring would
    ///   otherwise read 0 MIN forever.
    ///
    /// Both are skipped when the store already has them, so repeated launches stay idempotent.
    static func seedToolingDataIfNeeded(context: ModelContext) throws {
        if try context.fetchCount(FetchDescriptor<UserGoal>()) == 0 {
            context.insert(UserGoal())
            try context.save()
            NSLog("[VirtualRing] seeded a default goal row")
        }
        // A day of battery drain, so Wearable › Battery history (and its scrub tooltip) has a line to show —
        // the emulator only reports its level once a minute, and the history is throttled.
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        if try context.fetchCount(FetchDescriptor<BatterySample>(predicate: #Predicate { $0.timestamp > dayAgo })) < 2 {
            for hour in 0..<24 {
                context.insert(BatterySample(percent: 95 - hour * 3 / 2,
                                             timestamp: dayAgo.addingTimeInterval(Double(hour) * 3600 + 600)))
            }
            try context.save()
            NSLog("[VirtualRing] seeded 24 h of battery history")
        }
        let finishedToday = try context.fetchCount(FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.statusRaw == "finished" }))
        guard finishedToday == 0 else { return }
        // Type ids are the design-system keys ("walk", not "walking") — `create` throws otherwise.
        //
        // The session must end in the past **and** stay inside today: a fixed "an hour ago, 45 min
        // long" crosses midnight when the run happens just after midnight, which credits the minutes
        // to yesterday and leaves today's goal ring at 0 MIN.
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let elapsedMinutes = Int(now.timeIntervalSince(dayStart) / 60)
        let durationMinutes = Double(min(45, max(1, elapsedMinutes - 1)))
        let end = now.addingTimeInterval(-60)
        do {
            try ManualActivityService.create(
                type: "walk",
                startedAt: end.addingTimeInterval(-durationMinutes * 60),
                durationMinutes: durationMinutes,
                distanceMeters: durationMinutes / 45 * 4_200,
                notes: "Emulator session",
                context: context
            )
            NSLog("[VirtualRing] seeded a \(Int(durationMinutes))-minute workout for today")
        } catch {
            // Logged, never fatal: a failure here only means the active-minutes ring stays empty.
            NSLog("[VirtualRing] workout seed failed: \(error)")
        }
    }

    func attach(client: RingBLEClient, port: UInt16, host: String = "127.0.0.1") {
        self.client = client
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        self.connection = connection
        generation += 1
        let gen = generation
        isConnecting = true
        buffer.removeAll()
        // `self` is the process-wide singleton, so a strong capture costs nothing (and keeps the Sendable
        // hop free of a captured weak var).
        connection.stateUpdateHandler = { state in
            Task { @MainActor in self.handle(state: state, generation: gen) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        NSLog("[VirtualRing] connecting to ring-emulator at \(host):\(port)")
        E2ETrace.log("virtualRing connecting to \(host):\(port)")
    }

    /// Connect again with the last arguments — used by the firmware installer after the emulator drops the
    /// link (`--ota-fail-at`) or restarts the ring after an update. No-op while a link is up, a connect is
    /// under way or the automatic retry is already pending (the emulator serves one client at a time, so
    /// two parallel connections would queue behind each other).
    func reattach() {
        guard !isAttached, !isConnecting, !reconnectScheduled, let client else { return }
        NSLog("[VirtualRing] re-attaching for the firmware update")
        connection?.cancel()
        connection = nil
        attach(client: client, port: Self.configuredPort ?? UInt16(AgaraConfig.Emulator.defaultPort))
    }

    /// Feed a frame out to the emulator, exactly as a GATT write would leave the device. `characteristic`
    /// is the write target on the wire: the ring's command channel by default, `F032` for a firmware update
    /// (the emulator routes those to its AB-OTA responder).
    func send(_ frame: Data, characteristic: String? = nil) {
        guard !frame.isEmpty else { return }
        let target = characteristic ?? writeUUID.uuidString
        let line = "W \(target) \(frame.map { String(format: "%02x", $0) }.joined())\n"
        connection?.send(content: Data(line.utf8), completion: .contentProcessed { error in
            if let error { NSLog("[VirtualRing] send failed: \(error)") }
        })
    }

    // MARK: Signal strength (Find ring)

    /// Receives the emulator's `RSSI <dBm>` replies (the socket has no radio; the emulator scripts the signal with
    /// `--rssi` / `--rssi-walk`). Set by `VirtualRingSignalSource`.
    var onRSSI: ((Int) -> Void)?

    /// Ask the emulator for the current signal strength with a plain `RSSI` line. No-op while the link is down — the
    /// silence is what makes the screen go "Out of range", like a real ring walking out of reach.
    func requestRSSI() {
        guard isAttached, let connection else { return }
        connection.send(content: Data("RSSI\n".utf8), completion: .contentProcessed { _ in })
    }

    /// `RSSI -63` → -63; nil for anything else.
    static func parseRSSI(_ line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count == 2, parts[0] == "RSSI" else { return nil }
        return Int(parts[1])
    }

    // MARK: Internals

    /// A callback from the connection of `generation`; ignored when a newer `attach` replaced it.
    private func handle(state: NWConnection.State, generation gen: Int) {
        guard gen == generation else { return }
        handle(state: state)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            NSLog("[VirtualRing] connected — starting the virtual link")
            E2ETrace.log("virtualRing connected")
            isAttached = true
            isConnecting = false
            // Called on the main actor already: send in order, without a Task hop per frame (a firmware
            // update writes hundreds of frames back to back).
            client?.beginVirtualConnection(sink: { [weak self] characteristic, frame in
                self?.send(frame, characteristic: characteristic)
            })
            receive()
        case let .failed(error):
            NSLog("[VirtualRing] failed: \(error) — retrying in 2 s")
            E2ETrace.log("virtualRing failed: \(error)")
            let wasAttached = isAttached
            isAttached = false
            isConnecting = false
            if wasAttached { client?.endVirtualConnection() }
            scheduleReconnect()
        case let .waiting(error):
            // Nobody listening (the emulator isn't up yet / restarting): NWConnection would wait for a
            // network change that never comes. Treat it as a failure and retry on the usual 2 s cadence.
            NSLog("[VirtualRing] waiting: \(error) — retrying in 2 s")
            E2ETrace.log("virtualRing waiting: \(error)")
            isConnecting = false
            if isAttached {
                isAttached = false
                client?.endVirtualConnection()
            }
            scheduleReconnect()
        case .cancelled:
            isAttached = false
            isConnecting = false
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard let connection, !reconnectScheduled else { return }
        let port = connection.endpoint.debugDescription
        reconnectScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.reconnectScheduled = false
            guard let client = self.client, !self.isAttached else { return }
            NSLog("[VirtualRing] reconnecting (\(port))")
            self.connection?.cancel()
            self.connection = nil
            self.attach(client: client, port: Self.configuredPort ?? UInt16(AgaraConfig.Emulator.defaultPort))
        }
    }

    private func receive() {
        let gen = generation
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            Task { @MainActor in
                self.received(data: data, isComplete: isComplete, error: error, generation: gen)
            }
        }
    }

    private func received(data: Data?, isComplete: Bool, error: NWError?, generation gen: Int) {
        guard gen == generation else { return }
        if let data, !data.isEmpty {
            buffer.append(data)
            drainBuffer()
        }
        if let error { NSLog("[VirtualRing] receive error: \(error)") }
        if isComplete || error != nil {
            handle(state: .failed(NWError.posix(.ECONNRESET)))
        } else {
            receive()
        }
    }

    /// Split the byte stream on newlines and deliver each `N <uuid> <hex>` frame as a notification.
    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            deliver(line: Data(line))
        }
    }

    private func deliver(line: Data) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        if let dbm = Self.parseRSSI(text) {
            onRSSI?(dbm)
            return
        }
        let parts = text.split(separator: " ")
        guard parts.count == 3, parts[0] == "N" else { return }
        guard let bytes = Self.hexBytes(String(parts[2])) else {
            NSLog("[VirtualRing] malformed frame from emulator: \(text.prefix(60))")
            return
        }
        client?.injectVirtualNotification(bytes, from: CBUUID(string: String(parts[1])))
    }

    private static func hexBytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
#endif
