import Foundation
@preconcurrency import CoreBluetooth

/// Device-agnostic CoreBluetooth client for any supported wearable.
///
/// The client owns only the CoreBluetooth plumbing — scanning, connecting, discovering
/// services/characteristics, serializing writes, and fanning out notifications. Every
/// protocol-specific decision (which service/characteristics to use, how to frame a command, how to
/// decode a notification, what the startup/history flow is) is delegated to the `WearableDriver` and
/// `RingSyncEngine` selected at connect time from the coordinator registry.
///
/// Discovery walks `Self.coordinators` and the first coordinator whose `matches` claims a
/// peripheral wins; its driver is instantiated per connection (so per-connection state — big-data
/// buffers, sync-machine state — never leaks across reconnects). Adding a new wearable is "append a
/// coordinator to the registry."
///
/// Every outgoing and incoming frame is still published as `AgaraEvent.rawPacket` (for the hidden
/// debug feed), and decoded notifications are fanned out to typed `AgaraEvent`s via `RingEventBridge`.
///
/// The central manager is created with `queue: nil`, so all delegate callbacks arrive on the main
/// thread; the class is `@MainActor` and the delegate methods use `MainActor.assumeIsolated`. Writes
/// are serialized (one outstanding `withResponse` write at a time) to keep framed responses in order.
@MainActor
@Observable
final class RingBLEClient: NSObject {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Registry of supported wearables. First coordinator whose `matches` claims a peripheral wins.
    ///
    /// One entry: the Agara Ring. It stays an array — and the match stays a walk — because that is the
    /// seam a second ring would arrive through, and because `matchDeviceType` is what pairing asks.
    static let coordinators: [WearableCoordinator.Type] = [
        // The Veepoo/Agara Ring: matches the `TK20`/`AGARA` name (plus an `f8f8` manufacturer marker
        // alongside a TK name) on the F008/F002 GATT. Those services are not advertised, so the name is
        // the only pre-connect signal there is.
        VeepooCoordinator.self,
    ]

    /// Which coordinator serves a connection. Pure, so the pairing rules are testable without a
    /// `CBCentralManager`.
    ///
    /// Falls back to the Agara coordinator when no family is known (a reconnect to a peripheral whose
    /// advertisement carried no name): the only ring this build drives.
    static func coordinatorType(
        preferredFamily: RingDeviceType?,
        autoMatched: RingDeviceType?
    ) -> WearableCoordinator.Type {
        let family = preferredFamily ?? autoMatched
        return coordinators.first { $0.deviceType == family } ?? VeepooCoordinator.self
    }

    /// Walk the registry to claim an advertisement; nil when no coordinator recognizes it.
    static func matchDeviceType(name: String?, advertisement: AdvertisementInfo) -> RingDeviceType? {
        coordinators.first { $0.matches(name: name, advertisement: advertisement) }?.deviceType
    }

    struct DiscoveredRing: Identifiable, Equatable {
        let id: UUID          // CBPeripheral.identifier
        let name: String
        let rssi: Int
        /// True when the advertisement matches a known wearable signature. Non-matching named
        /// peripherals are still listed (sorted below) so the user can always find their device.
        let isLikelyRing: Bool
        /// The wearable family this advertisement matched, if any (drives the device card + icon).
        let deviceType: RingDeviceType?
        /// Exact catalog model inferred from the Bluetooth local name, when recognizable.
        let wearableModelID: String?
    }

    // MARK: Observable state (read by SwiftUI)
    private(set) var state: RingConnectionState = .idle
    private(set) var discovered: [DiscoveredRing] = []
    private(set) var batteryPercent: Int?
    /// The ring is on its charger (battery frame byte 1). A live condition: reset whenever the link drops.
    private(set) var isCharging = false { didSet { if !isCharging { chargeSeries.reset() } } }
    /// Battery readings of the current charge (live frames only) — the input to `chargeEstimate`.
    private(set) var chargeSeries = ChargeEstimator.Series()
    /// "Full in ~N min" etc. while on the charger; nil otherwise.
    var chargeEstimate: ChargeEstimator.Estimate? { isCharging ? chargeSeries.estimate : nil }
    /// The last battery frame's level and time. The ring sends level and charging flag in one frame, level
    /// first, so the charging event picks this up for the first reading of a charge.
    @ObservationIgnored private var lastBatteryReading: ChargeEstimator.Reading?
    private(set) var isBluetoothReady = false
    /// Why Bluetooth isn't usable (off vs not allowed vs unsupported) — the pairing card words it differently.
    private(set) var bluetoothAvailability: BluetoothAvailability = .unknown
    private(set) var lastError: String?

    /// The level from the ring's own battery frame (`a0`, in-band) on this connection; nil until one arrived.
    /// `batteryPercent` is the GATT battery characteristic, which the Agara ring doesn't have.
    private(set) var ringBatteryPercent: Int?
    /// What this ring's `a7` capability packets said on this connection (nil until all four arrived).
    private(set) var ringCapabilities: RingCapabilities?
    /// The firmware the ring's `a1` reply reported on the *current* link; cleared whenever the link drops,
    /// so a firmware install can tell the restarted ring's answer from the old one.
    private(set) var firmwareSinceConnect: String?

    // MARK: Firmware update channel (AB-OTA on F003; plan firmware-update stage 4)
    /// `F003` with its `F031` notify and `F032` write characteristics was found on this link (always true on
    /// the emulator's socket, which routes `F032` writes / `F031` notifications — emulator `ota.py`).
    private(set) var otaServiceAvailable = false
    @ObservationIgnored private var otaNotifyChar: CBCharacteristic?
    @ObservationIgnored private var otaWriteChar: CBCharacteristic?
    @ObservationIgnored private var otaNotifyEnabled = false
    /// Frames for `F032`, written without response as fast as the peripheral's buffer allows.
    @ObservationIgnored private var otaWriteQueue: [Data] = []
    /// The running install's listener: every `F031` notification, and the link going down.
    @ObservationIgnored private var otaListener: ((OtaLinkEvent) -> Void)?
    private let otaServiceCBUUID = CBUUID(string: AbOta.serviceUUID)
    private let otaNotifyCBUUID = CBUUID(string: AbOta.notifyUUID)
    private let otaWriteCBUUID = CBUUID(string: AbOta.writeUUID)
    /// The emulator link carries a whole frame per line; this mirrors Android's virtual MTU (515 − 3).
    static let virtualOtaFrameLimit = 512

    /// The wearable family of the active connection (nil until a driver is selected).
    private(set) var activeDeviceType: RingDeviceType?
    private(set) var activeWearableModelID: String?
    var activeWearableModel: WearableModel? { WearableModel.model(id: activeWearableModelID) }
    /// What the active device can do — the single source the capability-gated UI consults.
    private(set) var activeCapabilities: Set<WearableCapability> = []

