import Foundation
import Observation

// Ring firmware update, stage 4 (docs/process/plans/firmware-update.md): install the verified download on the
// connected Agara ring over AB-OTA (`AbOta` / `AbOtaInstaller`). Behind `firmware_install`, which ships on for
// every build since 1.1 (the debug-build restriction was removed with the flag flip).
// Same gates, hold, flow and copy as Android `FirmwareInstallGates` / `FirmwareInstallController`.

/// Everything that must hold before the first block goes to the ring (plan "Gates"). Pure, so each gate is
/// unit-tested; `FirmwareInstallController` fills it from live app state and re-checks it right before the
/// transfer starts.
///
/// `otaType` is byte 16 of the ring's `a7` capability package 3 (nil until that package has arrived); the
/// Agara ring reports 3, the only type this installer speaks.
struct FirmwareInstallInputs: Equatable {
    var flagOn: Bool
    var fileVerified: Bool
    var connected: Bool
    var otaType: Int?
    var otaServicePresent: Bool
    var batteryPercent: Int?
    var minBatteryPercent: Int
    var syncing: Bool
    var measuring: Bool
}

enum FirmwareInstallGate: CaseIterable, Equatable {
    case flagOff, noVerifiedFile, notConnected, unsupportedRing, noUpdateChannel, batteryUnknown, lowBattery,
         syncing, measuring

    func text(minBattery: Int) -> String {
        switch self {
        case .flagOff: return "Installing firmware is turned off in this build."
        case .noVerifiedFile: return "Download the update first."
        case .notConnected: return "Connect the ring first."
        case .unsupportedRing: return "This ring can't be updated from the app."
        case .noUpdateChannel: return "The ring's update channel isn't available. Reconnect the ring and try again."
        case .batteryUnknown: return "Waiting for the ring's battery level…"
        case .lowBattery: return "Charge the ring to at least \(minBattery) % first."
        case .syncing: return "Wait for the ring to finish syncing."
        case .measuring: return "Wait for the measurement to finish."
        }
    }
}

enum FirmwareInstallGates {
    /// Required OTA type from the capability packet (the update protocol this app speaks).
    static let supportedOtaType = 3

    /// Every gate that fails, in the order the screen should explain them; empty means go.
    static func evaluate(_ i: FirmwareInstallInputs) -> [FirmwareInstallGate] {
        var gates: [FirmwareInstallGate] = []
        if !i.flagOn { gates.append(.flagOff) }
        if !i.fileVerified { gates.append(.noVerifiedFile) }
        guard i.connected else {
            gates.append(.notConnected)
            return gates          // the rest describe a connected ring
        }
        if i.otaType != supportedOtaType { gates.append(.unsupportedRing) }
        if !i.otaServicePresent { gates.append(.noUpdateChannel) }
        if let battery = i.batteryPercent {
            if battery < i.minBatteryPercent { gates.append(.lowBattery) }
        } else {
            gates.append(.batteryUnknown)
        }
        if i.syncing { gates.append(.syncing) }
        if i.measuring { gates.append(.measuring) }
        return gates
    }
}

/// `OtaLink` over the app's `RingBLEClient`: `F031`/`F032` through the client's firmware-update channel
/// (Bluetooth, or the debug socket to ring-emulator), link drops from the client, and the ring's firmware from
/// each connection's `a1` reply.
@MainActor
final class RingOtaLink: OtaLink {
    nonisolated deinit {}

    private let client: RingBLEClient
    static let reconnectPoll: TimeInterval = 2
    static let handshakeWait: TimeInterval = 8
    static let settle: TimeInterval = 0.5

    init(client: RingBLEClient) { self.client = client }

    func setListener(_ listener: ((OtaLinkEvent) -> Void)?) { client.setOtaListener(listener) }

    var isConnected: Bool { client.state == .connected }

    func openChannel() async -> Int? { await client.openOtaChannel() }

    func write(_ frame: Data) { client.writeOta(frame) }

