import Foundation

/// Where Find ring's signal-strength readings come from (plan `find-ring-proximity.md`; Android has the same
/// interface). `start` begins polling every `AgaraConfig.Ring.findRssiPollMs` and hands each raw dBm reading to
/// `onRSSI` on the main actor; `stop` ends polling and any scan. `RingProximity` does the rest.
@MainActor
protocol RingSignalSource: AnyObject {
    func start(onRSSI: @escaping @MainActor (Int) -> Void)
    func stop()
}

enum RingSignalSources {
    static var pollInterval: Duration { .milliseconds(AgaraConfig.Ring.findRssiPollMs) }

    /// The emulator source when the app runs on the virtual ring (debug), otherwise CoreBluetooth.
    @MainActor
    static func make(client: RingBLEClient) -> RingSignalSource {
        #if DEBUG
        if VirtualRingLink.configuredPort != nil { return VirtualRingSignalSource() }
        #endif
        return BLERingSignalSource(client: client)
    }
}

/// CoreBluetooth: while connected, `CBPeripheral.readRSSI()` each tick (→ `peripheral(_:didReadRSSI:error:)`);
/// while the link is down, a FEE7-filtered scan for the known ring whose advertisements carry the RSSI. The client's
/// own reconnect logic keeps running, so walking back towards the ring reconnects it and the source switches back.
@MainActor
final class BLERingSignalSource: RingSignalSource {
    private let client: RingBLEClient
    private var task: Task<Void, Never>?

    init(client: RingBLEClient) { self.client = client }

    func start(onRSSI: @escaping @MainActor (Int) -> Void) {
        stop()
        client.setSignalListener { dbm in onRSSI(dbm) }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: RingSignalSources.pollInterval)
            }
        }
    }

    private func tick() {
        if client.readLinkRSSI() {
            client.stopProximityScan()
        } else {
            client.startProximityScan()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        client.stopProximityScan()
        client.setSignalListener(nil)
    }
}

#if DEBUG
/// The ring emulator over the debug socket: a plain `RSSI` line each tick, answered `RSSI <dBm>`
/// (`ring-emulator --rssi -63` or `--rssi-walk far-to-near:30`). No answer while the link is down.
@MainActor
final class VirtualRingSignalSource: RingSignalSource {
    private var task: Task<Void, Never>?

    func start(onRSSI: @escaping @MainActor (Int) -> Void) {
        stop()
        VirtualRingLink.shared.onRSSI = { dbm in onRSSI(dbm) }
        task = Task { @MainActor in
            while !Task.isCancelled {
                VirtualRingLink.shared.requestRSSI()
                try? await Task.sleep(for: RingSignalSources.pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        VirtualRingLink.shared.onRSSI = nil
    }
}
#endif