    /// Invoked once, on the main actor, after a connection is fully established (notifications
    /// enabled). The sync coordinator hooks this to run the startup command sequence.
    var onConnected: (@MainActor () -> Void)?

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Strong references to scanned peripherals, keyed by identifier. Required because
    /// `connect(_:)` needs the actual `CBPeripheral` object — `retrievePeripherals` returns
    /// nothing for a device the system has never connected to before.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var writeChar: CBCharacteristic?
    /// Optional second write characteristic for big-data requests (the ring `de5bf72a`).
    private var commandChar: CBCharacteristic?
    private var notifyChars: [CBUUID: CBCharacteristic] = [:]
    /// Notify characteristics that have actually reported `isNotifying` on *this* link. Reset per
    /// connection: a driver survives a reconnect, so a set carried over would let the next link claim
    /// readiness on subscriptions that belong to the dead one.
    private var subscribedNotifyUUIDs: Set<CBUUID> = []
    private var batteryCharacteristic: CBCharacteristic?

    // MARK: Active driver / engine (selected per connection)
    private var activeCoordinator: WearableCoordinator?
    private var activeDriver: WearableDriver?
    private var activeSyncEngine: RingSyncEngine?
    private var activeAdvertisedName: String?
    #if DEBUG
    /// Outbound frame sink for the debug virtual transport — see `VirtualRingLink`. When set, frames
    /// go to the emulator socket instead of CoreBluetooth. The first argument is the characteristic the
    /// write targets (nil = the ring's command channel; `F032` for a firmware update).
    private(set) var virtualFrameSink: ((String?, Data) -> Void)?
    #endif

    // MARK: Write serialization
    /// Each queued write carries its already-framed bytes and which characteristic to send it to.
    private struct PendingWrite {
        let data: Data
        let useCommandChannel: Bool
        var completion: (@MainActor (Result<Void, Error>) -> Void)?
    }
    private var writeQueue: [PendingWrite] = []
    private var inFlightCompletion: (@MainActor (Result<Void, Error>) -> Void)?
    private var writeInFlight = false
    /// Monotonic id for the in-flight write, so a timeout task only unblocks *its* write (not a newer
    /// one that has since started). Mirrors the Android write-ACK timeout guard.
    private var writeSeq: UInt64 = 0

    /// When true, an unexpected disconnect triggers an automatic reconnect attempt.
    private var autoReconnect = true

    // MARK: Connection reliability (mirrors the Android RingBLEClient hardening)
    /// Wall-clock of the last proof the link is alive (notification, write ACK, or read). Drives the
    /// watchdog's zombie-link detection.
    private var lastActivityAt: Date?
    private var watchdogTask: Task<Void, Never>?
    /// Watchdog tick + the "no activity ⇒ zombie link" threshold. The threshold is loosened from
    /// Android's 50s because iOS hands background apps shorter, less predictable execution windows.
    private let watchdogInterval: UInt64 = 15_000_000_000
    private let linkStaleSeconds: TimeInterval = 60
    /// Watchdog tick counter, used to piggyback a periodic battery re-read on the existing 15s loop
    /// (no new timer). the ring only reports battery on connect, so without this the level goes stale.
    private var watchdogTicks = 0
    /// Write-ACK timeout: if CoreBluetooth never reports the write completing, unblock the queue so a
    /// single dropped ACK can't wedge it.
    private let writeAckTimeout: UInt64 = 4_000_000_000

    /// Connect-attempt timeout, armed **only** for a connect the user asked for (see `beginConnect`).
    /// The watchdog above only guards a link that already reached `.connected`; nothing guarded the
    /// connect *phase*, which is where the wrong-driver failure lives: pick the wrong app variant for a
    /// the ring and the installed driver hunts for service UUIDs the ring doesn't have — the BLE link
    /// opens, GATT discovery turns up nothing, `.connected` never arrives, and the pairing screen spins
    /// forever with no error. 20 s is slack, not a race: a healthy ring completes link + discovery +
    /// notify-enable in a few seconds.
    private var connectTimeoutTask: Task<Void, Never>?
    private let connectTimeout: UInt64 = 20_000_000_000

    private static let lastPeripheralKey = "ring.lastPeripheralIdentifier"
    private static let lastDeviceTypeKey = "ring.lastDeviceType"
    private static let lastWearableModelKey = "ring.lastWearableModel"
    private static let lastCapabilitiesKey = "ring.lastCapabilities"

    /// The 0x180F battery service, used only when the active driver exposes GATT battery.
    private let batteryServiceCBUUID = CBUUID(string: "180F")

    /// Standard Device Information Service + its firmware/software revision characteristics. The 56ff
    /// ring exposes these even without advertising 0x180A, so we scan for them across all services
    /// (Android firmware-discovery parity).
    private let disServiceCBUUID = CBUUID(string: "180A")
    private let firmwareCharUUIDs: Set<CBUUID> = [CBUUID(string: "2A26"), CBUUID(string: "2A28")]

    override convenience init() {
        self.init(startManager: true)
    }