    func reconnect(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected {
            guard Date() < deadline else { return false }
            client.reconnectForFirmwareUpdate()
            _ = await poll(until: min(deadline, Date().addingTimeInterval(Self.reconnectPoll))) { self.isConnected }
        }
        // Let the session handshake (`a1`) finish before update frames go out, as on a first connect.
        _ = await poll(until: min(deadline, Date().addingTimeInterval(Self.handshakeWait))) {
            self.client.firmwareSinceConnect != nil
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1_000_000_000))
        return isConnected
    }

    func awaitDisconnect(timeout: TimeInterval) async -> Bool {
        await poll(until: Date().addingTimeInterval(timeout)) { !self.isConnected }
    }

    func awaitFirmwareVersion(timeout: TimeInterval) async -> String? {
        _ = await poll(until: Date().addingTimeInterval(timeout)) { self.client.firmwareSinceConnect != nil }
        return client.firmwareSinceConnect
    }

    /// True once `condition` holds, checking every 50 ms until `deadline`.
    private func poll(until deadline: Date, _ condition: () -> Bool) async -> Bool {
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}

/// Stage 4 of plan firmware-update: installs the verified download on the connected Agara ring. Owns the gates,
/// the `FirmwareUpdateHold` (sync engines go quiet) and the `AbOtaInstaller` run; the UI only reads `state` and
/// calls `start` / `cancel` / `dismiss`. The run is not tied to any view, so leaving a screen doesn't stop a
/// transfer. Debug builds only, behind `firmware_install`.
@MainActor
@Observable
final class FirmwareInstallController {
    nonisolated deinit {}

    static let shared = FirmwareInstallController()

    /// Debug launch argument: download the offered release if needed and start the install (without the
    /// confirm dialog) as soon as every gate passes — the headless simulator can't tap.
    static let autoInstallKey = "firmwareAutoInstall"

    private(set) var state: InstallState = .idle

    @ObservationIgnored private weak var client: RingBLEClient?
    @ObservationIgnored private weak var coordinator: RingSyncCoordinator?
    @ObservationIgnored private let checker: FirmwareUpdateChecker
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var installer: AbOtaInstaller?
    @ObservationIgnored private var autoInstallTask: Task<Void, Never>?

    init(checker: FirmwareUpdateChecker? = nil) {
        self.checker = checker ?? .shared
    }

    /// Wire the live ring client and coordinator (once, at launch).
    func attach(client: RingBLEClient, coordinator: RingSyncCoordinator) {
        self.client = client
        self.coordinator = coordinator
    }

    var minBattery: Int { AgaraConfig.Ring.firmwareMinBatteryPercent }

    /// The flag as the UI sees it.
    var enabled: Bool { AgaraFeatureStore.isOn(.firmwareInstall) }

    /// The gates right now, from live app state. `fileVerified` nil → "a download is Ready".
    func inputs(fileVerified: Bool? = nil) -> FirmwareInstallInputs {
        let ready: Bool = { if case .ready = checker.status { return true }; return false }()
        return FirmwareInstallInputs(
            flagOn: AgaraFeatureStore.isOn(.firmwareInstall),
            fileVerified: fileVerified ?? ready,
            connected: client?.state == .connected,
            otaType: client?.ringCapabilities?.otaType,
            otaServicePresent: client?.otaServiceAvailable ?? false,
            batteryPercent: client?.ringBatteryPercent ?? client?.batteryPercent,
            minBatteryPercent: minBattery,
            syncing: coordinator?.historySyncing ?? false,
            measuring: coordinator?.measurementActive ?? false
        )
    }

    func gates() -> [FirmwareInstallGate] { FirmwareInstallGates.evaluate(inputs()) }

