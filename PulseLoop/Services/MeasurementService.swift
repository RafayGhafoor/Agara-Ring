import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// The app-scoped measurement engine (consistency framework, block A; AGENTS.md Rule 10). It owns the one
/// running on-demand test, so a measurement survives the Measure sheet closing, a tab switch and — within
/// iOS limits — the app going to the background:
///
/// * **One test at a time** (the ring's rule: a second optical test kills the first). `start` refuses while
///   another spec is running.
/// * **Background:** the app declares `bluetooth-central`, so the ring's frames keep waking it; a
///   background-task assertion covers the gaps (every test is ≤ ~60 s, well inside it). Leaving the app while
///   a test runs posts the "Measuring…" notification; the result posts "Measurement ready" — **only while in
///   the background** (plan decision 2); in the foreground the sheet or the in-app pill shows it.
/// * **Resume:** the sheet is a view of this state, so reopening Measure shows the running (or finished)
///   measurement instead of starting a new one. A finished result stays until the user acknowledges it.
///
/// The reading itself is persisted by the coordinator's event subscriber as the ring's samples arrive, so storing
/// never depends on any screen being open. With no ring connected nothing is measured or saved (no demo readings).
/// Mirrors Android's `MeasurementService` (a foreground service there).
@MainActor
@Observable
final class MeasurementService {
    static let shared = MeasurementService()

    /// How long the sheet shows the "get ready" instruction before the ring is asked.
    nonisolated static let instructionHold: TimeInterval = 3

    /// The measurement lifecycle — the sheet's stages (`MeasurementSheet.Stage`).
    typealias Stage = MeasurementSheet.Stage

    // MARK: State (observed by the sheet and the in-app pill)

    /// The test being run or last finished; nil when idle.
    private(set) var spec: MeasurementSpec?
    private(set) var stage: Stage = .preparing
    private(set) var reading: MeasurementReading?
    /// When the ring was asked (the sheet's ring and clock derive from it).
    private(set) var measureStart: Date?
    /// Set on `.error`: what went wrong, phrased as what to do about it.
    private(set) var errorMessage: String?
    /// The unit a glucose result is shown in (the user's preference at start).
    private(set) var glucoseUnit: GlucoseUnit = .mgdl
    /// Bumped on every start, so a view can tell a fresh run from the one it was showing.
    private(set) var runID = 0

    /// A test is running (preparing, measuring or locking in).
    var isRunning: Bool { spec != nil && (stage == .preparing || stage == .searching || stage == .locking) }
    /// A result or error is waiting to be seen.
    var hasUnacknowledgedOutcome: Bool { spec != nil && (stage == .result || stage == .error) }
    /// Anything to show (running or finished).
    var isActive: Bool { spec != nil }

    /// "72 bpm" once a usable reading landed.
    var resultText: String? {
        guard stage == .result, let spec, let reading, spec.isUsable(reading) else { return nil }
        return spec.resultText(reading, glucoseUnit: glucoseUnit)
    }

    // MARK: Environment (the app attaches the real ring; tests inject fakes)

    struct Environment {
        var device: () -> MeasurementDevice?
        var isConnected: () -> Bool
        /// A ring has ever been paired — only used to word the failure ("Connect your ring" vs "reconnect").
        var hasPairedRing: () -> Bool
        /// Why a test failed, in the user's terms (not connected / charging / refused / not worn / generic).
        var failureMessage: (MeasurementSpec) -> String
        /// Keeps the app running while a test is in flight in the background; returns the "done" call.
        var beginBackgroundWork: () -> (() -> Void)
        var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    }

    var environment: Environment
    let notifications: AgaraNotifications

    private var task: Task<Void, Never>?
    private var endBackgroundWork: (() -> Void)?

    init(environment: Environment? = nil, notifications: AgaraNotifications? = nil) {
        self.environment = environment ?? Self.detachedEnvironment
        self.notifications = notifications ?? .shared
        self.notifications.onBackgroundChange { [weak self] background in self?.appBackgroundChanged(background) }
    }

    /// Before `attach`: no ring, nothing paired, a generic failure.
    private static let detachedEnvironment = Environment(
        device: { nil }, isConnected: { false }, hasPairedRing: { true },
        failureMessage: { $0.kind.failureMessage },
        beginBackgroundWork: { {} }
    )

    /// Shown when a measurement is started with no ring ever paired.
    static let connectRingMessage = "Connect your ring to take a measurement."

    /// Wire the live ring objects (from `AgaraApp`).
    func attach(client: RingBLEClient, coordinator: RingSyncCoordinator, context: ModelContext) {
        environment = Environment(
            device: { [weak coordinator] in coordinator },
            isConnected: { [weak client] in client?.state == .connected },
            hasPairedRing: { !MetricsService.fetchDevices(context).isEmpty },
            failureMessage: { [weak client, weak coordinator] spec in
                guard let client, client.state == .connected else {
                    return "Your ring isn't connected. Reconnect it and try again."
                }
                // The ring is on its charger, or said why it refused (busy, low battery, charging, not worn).
                if AgaraFeatureStore.shared.isOn(.chargingState), client.isCharging {
                    return MeasurementRefusal.chargingMessage
                }
                if let message = coordinator?.measureRefusal?.message(isCharging: client.isCharging) { return message }
                // The ring said it wasn't on the finger, so "keep still" advice would send the user the wrong way.
                if coordinator?.measureNotWorn == true { return spec.kind.notWornMessage }
                return spec.kind.failureMessage
            },
            beginBackgroundWork: {
                #if canImport(UIKit)
                var id = UIBackgroundTaskIdentifier.invalid
                id = UIApplication.shared.beginBackgroundTask(withName: "agara.measurement") {
                    UIApplication.shared.endBackgroundTask(id)
                    id = .invalid
                }
                return {
                    guard id != .invalid else { return }
                    UIApplication.shared.endBackgroundTask(id)
                    id = .invalid
                }
                #else
                return {}
                #endif
            }
        )
    }