    /// `startManager: false` skips creating the `CBCentralManager`, used by the app host under
    /// XCTest where CoreBluetooth's XPC service is unavailable (headless CI simulator) and would
    /// otherwise log "XPC connection invalid" and hang. No BLE method is called in that mode.
    init(startManager: Bool) {
        super.init()
        if startManager {
            // State restoration: if iOS kills the app mid-workout, a BLE event (e.g. the ring's HR
            // stream notifying) relaunches us and `willRestoreState` re-adopts the connection.
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "pulseloop.ring.central"] // install-bound: state-restoration id
            )
        }
    }

    // MARK: - Public API

    /// Pairing scans list every named peripheral; a reconnect scan looks for the one known ring.
    enum ScanMode: Equatable { case pairing, reconnect }

    /// The Agara ring's advertised service (`docs/ring/veepoo-protocol.md` §1: name, `FEE7`, `f8f8` data).
    static let ringAdvertisedService = CBUUID(string: "FEE7")
    /// An unfiltered scan is the most expensive radio mode; it runs this long before narrowing.
    static let scanTimeoutSeconds: UInt64 = 30
    private var scanMode: ScanMode = .pairing
    private var scanTimeoutTask: Task<Void, Never>?

    func startScanning() { startScanning(mode: .pairing) }

    /// - `.pairing`: unfiltered for `scanTimeoutSeconds` (so a firmware that hides its service is still
    ///   listed), then narrowed to a `FEE7`-filtered scan — cheap enough to leave running while the
    ///   pairing screen is up, and stopped by `stopScanning`.
    /// - `.reconnect`: `FEE7`-filtered from the start, connects to the last known ring when it shows up,
    ///   and gives up after `scanTimeoutSeconds` (the next foreground or pull-to-refresh tries again).
    ///   It used to be an unfiltered scan with no end and no auto-connect.
    func startScanning(mode: ScanMode) {
        #if DEBUG
        // E2E: a deferred virtual ring (`-virtualRingOnPair YES`) "is found" by the scan and connects.
        // Pairing it is a fresh start, like `connect(to:)` for a real ring: full history download.
        if mode == .pairing, VirtualRingLink.configuredPort != nil {
            SyncPlanStore.shared.reset(ring: Self.virtualHistoryRingID)
        }
        if VirtualRingLink.shared.attachDeferredIfNeeded() {
            lastError = nil
            state = .scanning
            return
        }
        #endif
        guard isBluetoothReady else {
            lastError = "Bluetooth is not powered on."
            return
        }
        discovered = []
        discoveredPeripherals = [:]
        lastError = nil
        autoReconnect = true
        state = .scanning
        scanMode = mode
        // Pairing: no service filter so we also catch firmwares that don't advertise their service UUID;
        // matching is done in didDiscover via the coordinator registry.
        central?.scanForPeripherals(withServices: mode == .pairing ? nil : [Self.ringAdvertisedService],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        armScanTimeout()
    }

    private func armScanTimeout() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.scanTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.state == .scanning else { return }
            self.scanTimedOut()
        }
    }

    private func scanTimedOut() {
        central?.stopScan()
        switch Self.scanAfterTimeout(mode: scanMode) {
        case .filtered:
            central?.scanForPeripherals(withServices: [Self.ringAdvertisedService],
                                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .stop:
            state = .idle
            resumeProximityScanIfNeeded()
        }
    }

    enum ScanTimeoutAction: Equatable { case filtered, stop }

    /// What a scan does when its unfiltered/initial window ends (pure, for tests).
    static func scanAfterTimeout(mode: ScanMode) -> ScanTimeoutAction {
        mode == .pairing ? .filtered : .stop
    }

    func stopScanning() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central?.stopScan()
        if state == .scanning { state = .idle }
        resumeProximityScanIfNeeded()
    }

    // MARK: Signal strength (Find ring, `RingSignalSource`)

    /// Receives every signal-strength reading while Find ring is open: the connected link's RSSI
    /// (`readLinkRSSI` → `peripheral(_:didReadRSSI:error:)`) and, while disconnected, the known ring's advertisements.
    @ObservationIgnored private var signalListener: ((Int) -> Void)?
    /// The ring the proximity scan looks for (nil: no proximity scan).
    @ObservationIgnored private var proximityScanTarget: UUID?

    func setSignalListener(_ listener: ((Int) -> Void)?) { signalListener = listener }

    /// Ask CoreBluetooth for the connected link's RSSI; false when there is no connected peripheral.
    @discardableResult
    func readLinkRSSI() -> Bool {
        guard state == .connected, let peripheral, peripheral.state == .connected else { return false }
        peripheral.readRSSI()
        return true
    }

    /// Scan for the known ring's advertisements (FEE7-filtered, duplicates on, so every advertisement carries a fresh
    /// RSSI). Leaves `state` alone — it runs beside the client's reconnect logic. No-op when already scanning for it.
    func startProximityScan() {
        guard isBluetoothReady, let target = lastKnownIdentifier ?? peripheral?.identifier else { return }
        guard proximityScanTarget != target else { return }
        proximityScanTarget = target
        if state != .scanning { applyProximityScan() }
    }

    func stopProximityScan() {
        guard proximityScanTarget != nil else { return }
        proximityScanTarget = nil
        if state != .scanning { central?.stopScan() }
    }

    var isProximityScanning: Bool { proximityScanTarget != nil }

    private func applyProximityScan() {
        central?.scanForPeripherals(withServices: [Self.ringAdvertisedService],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// A pairing/reconnect scan ended (it replaced the proximity scan's parameters): put the proximity scan back.
    private func resumeProximityScanIfNeeded() {
        if proximityScanTarget != nil, state != .scanning { applyProximityScan() }
    }

    // MARK: Reconnect backoff

    /// Re-dials after a failed or dropped link. The first retry is an immediate pending connect (the
    /// normal CoreBluetooth pattern: it costs nothing until the ring is in range); a link that keeps
    /// failing or flapping backs off 2, 4, 8 … 60 s instead of re-dialing in a tight loop.
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(60, pow(2, Double(min(attempt, 6))))
    }

    private func scheduleReconnect(_ target: CBPeripheral) {
        let delay = Self.reconnectDelay(attempt: reconnectAttempts)
        reconnectAttempts += 1
        reconnectTask?.cancel()
        guard delay > 0 else {
            central?.connect(target, options: nil)
            return
        }
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.autoReconnect, self.peripheral?.identifier == target.identifier,
                  self.state == .reconnecting else { return }
            self.central?.connect(target, options: nil)
        }
    }

    /// - Parameter preferredFamily: the family the *user* declared at pairing (the app-type picker on a
    ///   the ring card). Non-nil wins over the scan's auto-match — see `coordinatorType(preferredFamily:autoMatched:)`.
    func connect(to id: UUID, selectedModelID: String? = nil, preferredFamily: RingDeviceType? = nil) {
        // Prefer the freshly-scanned object; fall back to the system cache (paired/known).
        guard let target = discoveredPeripherals[id] ?? central?.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "Ring no longer available; scan again."
            return
        }
        // A pairing is a fresh start: this ring's next pass downloads every day in full (`SyncPlan`).
        SyncPlanStore.shared.reset(ring: id.uuidString)
        // Use the matched device type from discovery if we have it.
        let discoveredRing = discovered.first { $0.id == id }
        beginConnect(
            to: target,
            deviceType: discoveredRing?.deviceType,
            selectedModelID: Self.modelIDForConnect(
                selectedModelID: selectedModelID,
                scanInferredModelID: discoveredRing?.wearableModelID
            ),
            advertisedName: discoveredRing?.name,
            preferredFamily: preferredFamily,
            userInitiated: true
        )
    }

    /// The carousel selection is an explicit user statement; scan inference is only its fallback.
    /// This matters for an earlier ring, whose generic `SMART_RING` name is inferred as the ring.
    static func modelIDForConnect(selectedModelID: String?, scanInferredModelID: String?) -> String? {
        selectedModelID ?? scanInferredModelID
    }

    /// Silently reconnect to the last paired ring (used on launch). Falls back to scanning.
    func connectLastKnown() {
        #if DEBUG
        if VirtualRingLink.shared.hasDeferredRing, VirtualRingLink.shared.attachDeferredIfNeeded() { return }
        #endif
        guard isBluetoothReady, let id = lastKnownIdentifier else { return }
        if let known = central?.retrievePeripherals(withIdentifiers: [id]).first {
            beginConnect(
                to: known,
                deviceType: lastKnownDeviceType,
                selectedModelID: lastKnownWearableModelID,
                advertisedName: known.name
            )
        } else {
            startScanning(mode: .reconnect)
        }
    }

    func disconnect() {
        autoReconnect = false
        reconnectTask?.cancel()
        scanTimeoutTask?.cancel()
        #if DEBUG
        if VirtualRingLink.shared.userDisconnect() { return }
        #endif
        cancelConnectTimeout()   // an explicit disconnect is not a failed connect attempt
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        } else {
            state = .idle
        }
    }

    /// Forget the active/last ring: release it (the ring sends the 0x4B UNBOND so the ring re-advertises
    /// for other apps), then disconnect and clear the remembered identifier + device type so the app no
    /// longer auto-reconnects to it. The unbind is best-effort — we give the write a short window to
    /// flush before tearing the link down, but never block Forget on it.
    func forget() {
        if state == .connected, let engine = activeSyncEngine {
            engine.unbind()
            // Let the UNBOND write flush (and the ring ACK) before we drop the link.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                finalizeForget()
            }
        } else {
            finalizeForget()
        }
    }

    private func finalizeForget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceTypeKey)
        UserDefaults.standard.removeObject(forKey: Self.lastWearableModelKey)
        UserDefaults.standard.removeObject(forKey: Self.lastCapabilitiesKey)   // a new ring must not inherit the old one's claims
        SyncPlanStore.shared.resetAll()   // a later pairing starts with a full history download
        activeDeviceType = nil
        activeWearableModelID = nil
        activeCapabilities = []
        activeAdvertisedName = nil
        publish(.deviceForgotten)
    }

    /// Queue a logical command for writing. The active driver's framing (padding/checksum) is applied
    /// here, so callers/engines deal in unframed commands. The driver also decides whether the frame
    /// goes to the normal write char or the big-data command char. Writes are serialized.
    func enqueueWrite(_ data: Data, completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        let framed = activeDriver?.frame(data) ?? data
        let useCommand = activeDriver?.usesCommandChannel(for: framed) ?? false
        writeQueue.append(PendingWrite(data: framed, useCommandChannel: useCommand, completion: completion))
        pumpWrites()
    }

    /// Put commands at the **head** of the write queue, preserving their order relative to each other.
    ///
    /// Only for `WearableDriver.immediatePostSubscriptionCommands()`. Everything else must append: the
    /// queue is what makes writes serial and ordered, and a caller jumping it would reorder a protocol
    /// that depends on its own sequence.
    private func prependWrites(_ commands: [Data]) {
        let framed = commands.map { command -> PendingWrite in
            let framed = activeDriver?.frame(command) ?? command
            return PendingWrite(data: framed, useCommandChannel: activeDriver?.usesCommandChannel(for: framed) ?? false)
        }
        writeQueue.insert(contentsOf: framed, at: 0)
    }

    func readBattery() {
        guard let peripheral, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    var lastKnownIdentifier: UUID? {
        UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init)
    }

    var lastKnownDeviceType: RingDeviceType? {
        UserDefaults.standard.string(forKey: Self.lastDeviceTypeKey).flatMap(RingDeviceType.init)
    }

    var lastKnownWearableModelID: String? {
        UserDefaults.standard.string(forKey: Self.lastWearableModelKey)
    }

    /// What the last connected ring resolved to *after* its capability bitmap had spoken — the baseline
    /// plus whatever the unit itself claimed (`applySupportFunctions`).
    ///
    /// Remembered because the bitmap arrives partway into a handshake, while `Device.capabilitiesRaw` is
    /// overwritten wholesale at the *start* of one. Without this, every connect would first stamp the
    /// device back down to the family baseline — so a ring whose temperature sensor we already know about
    /// would drop its Vitals card on every launch and only get it back a second later, and a handshake
    /// whose `02 01` reply is lost (or answered by firmware with a short array) would leave it dropped
    /// for the whole session and while offline afterwards.
    var lastKnownCapabilities: Set<WearableCapability> {
        Set(csv: UserDefaults.standard.string(forKey: Self.lastCapabilitiesKey) ?? "")
    }

    var hasLastKnownRing: Bool {
        #if DEBUG
        if VirtualRingLink.shared.hasDeferredRing { return true }
        #endif
        return lastKnownIdentifier != nil
    }

    /// The active sync engine, exposed so the `RingSyncCoordinator` façade can drive command flows.
    var syncEngine: RingSyncEngine? { activeSyncEngine }

    // MARK: - Internal

    /// - Parameters:
    ///   - preferredFamily: an explicitly user-declared family; wins over `deviceType` (the auto-match).
    ///   - userInitiated: the user tapped a ring in the pairing screen, so a connect that never lands is
    ///     a dead end they need told about — arm the connect-attempt timeout. Background reconnects pass
    ///     false: a pending connect that waits forever is exactly what they're *for*.
    private func beginConnect(
        to target: CBPeripheral,
        deviceType: RingDeviceType?,
        selectedModelID: String?,
        advertisedName: String?,
        preferredFamily: RingDeviceType? = nil,
        userInitiated: Bool = false
    ) {
        central?.stopScan()
        scanTimeoutTask?.cancel()
        reconnectTask?.cancel()
        reconnectAttempts = 0
        autoReconnect = true
        // Force-close any stale connection (incl. a different peripheral) before opening a new one, so
        // a reconnect after an idle drop can't collide with an orphaned handle. iOS analogue of
        // Android's gatt.disconnect()+close(). Reset the per-connection write state too.
        stopReliabilityTimers()
        cancelConnectTimeout()
        if let old = peripheral, old.identifier != target.identifier || old.state != .disconnected {
            central?.cancelPeripheralConnection(old)
        }
        writeChar = nil; commandChar = nil; notifyChars = [:]; batteryCharacteristic = nil
        subscribedNotifyUUIDs = []
        cancelPendingWrites()
        clearOtaChannel()
        peripheral = target
        target.delegate = self
        // Select the coordinator/driver for this connection: the user's declared family if they made
        // one, else the auto-match, else the ring (an unknown cached peripheral — prior behavior).
        let coordinatorType = Self.coordinatorType(preferredFamily: preferredFamily, autoMatched: deviceType)
        activeAdvertisedName = advertisedName
        activeWearableModelID = WearableModel.resolve(
            advertisedName: advertisedName,
            selectedModelID: selectedModelID,
            family: coordinatorType.deviceType
        )?.id
        installDriver(coordinatorType)
        state = .connecting
        if userInitiated { startConnectTimeout() }
        central?.connect(target, options: nil)
    }

    /// Instantiate the coordinator's driver + sync engine for the upcoming connection. A fresh driver
    /// per connection keeps per-connection state from leaking across reconnects.
    ///
    /// Capabilities start from what we last *learned* about the ring, not from the bare family baseline:
    /// the remembered set is fed back through the same additive-only refinement (`refinedCapabilities`),
    /// so it can only re-grant capabilities this family gates on the bitmap — a set remembered from a
    /// different family, or one naming something this family never gates, cannot leak in. The ring's own
    /// bitmap still overrules it moments later (`applySupportFunctions`), downwards as well as upwards.
    func installDriver(_ coordinatorType: WearableCoordinator.Type) {
        let coordinator = coordinatorType.init()
        let driver = coordinator.makeDriver(writer: self)
        activeCoordinator = coordinator
        activeDriver = driver
        activeSyncEngine = driver.makeSyncEngine()
        activeDeviceType = coordinatorType.deviceType
        activeCapabilities = coordinator.refinedCapabilities(bitmapDerived: lastKnownCapabilities)
        isCharging = false
        ringBatteryPercent = nil
        ringCapabilities = nil
    }

    /// Re-adopt the remembered ring's identity: its family **and** the exact catalog model.
    ///
    /// State restoration is the one connect path with no advertisement to re-derive either from. The
    /// family was already remembered; the model id was not, and a restored session that reached
    /// `.connected` without it published `.deviceIdentified(wearableModelID: nil)` — which *erases*
    /// `Device.wearableModelID`, costing the device card its product name and art until some later
    /// reconnect happened to carry a resolvable GAP name.
    func adoptRememberedIdentity() {
        // The remembered family already *is* the user's choice — `beginConnect` persisted whichever
        // coordinator it selected — so a restored session re-adopts the right driver for free.
        installDriver(Self.coordinatorType(preferredFamily: nil, autoMatched: lastKnownDeviceType))
        activeWearableModelID = lastKnownWearableModelID
    }

    /// Fold the ring's self-reported capability bitmap into the active capability set.
    ///
    /// `installDriver` seeds `activeCapabilities` with the coordinator's baseline — what the *family*
    /// can do. This is where *this unit* gets a say, which is what makes one driver able to serve SKUs
    /// that differ on which sensors they physically have. The bitmap can only add capabilities the
    /// family pre-approved (`refinedCapabilities`), so a family that gates none is untouched.
    ///
    /// Re-publishing `.deviceIdentified` is what carries the refined set into `Device.capabilitiesRaw`;
    /// the equality guard keeps that idempotent, because the bitmap arrives on *every* handshake and a
    /// reconnect runs a fresh one — without it, each reconnect would re-publish an identical set and
    /// churn the bus and the store for nothing.
    private func applySupportFunctions(_ derived: Set<WearableCapability>) {
        guard let coordinator = activeCoordinator, let type = activeDeviceType else { return }
        let refined = coordinator.refinedCapabilities(bitmapDerived: derived)
        // Remember the answer even when it changes nothing right now: this is what seeds the *next*
        // connect, before that connect's own bitmap has arrived (see `lastKnownCapabilities`).
        UserDefaults.standard.set(refined.csv, forKey: Self.lastCapabilitiesKey)
        guard refined != activeCapabilities else { return }
        activeCapabilities = refined
        publish(.deviceIdentified(
            deviceType: type,
            wearableModelID: activeWearableModelID,
            advertisedName: activeAdvertisedName,
            capabilities: refined,
            peripheralIdentifier: deviceIdentifier
        ))
    }

    private func pumpWrites() {
        #if DEBUG
        if virtualFrameSink != nil { pumpVirtualWrites(); return }
        #endif
        guard !writeInFlight,
              let peripheral,
              let writeChar,
              !writeQueue.isEmpty else { return }
        // Big-data requests go to the command char (`de5bf72a`); fall back to the write char if the
        // device/firmware didn't expose a separate one.
        let target = (writeQueue[0].useCommandChannel ? commandChar : writeChar) ?? writeChar

        // The write type must come from the characteristic, not a constant. A characteristic that only
        // supports write-without-response (an earlier family's `B002`) silently *discards* a `.withResponse`
        // write — CoreBluetooth never calls `didWriteValueFor`, so every packet used to sit out the
        // full missed-ACK timeout and the device never received a byte. This mirrors Android's
        // `writeCharacteristic`, which auto-selects the type from the properties.
        let type: CBCharacteristicWriteType =
            target.properties.contains(.write) ? .withResponse : .withoutResponse

        if type == .withoutResponse {
            // No ATT round-trip to serialize on; pace with the peripheral's buffer instead.
            // `peripheralIsReady(toSendWriteWithoutResponse:)` re-pumps when it drains.
            guard peripheral.canSendWriteWithoutResponse else { return }
            let item = writeQueue.removeFirst()
            publishRawPacket(direction: .outgoing, data: item.data)
            // Deliberately no `noteActivity()`: an unacknowledged write proves nothing about the link,
            // and crediting it would blind the watchdog to a zombie connection during a silent sync.
            peripheral.writeValue(item.data, for: target, type: .withoutResponse)
            item.completion?(.success(()))
            pumpWrites()
            return
        }

        let item = writeQueue.removeFirst()
        writeInFlight = true
        inFlightCompletion = item.completion
        writeSeq &+= 1
        let seq = writeSeq
        publishRawPacket(direction: .outgoing, data: item.data)
        peripheral.writeValue(item.data, for: target, type: .withResponse)
        // Guard against a missed `didWriteValueFor`: if this write is still in flight after the
        // timeout, unblock the queue so one dropped ACK can't wedge it (Android write-ACK timeout).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: writeAckTimeout)
            if writeInFlight, seq == writeSeq {
                // ATT callbacks have no request identifier. Retire the link so a late ACK cannot
                // accidentally complete the next write after this deadline.
                cancelPendingWrites(error: RingWriteError.timedOut)
                central?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func cancelPendingWrites(error: Error = CancellationError()) {
        let callbacks = [inFlightCompletion].compactMap { $0 } + writeQueue.compactMap(\.completion)
        inFlightCompletion = nil
        writeChar = nil
        commandChar = nil
        writeQueue.removeAll()
        writeInFlight = false
        writeSeq &+= 1
        for callback in callbacks { callback(.failure(error)) }
    }

    // MARK: - Connection reliability

    /// Record that the link just proved itself alive (notification / write ACK / read).
    private func noteActivity() { lastActivityAt = Date() }

    /// Watchdog: CoreBluetooth doesn't always deliver a disconnect when the OS tears the link down in
    /// the background, leaving a "zombie" peripheral that's `.connected` but silent. If we've gone
    /// `linkStaleSeconds` with no inbound activity, force a reconnect. Also catches a hung connect.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTicks = 0
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.watchdogInterval ?? 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        // Periodic battery re-read (~every 60 min at the 15s cadence): the ring reports battery only on
        // connect, so refresh it here. the ring's engine re-requests 0x03; both are harmless no-ops when
        // unsupported. Runs before the stale-link check (which may return early).
        watchdogTicks += 1
        if watchdogTicks >= 240, state == .connected {
            watchdogTicks = 0
            readBattery()                                // standard GATT battery; no-op when absent
            activeSyncEngine?.requestBattery()           // protocol battery request; default no-op
        }
        guard isBluetoothReady, state == .connected, let last = lastActivityAt else { return }
        if Date().timeIntervalSince(last) > linkStaleSeconds {
            // Zombie link: drop it and let the disconnect handler's auto-reconnect re-link.
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    private func stopReliabilityTimers() {
        watchdogTask?.cancel(); watchdogTask = nil
    }

    // MARK: Connect-attempt timeout

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.connectTimeout ?? 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.connectAttemptTimedOut()
        }
    }

    /// Deliberately *not* folded into `stopReliabilityTimers`: that also runs on an unexpected disconnect,
    /// where the client re-dials and the attempt is still live — cancelling there would disarm the very
    /// case this guards.
    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    /// The user's connect never reached `.connected`. Give up, and say why in terms they can act on.
    private func connectAttemptTimedOut() {
        guard state == .connecting || state == .reconnecting else { return }
        connectTimeoutTask = nil
        // Order matters: `didDisconnectPeripheral` re-dials whenever `autoReconnect` is set, so clearing
        // it *before* the cancel is what stops the failure from instantly reconnecting itself.
        autoReconnect = false
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        stopReliabilityTimers()
        // Names the app variant we tried and the one to try instead — the whole point of failing loudly
        // here is that the wrong-app pick is recoverable in one tap (`PairingView`).
        lastError = RingConnectFailure.message(family: activeDeviceType)
        state = .failed
        publish(.deviceStateChanged(state: .failed, address: nil))
    }

    private func publishRawPacket(direction: PacketDirection, data: Data) {
        guard RawPacketCapture.isEnabled else { return }   // nobody stores it; skip the bus hop
        // Outgoing frames are logged raw for the debug feed. We do NOT route them through the
        // driver's `ingest` (that is the inbound path and, for big-data devices, would corrupt the
        // reassembly buffer). The command id is enough annotation for the trace.
        let decoded = RingDecodedEvent.commandAck(commandId: data.first ?? 0)
        publish(.rawPacket(direction: direction, data: data, decoded: decoded))
    }

    private func publish(_ event: AgaraEvent) {
        Task { await AgaraEventBus.shared.publish(event) }
    }

    /// Lift CoreBluetooth's raw advertisement dictionary into `AdvertisementInfo` and claim it against
    /// the registry.
    private func matchDeviceType(name: String?, advertisementData: [String: Any]) -> RingDeviceType? {
        Self.matchDeviceType(name: name, advertisement: AdvertisementInfo(
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [],
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        ))
    }
}

