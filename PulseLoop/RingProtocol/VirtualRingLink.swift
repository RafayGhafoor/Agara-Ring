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
/// (see `PulseLoopApp`), so a remembered physical ring can never be dragged into the session.
@MainActor
final class VirtualRingLink {
    static let shared = VirtualRingLink()

    /// The port from the launch argument or environment, or nil when the virtual transport is off.
    static var configuredPort: UInt16? {
        if let raw = UserDefaults.standard.string(forKey: "virtualRing"), let port = UInt16(raw) {
            return port
        }
        if let raw = ProcessInfo.processInfo.environment["PULSELOOP_VIRTUAL_RING"], let port = UInt16(raw) {
            return port
        }
        // A bare `-virtualRing` (no value) means "on, default port".
        if UserDefaults.standard.object(forKey: "virtualRing") != nil { return 9909 }
        return nil
    }

    private var connection: NWConnection?
    private var buffer = Data()
    private weak var client: RingBLEClient?
    private var isAttached = false

    private let writeUUID = CBUUID(string: VeepooUUIDs.commandWrite)

    private init() {}

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
        self.client = client
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state: state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        NSLog("[VirtualRing] connecting to ring-emulator at \(host):\(port)")
    }

    /// Feed a frame out to the emulator, exactly as a GATT write would leave the device.
    func send(_ frame: Data) {
        guard !frame.isEmpty else { return }
        let line = "W \(writeUUID.uuidString) \(frame.map { String(format: "%02x", $0) }.joined())\n"
        connection?.send(content: Data(line.utf8), completion: .contentProcessed { error in
            if let error { NSLog("[VirtualRing] send failed: \(error)") }
        })
    }

    // MARK: Internals

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            NSLog("[VirtualRing] connected — starting the virtual link")
            isAttached = true
            client?.beginVirtualConnection(sink: { [weak self] frame in
                Task { @MainActor in self?.send(frame) }
            })
            receive()
        case let .failed(error):
            NSLog("[VirtualRing] failed: \(error) — retrying in 2 s")
            isAttached = false
            client?.endVirtualConnection()
            scheduleReconnect()
        case .cancelled:
            isAttached = false
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard let connection else { return }
        let port = connection.endpoint.debugDescription
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let client = self.client else { return }
            NSLog("[VirtualRing] reconnecting (\(port))")
            self.connection?.cancel()
            self.connection = nil
            self.attach(client: client, port: Self.configuredPort ?? 9909)
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainBuffer()
                }
                if let error { NSLog("[VirtualRing] receive error: \(error)") }
                if isComplete || error != nil {
                    self.handle(state: .failed(NWError.posix(.ECONNRESET)))
                } else {
                    self.receive()
                }
            }
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
