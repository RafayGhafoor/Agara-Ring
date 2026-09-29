import Foundation
import SQLite3

/// What the Storage screen shows: how many bytes each class of data occupies and how much of the database file is free
/// space that could be given back. Sizes are computed from SQLite's `dbstat` (per table and per index page bytes), read
/// through a separate read-only connection, so the screen never touches SwiftData's own connection. Where `dbstat`
/// isn't compiled in, the class sizes are estimated from row counts and marked "≈".
nonisolated enum StorageClass: String, CaseIterable, Identifiable {
    case healthReadings, dailySummaries, workouts, coach, diagnostics, caches, other
    var id: String { rawValue }

    /// Native labels (ordinary UI copy stays per app).
    var title: String {
        switch self {
        case .healthReadings: return "Health readings (detailed)"
        case .dailySummaries: return "Daily summaries, sleep and profile"
        case .workouts: return "Workouts & routes"
        case .coach: return "Coach conversations"
        case .diagnostics: return "Diagnostics (raw data and logs)"
        case .caches: return "Caches (food products)"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .healthReadings: return "heart.text.square"
        case .dailySummaries: return "calendar"
        case .workouts: return "figure.run"
        case .coach: return "bubble.left.and.text.bubble.right"
        case .diagnostics: return "stethoscope"
        case .caches: return "shippingbox"
        case .other: return "square.stack.3d.up"
        }
    }

    /// Which class a SwiftData entity (uppercased Core Data name) belongs to.
    static let byEntity: [String: StorageClass] = {
        var m: [String: StorageClass] = [:]
        for e in ["MEASUREMENT", "MEASUREMENTBLOCK", "BLOCKSYNC", "MEASUREMENTDELETION", "BATTERYSAMPLE"] { m[e] = .healthReadings }
        for e in ["ACTIVITYDAILY", "ACTIVITYBUCKETSAMPLE", "SLEEPSESSION", "SLEEPSTAGEBLOCK", "MEALENTRY", "USERPROFILE", "USERGOAL",
                  "DEVICE", "DEVICEMEASUREMENTCONFIG"] { m[e] = .dailySummaries }
        for e in ["ACTIVITYSESSION", "ACTIVITYSAMPLE", "ACTIVITYGPSPOINT", "ACTIVITYEVENT", "ACTIVITYSENSORPOLLEVENT"] { m[e] = .workouts }
        for e in ["COACHCONVERSATION", "COACHMESSAGE", "COACHMEMORY", "COACHTOOLCALL", "COACHNOTIFICATIONRECORD", "COACHSUMMARY"] { m[e] = .coach }
        for e in ["RAWPACKETROW", "RAWPACKETRECORD", "DERIVEDUPDATEROW", "WEARABLELOG", "ACHANGE", "ATRANSACTION", "TRANSACTION", "CHANGE"] { m[e] = .diagnostics }
        m["CACHEDFOODPRODUCT"] = .caches
        return m
    }()

    /// Class for a `dbstat` object name: tables are `Z<ENTITY>`, indexes `Z_<Entity>_…`, history `ACHANGE…`/`ATRANSACTION…`.
    static func classify(objectName name: String) -> StorageClass {
        let upper = name.uppercased()
        if upper.hasPrefix("ACHANGE") { return .diagnostics }
        if upper.hasPrefix("ATRANSACTION") { return .diagnostics }
        if upper.hasPrefix("Z_") {
            let rest = upper.dropFirst(2)
            let entity = rest.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return byEntity[entity] ?? .other
        }
        if upper.hasPrefix("Z") { return byEntity[String(upper.dropFirst())] ?? .other }
        return .other
    }
}

nonisolated struct StorageUsage: Equatable {
    var bytes: [StorageClass: Int64] = [:]
    /// Free pages inside the database file that `incremental_vacuum` can return.
    var reclaimableBytes: Int64 = 0
    /// Size of the store files (database + write-ahead log + shared memory) as the filesystem reports them.
    var fileBytes: Int64 = 0
    var freeDiskBytes: Int64 = 0
    /// False when sizes were estimated because `dbstat` isn't available.
    var exact = true

    /// Bytes the storage limit is measured against: every class, not the reclaimable slack.
    var usedBytes: Int64 { bytes.values.reduce(0, +) }
    func bytes(_ c: StorageClass) -> Int64 { bytes[c] ?? 0 }
}