// MARK: - RingCommandWriter

extension RingBLEClient: RingCommandWriter {
    var deviceIdentifier: String? { peripheral?.identifier.uuidString }
    var connectionSource: String? {
        #if DEBUG
        if virtualFrameSink != nil { return SleepSource.virtualTransport }
        #endif
        return deviceIdentifier
    }
    var historyRingID: String? {
        #if DEBUG
        if virtualFrameSink != nil { return Self.virtualHistoryRingID }
        #endif
        return deviceIdentifier
    }
    #if DEBUG
    /// The emulator socket's ledger identity: one per port, since each emulator serves its own data.
    static var virtualHistoryRingID: String {
        "\(SleepSource.virtualTransport):\(VirtualRingLink.configuredPort.map(String.init) ?? "?")"
    }
    #endif
    /// Drivers / sync engines enqueue logical commands through this seam; framing is applied in
    /// `enqueueWrite`.
    func enqueue(_ command: Data) {
        enqueueWrite(command)
    }

    func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard peripheral?.state == .connected, writeChar != nil else {
            completion(.failure(RingWriteError.disconnected))
            return
        }
        let tracked = RingTrackedWrite(timeoutError: RingWriteError.timedOut, onTimeout: { [weak self] in
            guard let self else { return }
            self.cancelPendingWrites(error: RingWriteError.timedOut)
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
        }, completion: completion)
        enqueueWrite(command, completion: { tracked.finish($0) })
    }

    func emit(_ event: RingDecodedEvent) {
        deliverDecoded(event)
    }

    private func deliverDecoded(_ decoded: RingDecodedEvent) {
        for event in RingNotificationDelivery.events(for: decoded) { publish(event) }
        if case let .supportFunctions(derived) = decoded { applySupportFunctions(derived) }
        if case let .firmware(version, _, _) = decoded, !version.isEmpty { firmwareSinceConnect = version }
        if case let .ringCapabilities(capabilities) = decoded { ringCapabilities = capabilities }
        if case let .battery(percent) = decoded {
            ringBatteryPercent = percent
            let reading = ChargeEstimator.Reading(date: Date(), percent: percent)
            lastBatteryReading = reading
            if isCharging { chargeSeries.add(percent: reading.percent, at: reading.date) }
        }
        if case let .chargingState(charging) = decoded {
            if charging != isCharging { isCharging = charging }
            if charging, let reading = lastBatteryReading {
                chargeSeries.add(percent: reading.percent, at: reading.date)   // same frame → deduplicated
            }
        }
        activeSyncEngine?.handle(decoded)
    }

    // MARK: - Virtual transport (DEBUG only)

    #if DEBUG
    /// Debug-only socket transport used by `ring-emulator`, so the whole app pipeline (decode →
    /// store → UI → cloud) can be exercised on one machine without a ring, a phone or CoreBluetooth.
    ///
    /// Nothing about the BLE path changes: the frame still goes through the same driver, the same
    /// write queue, the same `RingNotificationDelivery` decode and the same event bus.
    ///
    /// Bring the client up on the virtual transport, running the same post-connect steps a real GATT
    /// link runs — the driver's lead handshake (`immediatePostSubscriptionCommands`, i.e. the Veepoo
    /// A1 open frame) and then `onConnected` (the sync engine's startup sequence).
    func beginVirtualConnection(
        coordinator: WearableCoordinator.Type = VeepooCoordinator.self,
        advertisedName: String = "TK20",
        wearableModelID: String? = "tk20",
        sink: @escaping (String?, Data) -> Void
    ) {
        installDriver(coordinator)
        virtualFrameSink = sink
        clearOtaChannel()
        otaServiceAvailable = true
        activeAdvertisedName = advertisedName
        activeWearableModelID = wearableModelID
        subscribedNotifyUUIDs = Set(activeDriver?.notifyUUIDs ?? [])
        // Start the handshake with a
        // clean slate, exactly like a fresh GATT link does.
        activeDriver?.connectionDidStart()
        activeSyncEngine?.connectionDidStart()
        state = .connected
        if let type = activeDeviceType {
            publish(.deviceIdentified(
                deviceType: type,
                wearableModelID: activeWearableModelID,
                advertisedName: advertisedName,
                capabilities: activeCapabilities
            ))
        }
        publish(.deviceStateChanged(state: .connected, address: nil))
        noteActivity()
        prependWrites(activeDriver?.immediatePostSubscriptionCommands() ?? [])
        onConnected?()
        pumpWrites()
    }

    /// Feed one frame from the virtual transport through the identical path a GATT notification takes.
    func injectVirtualNotification(_ data: Data, from characteristic: CBUUID) {
        if characteristic == otaNotifyCBUUID {
            handleOtaNotify(data)
            return
        }
        guard let driver = activeDriver, driver.notifyUUIDs.contains(characteristic) else { return }
        noteActivity()
        RingNotificationDelivery.receive(data,
            decode: { driver.ingest(data, from: characteristic) },
            publish: { publish($0) }, deliver: { deliverDecoded($0) })
    }

    func endVirtualConnection() {
        virtualFrameSink = nil
        writeQueue.removeAll()
        clearOtaChannel()
        otaListener?(.dropped)
        activeSyncEngine?.connectionDidEnd()
        activeDriver?.connectionDidEnd()
        activeDriver = nil
        activeCoordinator = nil
        activeSyncEngine = nil
        activeDeviceType = nil
        isCharging = false
        state = .disconnected
        publish(.deviceStateChanged(state: .disconnected, address: nil))
    }

    /// The virtual transport has no ATT round-trip to serialize on, so every queued frame is handed
    /// to the sink and completed at once — the queue still preserves the order the ring expects.
    private func pumpVirtualWrites() {
        guard let sink = virtualFrameSink else { return }
        while !writeQueue.isEmpty {
            let item = writeQueue.removeFirst()
            publishRawPacket(direction: .outgoing, data: item.data)
            sink(nil, item.data)
            item.completion?(.success(()))
        }
    }
    #endif
}