    // MARK: Control

    /// Start `spec`. Refused (false) while another test runs — one optical test at a time. Starting the same
    /// spec again while it runs is a no-op that returns true (the sheet reopened). A finished outcome is
    /// replaced (that's "Try again").
    @discardableResult
    func start(_ spec: MeasurementSpec, glucoseUnit: GlucoseUnit = .mgdl,
               instructionHold: TimeInterval = MeasurementService.instructionHold) -> Bool {
        if isRunning { return self.spec?.id == spec.id }
        task?.cancel()
        self.spec = spec
        self.glucoseUnit = glucoseUnit
        stage = .preparing
        reading = nil
        errorMessage = nil
        measureStart = nil
        runID += 1
        let run = runID
        endBackgroundWork?()
        endBackgroundWork = environment.beginBackgroundWork()
        Task { await notifications.requestAuthorizationIfUndetermined() }
        task = Task { [weak self] in await self?.drive(spec, run: run, hold: instructionHold) }
        return true
    }

    /// Stop the running test (the ring's stream stops with the cancelled task) and forget it.
    func cancel() {
        task?.cancel()
        task = nil
        finishBackgroundWork()
        notifications.remove(ids: [AgaraNotification.measurementId])
        reset()
    }

    /// The user saw the outcome (Done / Close / swiped the result away): back to idle. No-op while running.
    func acknowledge() {
        guard !isRunning else { return }
        reset()
    }

    private func reset() {
        spec = nil
        stage = .preparing
        reading = nil
        errorMessage = nil
        measureStart = nil
    }

    // MARK: Driver

    private func drive(_ spec: MeasurementSpec, run: Int, hold: TimeInterval) async {
        await environment.sleep(hold)
        guard isCurrent(run) else { return }

        // No connected ring (never paired, or paired but not connected): nothing is measured and nothing is saved.
        // An invented reading would be indefensible (Apple 1.4.1 / 2.1), so the user is told to connect the ring.
        guard environment.isConnected(), let device = environment.device() else {
            fail(spec, message: environment.hasPairedRing() ? nil : Self.connectRingMessage)
            return
        }

        beginMeasuring()
        let result = await spec.run(device)
        guard isCurrent(run) else { return }
        await finish(spec, reading: result, run: run)
    }

    private func isCurrent(_ run: Int) -> Bool { !Task.isCancelled && run == runID && spec != nil }

    private func beginMeasuring() {
        stage = .searching
        measureStart = Date()
        if notifications.isAppInBackground, let spec {
            Task { await notifications.post(.measuring(spec.title)) }
        }
    }

    private func finish(_ spec: MeasurementSpec, reading: MeasurementReading?, run: Int) async {
        guard spec.isUsable(reading), let reading else { fail(spec); return }
        stage = .locking
        self.reading = reading
        // Let the ring visibly finish its fill before the number lands.
        await environment.sleep(0.5)
        guard isCurrent(run) else { return }
        stage = .result
        let text = spec.resultText(reading, glucoseUnit: glucoseUnit)
        trace("measurement \(spec.title): \(text). Saved.")
        await notifications.post(.measured(spec.title, result: text))
        finishBackgroundWork()
    }

    private func fail(_ spec: MeasurementSpec, message override: String? = nil) {
        let message = override ?? environment.failureMessage(spec)
        errorMessage = message
        stage = .error
        trace("measurement \(spec.title): \(message)")
        // Backgrounded: replace "Measuring…" with "Measurement didn't finish" (brand.yaml, same as Android);
        // in the foreground the sheet shows the error, so just clear it.
        if notifications.isAppInBackground {
            Task { await notifications.post(.measurementFailed(spec.title)) }
        } else {
            notifications.remove(ids: [AgaraNotification.measurementId])
        }
        finishBackgroundWork()
    }

    private func finishBackgroundWork() {
        endBackgroundWork?()
        endBackgroundWork = nil
    }

    /// Leaving the app mid-test posts "Measuring…"; coming back clears it (the sheet or pill shows progress).
    private func appBackgroundChanged(_ background: Bool) {
        guard isRunning, let spec else { return }
        if background {
            Task { await notifications.post(.measuring(spec.title)) }
        } else {
            notifications.remove(ids: [AgaraNotification.measurementId])
        }
    }

    /// E2E tooling: one line per outcome, so runs the UI test runner can't drive (the Mac build) leave evidence.
    private func trace(_ line: String) {
        #if DEBUG
        E2ETrace.log(line)
        #endif
    }
}