nonisolated enum StorageMeter {
    /// Sum of the sizes of a directory's files (coach attachments).
    static func directoryBytes(_ url: URL?) -> Int64 {
        guard let url, let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Free space the OS will give the app for important data (`volumeAvailableCapacityForImportantUsage`).
    static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return v }
        return Int64((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? Int64) ?? 0)
    }

    /// Measure the store at `storeURL` (plus an attachments directory counted as coach data). `fallbackRows` maps a class to
    /// an estimated byte count and is used only when `dbstat` is unavailable.
    static func measure(storeURL: URL, attachmentsURL: URL? = nil, fallbackEstimate: (() -> [StorageClass: Int64])? = nil) -> StorageUsage {
        var usage = StorageUsage()
        usage.freeDiskBytes = freeDiskBytes()
        usage.fileBytes = ["", "-wal", "-shm"].reduce(0) { $0 + fileSize(URL(fileURLWithPath: storeURL.path + $1)) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            usage.exact = false
            usage.bytes = fallbackEstimate?() ?? [:]
            return usage
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        let pageSize = scalar(db, "PRAGMA page_size") ?? 4096
        usage.reclaimableBytes = (scalar(db, "PRAGMA freelist_count") ?? 0) * pageSize
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cName = sqlite3_column_text(stmt, 0) else { continue }
                let c = StorageClass.classify(objectName: String(cString: cName))
                usage.bytes[c, default: 0] += sqlite3_column_int64(stmt, 1)
            }
        } else {
            usage.exact = false
            usage.bytes = fallbackEstimate?() ?? [:]
        }
        sqlite3_finalize(stmt)
        usage.bytes[.coach, default: 0] += directoryBytes(attachmentsURL)
        return usage
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Give free pages back to the filesystem with `PRAGMA incremental_vacuum` (never a full VACUUM, which needs up to twice
    /// the database in temp space). Returns bytes reclaimed; 0 when there is less than `storage_vacuum_min_reclaim_mb` to gain,
    /// when the disk is low, or when the database is busy.
    @discardableResult
    static func reclaim(storeURL: URL) -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { sqlite3_close(db); return 0 }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let pageSize = scalar(db, "PRAGMA page_size") ?? 4096
        let free = (scalar(db, "PRAGMA freelist_count") ?? 0) * pageSize
        guard free >= Int64(AgaraConfig.Storage.vacuumMinReclaimMb) * 1_048_576, (scalar(db, "PRAGMA auto_vacuum") ?? 0) == 2 else { return 0 }
        guard sqlite3_exec(db, "PRAGMA incremental_vacuum", nil, nil, nil) == SQLITE_OK else { return 0 }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE)", nil, nil, nil)
        let after = (scalar(db, "PRAGMA freelist_count") ?? 0) * pageSize
        return max(0, free - after)
    }
}

/// The disk-space verdict the rest of the app consults (raw capture, caches, import). Refreshed at launch and by every
/// maintenance pass; reading it never touches the disk.
nonisolated enum StorageGuard {
    nonisolated(unsafe) private static var cachedFree: Int64 = .max
    private static let lock = NSLock()

    /// Where free space comes from (tests substitute a fixed value).
    nonisolated(unsafe) static var probe: () -> Int64 = { StorageMeter.freeDiskBytes() }

    static func refresh() { let f = probe(); lock.lock(); cachedFree = f; lock.unlock() }
    static func set(freeBytes: Int64) { lock.lock(); cachedFree = freeBytes; lock.unlock() }
    static var freeBytes: Int64 { lock.lock(); defer { lock.unlock() }; return cachedFree }

    /// Below `storage_low_disk_free_mb`: stop raw capture, skip anything that needs temp space.
    static var isLowDisk: Bool { freeBytes < Int64(AgaraConfig.Storage.lowDiskFreeMb) * 1_048_576 }
    /// Below `storage_critical_disk_free_mb`: also pause caches and image writes, and refuse an import.
    static var isCriticalDisk: Bool { freeBytes < Int64(AgaraConfig.Storage.criticalDiskFreeMb) * 1_048_576 }
}