// MARK: - Firmware update channel (AB-OTA on F003; plan firmware-update stage 4)

extension RingBLEClient {
    /// Receive every `F031` notification and link drop while an install runs; nil detaches.
    func setOtaListener(_ listener: ((OtaLinkEvent) -> Void)?) { otaListener = listener }

    /// Prepare `F003` on the current connection: enable `F031` notifications (never done until an install
    /// asks). Returns the largest frame the link carries write-without-response (CoreBluetooth negotiates the
    /// MTU itself), or nil when the ring has no update service or the notification can't be enabled.
    func openOtaChannel(timeout: TimeInterval = 5) async -> Int? {
        guard otaServiceAvailable else { return nil }
        #if DEBUG
        if virtualFrameSink != nil { return Self.virtualOtaFrameLimit }
        #endif
        guard let peripheral, let notify = otaNotifyChar, otaWriteChar != nil else { return nil }
        if !otaNotifyEnabled {
            peripheral.setNotifyValue(true, for: notify)
            let deadline = Date().addingTimeInterval(timeout)
            while !otaNotifyEnabled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard otaNotifyEnabled else { return nil }
        }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        NSLog("[OTA] channel ready, write limit \(limit) B")
        return limit
    }

    /// One firmware-update frame to `F032` (write-without-response, in order). Logged header-only.
    func writeOta(_ frame: Data) {
        publishOtaPacket(frame, outgoing: true)
        #if DEBUG
        if let sink = virtualFrameSink {
            sink(AbOta.writeUUID, frame)
            return
        }
        #endif
        otaWriteQueue.append(frame)
        pumpOtaWrites()
    }

