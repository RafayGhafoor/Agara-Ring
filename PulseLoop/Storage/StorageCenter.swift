import Foundation
import SwiftData
import SwiftUI
import OSLog

/// Runs the maintenance job on a background `ModelContext` (never the main one), so a compaction pass can't stall the UI
/// or a ring sync: each series-day is its own short transaction.
@ModelActor
actor StorageMaintenanceActor {
    func run(now: Date, options: StorageMaintenance.Options, storeURL: URL?, attachmentsURL: URL?,
             progress: @escaping @Sendable (Double, String) -> Void) -> MaintenanceReport {
        let measure: (() -> Int64)? = storeURL.map { url in { StorageMeter.measure(storeURL: url, attachmentsURL: attachmentsURL).usedBytes } }
        let report = StorageMaintenance.run(now: now, context: modelContext, options: options, measure: measure,
                                            isCancelled: { Task.isCancelled }, progress: progress)
        // Give free pages back — incremental only, and never on a low disk (`storage_low_disk_free_mb`).
        StorageGuard.refresh()
        if let storeURL, !StorageGuard.isLowDisk { StorageMeter.reclaim(storeURL: storeURL) }
        return report
    }
}

/// App-level owner of storage state: usage for the screen, the daily maintenance schedule and "Optimize now".
@MainActor
@Observable
final class StorageCenter {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = StorageCenter()
    static let lastRunKey = "agara.storage.lastMaintenance"
    private let log = Logger(subsystem: "com.agara.ring", category: "storage")

    private(set) var usage: StorageUsage?
    private(set) var isRunning = false
    private(set) var lastReport: MaintenanceReport?
    private var container: ModelContainer?
    private var runTask: Task<Void, Never>?
    var defaults: UserDefaults = .standard
    var prefs = StoragePrefs()

    var lastRunAt: Date? { defaults.object(forKey: Self.lastRunKey) as? Date }

    var storeURL: URL? { container?.configurations.first?.url }
    var attachmentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("coach_attachments", isDirectory: true)
    }

    var banner: StorageLadder.Banner {
        guard let usage else { return .none }
        return StorageLadder.banner(usedBytes: usage.usedBytes, capBytes: prefs.capBytes, freeDiskBytes: usage.freeDiskBytes)
    }

    func attach(container: ModelContainer) { self.container = container }

    // MARK: Usage

    func refreshUsage() async {
        guard let url = storeURL else { return }
        let attachments = attachmentsURL
        let measured = await Task.detached(priority: .utility) { StorageMeter.measure(storeURL: url, attachmentsURL: attachments) }.value
        usage = measured
        StorageGuard.set(freeBytes: measured.freeDiskBytes)
    }

    // MARK: Runs

    /// The routine pass: at most once per `storage_maintenance_interval_hours`, gated by the `storage_compaction` flag.
    func runIfDue(now: Date = Date()) {
        guard !isRunning, container != nil else { return }
        // Never compete with a ring history pass; the next foreground picks it up.
        guard !SyncProgress.shared.isSyncing else { return }
        if let last = lastRunAt, now.timeIntervalSince(last) < Double(AgaraConfig.Storage.maintenanceIntervalHours) * 3600 { return }
        start(now: now, optimize: false)
    }

    /// "Optimize now": compaction, prune, the cap ladder and reclaim, with progress on the one sync-progress model.
    /// Not offered on a low disk, or on battery below 20 % while not charging.
    var canOptimize: Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return !isRunning && StorageLadder.canOptimize(freeDiskBytes: usage?.freeDiskBytes ?? StorageMeter.freeDiskBytes(),
                                                       batteryLevel: UIDevice.current.batteryLevel, charging: charging)
    }

    func optimizeNow() {
        guard canOptimize else { return }
        start(now: Date(), optimize: true)
    }

    /// Await the current pass (tests, and the screen refreshing after it).
    func waitForIdle() async { await runTask?.value }

    private func start(now: Date, optimize: Bool) {
        guard let container, !isRunning else { return }
        isRunning = true
        if optimize { SyncProgress.shared.beginJob(title: "Optimizing storage") }
        var options = StorageMaintenance.Options()
        options.compact = AgaraFeatureStore.isOn(.storageCompaction)
        options.runLadder = optimize || (usage.map { $0.usedBytes > Int64(prefs.capMb) * 1_048_576 } ?? false) && prefs.capMb > 0
        options.capBytes = prefs.capBytes
        let url = storeURL, attachments = attachmentsURL
        runTask = Task { [weak self] in
            let report = await Task.detached(priority: .utility) { () -> MaintenanceReport in
                let actor = StorageMaintenanceActor(modelContainer: container)
                return await actor.run(now: now, options: options, storeURL: url, attachmentsURL: attachments) { fraction, detail in
                    Task { @MainActor in if optimize { SyncProgress.shared.updateJob(fraction: fraction, detail: detail) } }
                }
            }.value
            guard let self else { return }
            self.defaults.set(now, forKey: Self.lastRunKey)
            self.lastReport = report
            self.isRunning = false
            SyncProgress.shared.endJob()
            self.log.info("maintenance: \(report.blocksCompacted) blocks, \(report.rowsCompacted) rows, \(report.snapshotsWritten) snapshots, ladder \(report.ladder.map(\.rawValue).joined(separator: ","))")
            await self.refreshUsage()
            if report.blocksCompacted > 0 { AgaraDataChange.shared.notify() }
        }
    }
}
