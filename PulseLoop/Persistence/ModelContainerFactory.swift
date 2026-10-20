import Foundation
import SwiftData
import OSLog

enum ModelContainerFactory {
    static let schema = Schema([
            Device.self,
            ActivityDaily.self,
            Measurement.self,
            BatterySample.self,
            SleepSession.self,
            SleepStageBlock.self,
            RawPacketRow.self,          // legacy (hex text); converted into RawPacketRecord, removed one release later
            RawPacketRecord.self,
            MeasurementBlock.self,
            BlockSync.self,
            DerivedUpdateRow.self,
            UserProfile.self,
            UserGoal.self,
            DeviceMeasurementConfig.self,
            ActivitySession.self,
            ActivitySample.self,
            ActivityBucketSample.self,
            MeasurementDeletion.self,
            ActivityGpsPoint.self,
            ActivityEvent.self,
            ActivitySensorPollEvent.self,
            CoachConversation.self,
            CoachMessage.self,
            CoachMemory.self,
            CoachToolCall.self,
            CoachNotificationRecord.self,
            // Nudges keep nothing in SwiftData: the ledger, the preferences and the one-day goal override are a few
            // hundred bytes of day-keyed bookkeeping in UserDefaults (NudgeLedgerStore / NudgePreferencesStore /
            // DailyGoalOverrideStore), so no schema migration rides on a notification feature.
            CoachSummary.self,
            WearableLog.self,
            MealEntry.self,
            CachedFoodProduct.self
        ])

    /// - Parameter url: store file; nil = SwiftData's default (`Application Support/default.store`).
    static func make(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let config: ModelConfiguration
        if let url, !inMemory {
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Open the on-disk store; if it can't be opened (corrupt file, a migration SwiftData can't perform),
    /// move it and its `-wal`/`-shm` side files aside as `<name>.broken-<timestamp>` and start a fresh
    /// store instead of crashing on every launch. The moved files are kept so the data can be recovered
    /// (Files app / a later import). Only if even a fresh store fails does it fall back to memory.
    /// The caller shows `StoreRecoveryNotice` once.
    static func makeRecovering(url: URL? = nil, now: Date = AppClock.now) -> (container: ModelContainer, movedAside: URL?) {
        do {
            return (try make(url: url), nil)
        } catch {
            let log = Logger(subsystem: "com.agara.ring", category: "Store")
            log.error("store failed to open — moving it aside: \(String(describing: error), privacy: .public)")
            let storeURL = url ?? ModelConfiguration(schema: schema).url
            let moved = moveAside(storeURL, now: now)
            if let container = try? make(url: url) {
                StoreRecoveryNotice.record(movedTo: moved)
                return (container, moved)
            }
            log.error("fresh store failed too — running in memory")
            StoreRecoveryNotice.record(movedTo: moved)
            // In-memory creation only fails on a schema bug, which every test run would catch first.
            // swiftlint:disable:next force_try
            return (try! make(inMemory: true), moved)
        }
    }

    /// Move `store` and its SQLite side files to `<store>.broken-<yyyyMMdd-HHmmss>[-wal|-shm]`.
    /// Returns the moved main file's URL (nil when there was nothing to move).
    @discardableResult
    static func moveAside(_ store: URL, now: Date = AppClock.now) -> URL? {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var movedMain: URL?
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: store.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: store.path + ".broken-" + stamp + suffix)
            try? fm.removeItem(at: target)
            do {
                try fm.moveItem(at: source, to: target)
                if suffix.isEmpty { movedMain = target }
            } catch {
                try? fm.removeItem(at: source)   // can't keep it: at least let a fresh store open
            }
        }
        return movedMain
    }
}

/// One-shot notice that the store was reset at launch (`ModelContainerFactory.makeRecovering`).
enum StoreRecoveryNotice {
    static let key = "storeRecovery.pendingNotice"

    static func record(movedTo url: URL?, defaults: UserDefaults = .standard) {
        defaults.set(url?.lastPathComponent ?? "", forKey: key)
    }

    /// The pending notice text, cleared once read.
    static func consume(defaults: UserDefaults = .standard) -> String? {
        guard let name = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        let kept = name.isEmpty ? "" : " The old data file was kept as \(name) and can be sent to support for recovery."
        return "Your health data couldn't be opened, so the app started with a fresh store.\(kept) "
            + "Your ring will re-sync its recent history when it connects."
    }
}