    /// Bring the ring back after a drop during an update, or after it restarts with new firmware: the socket
    /// link re-attaches to the emulator; Bluetooth re-dials the known peripheral.
    func reconnectForFirmwareUpdate() {
        #if DEBUG
        if VirtualRingLink.configuredPort != nil {
            VirtualRingLink.shared.reattach()
            return
        }
        #endif
        guard state != .connected else { return }
        if let peripheral {
            autoReconnect = true
            if peripheral.state == .disconnected {
                state = .reconnecting
                central?.connect(peripheral, options: nil)
            }
        } else {
            connectLastKnown()
        }
    }

    /// Drain the `F032` queue while the peripheral's without-response buffer has room;
    /// `peripheralIsReady(toSendWriteWithoutResponse:)` resumes it.
    fileprivate func pumpOtaWrites() {
        guard let peripheral, let target = otaWriteChar else { return }
        while !otaWriteQueue.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(otaWriteQueue.removeFirst(), for: target, type: .withoutResponse)
        }
    }

    fileprivate func handleOtaNotify(_ data: Data) {
        noteActivity()
        publishOtaPacket(data, outgoing: false)
        otaListener?(.notify(data))
    }

    /// The raw-packet capture keeps each OTA frame's header/offset/status (never block payloads).
    private func publishOtaPacket(_ frame: Data, outgoing: Bool) {
        guard RawPacketCapture.isEnabled else { return }
        let event = AgaraEvent.rawPacket(
            direction: outgoing ? .outgoing : .incoming,
            data: AbOta.logBytes(frame, outgoing: outgoing),
            decoded: .otaFrame(commandId: frame.first ?? 0, summary: AbOta.summary(frame, outgoing: outgoing))
        )
        Task { await AgaraEventBus.shared.publish(event) }
    }

    /// Find `F031` / `F032` in the `F003` service (never subscribed until an install asks).
    fileprivate func bindOtaService(_ service: CBService) {
        otaNotifyChar = service.characteristics?.first { $0.uuid == otaNotifyCBUUID }
        otaWriteChar = service.characteristics?.first { $0.uuid == otaWriteCBUUID }
        otaNotifyEnabled = false
        otaServiceAvailable = otaNotifyChar != nil && otaWriteChar != nil
        NSLog("[OTA] update service \(otaServiceAvailable ? "present" : "absent")")
    }

    fileprivate func clearOtaChannel() {
        otaNotifyChar = nil
        otaWriteChar = nil
        otaNotifyEnabled = false
        otaWriteQueue.removeAll()
        otaServiceAvailable = false
        firmwareSinceConnect = nil
    }
}