    /// Start installing the Ready download. False when one is already running or nothing is Ready.
    @discardableResult
    func start() -> Bool {
        guard task == nil else { return false }
        guard case let .ready(release) = checker.status, let url = checker.storedFileURL(), let client else {
            state = .failed(.blocked, detail: FirmwareInstallGate.noVerifiedFile.text(minBattery: minBattery))
            return false
        }
        state = .preparing(resuming: false)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            // Re-verify the file itself (size + MD5), not just the status the checker remembers.
            let image = (try? Data(contentsOf: url)).flatMap { FirmwareUpdateLogic.verify($0, against: release) ? $0 : nil }
            let blocked = FirmwareInstallGates.evaluate(self.inputs(fileVerified: image != nil))
            guard let image, blocked.isEmpty else {
                self.state = .failed(.blocked, detail: blocked.first?.text(minBattery: self.minBattery))
                return
            }
            FirmwareUpdateHold.active = true
            client.syncEngine?.enterFirmwareHold()
            let link = RingOtaLink(client: client)
            let run = AbOtaInstaller(
                link: link,
                log: { NSLog("[FirmwareInstall] %@", $0) },
                // Right before the first block: every gate again (the hold is set, so a sync can't start now).
                preflight: { [weak self] in
                    guard let self else { return nil }
                    return FirmwareInstallGates.evaluate(self.inputs(fileVerified: true)).first?.text(minBattery: self.minBattery)
                }
            )
            self.installer = run
            NSLog("[FirmwareInstall] install %@: %d B", release.version, image.count)
            let result = await run.install(image: image, targetVersion: release.version) { [weak self] s in
                if case .failed(.cancelled, _) = s { self?.state = .idle } else { self?.state = s }
            }
            NSLog("[FirmwareInstall] install ended: %@", String(describing: result))
            self.installer = nil
            FirmwareUpdateHold.active = false
            client.syncEngine?.resumeAfterFirmwareHold()
        }
        return true
    }

    /// Cancel is offered only while preparing a fresh install, before the first block goes out.
    var cancellable: Bool {
        guard case .preparing(resuming: false) = state else { return false }
        return installer?.started != true
    }

    /// Cancel — only before the first block is sent. Returns whether it was. The installer stops at its next
    /// checkpoint (it has written nothing to flash yet) and the run releases the sync hold as it ends.
    @discardableResult
    func cancel() -> Bool {
        guard let run = installer, state.busy, run.cancel() else { return false }
        state = .idle
        return true
    }

    /// Close a finished install's screen (success or failure).
    func dismiss() {
        if !state.busy { state = .idle }
    }

    // MARK: Debug: headless install

    /// `-firmwareAutoInstall YES` (debug): download the offered release, then start as soon as the gates
    /// pass — at most once per launch, for up to 10 minutes. The simulator can't tap the sheet's buttons.
    func startAutoInstallIfRequested(defaults: UserDefaults = .standard) {
        #if DEBUG
        guard defaults.bool(forKey: Self.autoInstallKey), autoInstallTask == nil else { return }
        NSLog("[FirmwareInstall] auto-install requested; waiting for a verified download and open gates")
        autoInstallTask = Task { @MainActor [weak self] in
            var lastReport = ""
            var lastDownload = Date.distantPast
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                switch self.checker.status {
                case .available, .error:
                    if self.checker.latestRelease != nil, AgaraFeatureStore.isOn(.firmwareDownload),
                       Date().timeIntervalSince(lastDownload) > 15 {
                        lastDownload = Date()
                        NSLog("[FirmwareInstall] auto-install: downloading %@", self.checker.latestRelease?.version ?? "?")
                        await self.checker.download()
                    }
                    continue
                case .ready:
                    let gates = self.gates()
                    if gates.isEmpty {
                        NSLog("[FirmwareInstall] auto-install: gates open — starting")
                        self.start()
                        return
                    }
                    let report = gates.map { $0.text(minBattery: self.minBattery) }.joined(separator: " | ")
                    if report != lastReport {
                        lastReport = report
                        NSLog("[FirmwareInstall] auto-install: blocked — %@", report)
                    }
                default:
                    continue
                }
            }
        }
        #endif
    }
}