private enum RingWriteError: LocalizedError {
    case disconnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .disconnected: return "The ring disconnected before the command was sent."
        case .timedOut: return "The ring did not acknowledge the Bluetooth write."
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RingBLEClient: CBCentralManagerDelegate {
    /// iOS relaunched us to service a preserved BLE session (e.g. the ring's HR stream notified
    /// while we were dead). Re-adopt the peripheral and remembered driver here; the actual
    /// connect/discovery is deferred to `centralManagerDidUpdateState` — restoration fires before
    /// power-on completes, and issuing `connect` that early is API misuse.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
            guard peripheral == nil, let target = restored.first else { return }
            autoReconnect = true
            peripheral = target
            target.delegate = self
            adoptRememberedIdentity()
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            isBluetoothReady = (central.state == .poweredOn)
            bluetoothAvailability = BluetoothAvailability(central.state)
            switch central.state {
            case .poweredOn:
                if let restored = peripheral, state != .connected {
                    // Adopted in willRestoreState — resume from wherever the link actually is.
                    if restored.state == .connected {
                        state = .connecting
                        restored.discoverServices(nil)
                    } else {
                        state = .reconnecting
                        central.connect(restored, options: nil)
                    }
                } else if autoReconnect, hasLastKnownRing, peripheral == nil {
                    connectLastKnown()
                }
            case .poweredOff, .unauthorized, .unsupported:
                cancelPendingWrites()
                clearOtaChannel()
                otaListener?(.dropped)
                activeDriver?.connectionDidEnd()
                activeSyncEngine?.connectionDidEnd()
                state = .idle
                lastError = "Bluetooth unavailable (\(central.state.rawValue))."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            // Find ring: the known ring's advertisement strength while the link is down.
            if let target = proximityScanTarget, peripheral.identifier == target {
                signalListener?(RSSI.intValue)
                if state != .scanning { return }
            }
            // Reconnect scan: the known ring showed up — connect to it and stop looking.
            if scanMode == .reconnect, state == .scanning, peripheral.identifier == lastKnownIdentifier {
                stopScanning()
                beginConnect(to: peripheral, deviceType: lastKnownDeviceType,
                             selectedModelID: lastKnownWearableModelID, advertisedName: peripheral.name)
                return
            }
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            let matchedType = matchDeviceType(name: name, advertisementData: advertisementData)
            let matchedModel = WearableModel.model(advertisedName: name)
            // List any *named* peripheral so the user can always find their ring, even if its
            // advertisement omits the service UUID / manufacturer bytes; recognized rings sort first.
            guard let displayName = name, !displayName.isEmpty else { return }
            discoveredPeripherals[peripheral.identifier] = peripheral
            // Keep the model tag when the matched family is *any* the card can resolve to, not just its
            // default — a row the scan claimed as another family is still the ring on the other end.
            let modelID: String? = {
                guard let matchedModel, let matchedType,
                      matchedModel.families.contains(matchedType) else { return nil }
                return matchedModel.id
            }()
            let ring = DiscoveredRing(
                id: peripheral.identifier,
                name: displayName,
                rssi: RSSI.intValue,
                isLikelyRing: matchedType != nil,
                deviceType: matchedType,
                wearableModelID: modelID
            )
            if let index = discovered.firstIndex(where: { $0.id == ring.id }) {
                discovered[index] = ring
            } else {
                discovered.append(ring)
            }
            discovered.sort { ($0.isLikelyRing ? 0 : 1, -$0.rssi) < ($1.isLikelyRing ? 0 : 1, -$1.rssi) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            // Auto-reconnect keeps the existing driver, so tell it the link is new: anything half-read
            // when the old link dropped (a partial frame, an in-flight history transfer) must go.
            activeDriver?.connectionDidStart()
            activeSyncEngine?.connectionDidStart()
            firmwareSinceConnect = nil
            // Discover ALL services so we also find a Device Information Service the ring exposes
            // without advertising it (firmware revision lives there). Characteristic discovery below
            // filters to the driver's chars + battery + firmware.
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            lastError = error?.localizedDescription ?? "Failed to connect."
            // Don't dead-end at .failed during a workout: keep a pending reconnect alive so iOS
            // re-links the ring as soon as it's back in range.
            if autoReconnect, let peripheral = self.peripheral {
                state = .reconnecting
                publish(.deviceStateChanged(state: .reconnecting, address: nil))
                scheduleReconnect(peripheral)
            } else {
                state = .failed
                publish(.deviceStateChanged(state: .failed, address: nil))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == peripheral.identifier else { return }
            stopReliabilityTimers()
            lastActivityAt = nil
            writeChar = nil
            commandChar = nil
            notifyChars = [:]
            subscribedNotifyUUIDs = []
            batteryCharacteristic = nil
            cancelPendingWrites()
            clearOtaChannel()
            otaListener?(.dropped)
            // Stop the driver's own state machines *now*, not on the next connect: a self-driving one
            // (an earlier protocol history transfer's stall watchdog) would otherwise keep stepping through the
            // reconnect gap and refill the queue we just cleared, and those stale queries would be the
            // first thing the new link writes — ahead of its handshake.
            activeDriver?.connectionDidEnd()
            activeSyncEngine?.connectionDidEnd()
            isCharging = false
            publish(.deviceStateChanged(state: .disconnected, address: nil))
            if autoReconnect {
                state = .reconnecting
                scheduleReconnect(peripheral)
            } else {
                // A connect-attempt timeout has already parked us in `.failed` with an explanatory
                // message, and the cancel *it* issued is what brought us here — it must not overwrite
                // that with a bland `.disconnected`.
                if state != .failed { state = .disconnected }
                self.peripheral = nil
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingBLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let driver = activeDriver else { return }
            // Full service list first, before any characteristic I/O: the ring driver picks its wire
            // framing off which sibling services exist (see `WearableDriver.servicesDiscovered`).
            driver.servicesDiscovered((peripheral.services ?? []).map(\.uuid))
            for service in peripheral.services ?? [] {
                if driver.serviceUUIDs.contains(service.uuid) {
                    var chars = driver.notifyUUIDs
                    chars.append(driver.writeUUID)
                    if let command = driver.commandUUID { chars.append(command) }
                    peripheral.discoverCharacteristics(chars, for: service)
                } else if service.uuid == driver.batteryServiceUUID {
                    if let batteryChar = driver.batteryCharUUID {
                        peripheral.discoverCharacteristics([batteryChar], for: service)
                    }
                } else if service.uuid == disServiceCBUUID {
                    // Standard Device Information Service — read firmware/software revision.
                    peripheral.discoverCharacteristics(Array(firmwareCharUUIDs), for: service)
                } else if service.uuid == otaServiceCBUUID {
                    // Firmware update (AB-OTA): bound now, subscribed only when an install asks.
                    peripheral.discoverCharacteristics([otaNotifyCBUUID, otaWriteCBUUID], for: service)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if service.uuid == otaServiceCBUUID {
                bindOtaService(service)
                return
            }
            guard let driver = activeDriver else { return }
            for characteristic in service.characteristics ?? [] {
                let uuid = characteristic.uuid
                // Write / command / notify are checked independently (not mutually exclusive) because a
                // device can expose one characteristic that is *both* the write target and a notify
                // source — an earlier protocol families' `be940001` receives command replies on the same char it's written
                // to. the ring/the ring keep these on distinct UUIDs, so their behavior is unchanged.
                if uuid == driver.writeUUID { writeChar = characteristic }
                if uuid == driver.commandUUID { commandChar = characteristic }
                if driver.notifyUUIDs.contains(uuid) {
                    notifyChars[uuid] = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if uuid == driver.batteryCharUUID {
                    batteryCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                } else if firmwareCharUUIDs.contains(uuid) {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if characteristic.uuid == otaNotifyCBUUID {
                otaNotifyEnabled = error == nil && characteristic.isNotifying
                return
            }
            guard let driver = activeDriver,
                  driver.notifyUUIDs.contains(characteristic.uuid),
                  characteristic.isNotifying else { return }
            subscribedNotifyUUIDs.insert(characteristic.uuid)
            // Fully connected once every channel the driver declared *required* is live — or, for a
            // driver that declares none, on the first one, which is the historical behaviour. (Multi-notify
            // devices fire this once per channel; guard against re-running startup.)
            let required = driver.requiredSubscriptionsBeforeConnected
            guard required.allSatisfy(subscribedNotifyUUIDs.contains) else { return }
            guard state != .connected else { return }
            reconnectAttempts = 0   // a link that reached `.connected` resets the backoff
            reconnectTask?.cancel()
            state = .connected
            cancelConnectTimeout()   // the attempt landed
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
            if let type = activeDeviceType {
                UserDefaults.standard.set(type.rawValue, forKey: Self.lastDeviceTypeKey)
            }
            if let modelID = activeWearableModelID {
                UserDefaults.standard.set(modelID, forKey: Self.lastWearableModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastWearableModelKey)
            }
            if let type = activeDeviceType {
                publish(.deviceIdentified(
                    deviceType: type,
                    wearableModelID: activeWearableModelID,
                    advertisedName: activeAdvertisedName,
                    capabilities: activeCapabilities,
                    peripheralIdentifier: peripheral.identifier.uuidString
                ))
            }
            publish(.deviceStateChanged(state: .connected, address: nil))
            noteActivity()
            startWatchdog()
            readBattery()
            // Order on the wire: the driver's own handshake, then the engine's startup sequence.
            // `onConnected` is what queues the latter, so the prepend has to happen first — after it, the
            // engine's commands are already in the queue and "head" would mean jumping them too.
            prependWrites(driver.immediatePostSubscriptionCommands())
            onConnected?()
            pumpWrites()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let value = characteristic.value else { return }
            noteActivity()
            if characteristic.uuid == otaNotifyCBUUID {
                handleOtaNotify(value)
                return
            }
            if characteristic.uuid == activeDriver?.batteryCharUUID {
                if let first = value.first {
                    batteryPercent = Int(first)
                    publish(.batteryLevel(percent: Int(first)))
                }
                return
            }
            // Firmware revision read from a standard DIS characteristic (0x2A26/0x2A28) — surface it.
            if firmwareCharUUIDs.contains(characteristic.uuid) {
                if let fw = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !fw.isEmpty {
                    publish(.firmwareVersion(fw))
                }
                return
            }
            guard let driver = activeDriver, driver.notifyUUIDs.contains(characteristic.uuid) else { return }
            // Capture before decoding: fragmented, malformed and multi-frame notifications each
            // occupy exactly one trace row. Decoded consumers use their own event channel.
            RingNotificationDelivery.receive(value,
                decode: { driver.ingest(value, from: characteristic.uuid) },
                publish: { publish($0) }, deliver: { deliverDecoded($0) })
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == peripheral.identifier, writeInFlight else { return }
            if error == nil { noteActivity() }
            let completion = inFlightCompletion
            inFlightCompletion = nil
            writeInFlight = false
            completion?(error.map { .failure($0) } ?? .success(()))
            pumpWrites()
        }
    }

    /// The connected link's signal strength (`readLinkRSSI`), for Find ring.
    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, self.peripheral?.identifier == peripheral.identifier else { return }
            signalListener?(RSSI.intValue)
        }
    }

    /// The without-response buffer drained — resume the queue. (Writes gated on
    /// `canSendWriteWithoutResponse` park here when the peripheral's buffer is full.)
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            pumpOtaWrites()
            pumpWrites()
        }
    }
}
