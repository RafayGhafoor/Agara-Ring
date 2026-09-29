import Foundation

/// The cap-pressure ladder (storage-compression.md §4): when usage is over `storage_cap_target_percent` of the limit,
/// apply the rungs in order of bytes won per information lost and stop the moment usage is at or under the target.
///
/// What it never does: delete daily summaries, sleep, workouts, coach conversations and other user content, or
/// **unsynced** data (every block is unsynced while the cloud is off, so in 1.0 nothing is ever downsampled), and it
/// never blocks ring sync — it only runs inside the maintenance job. When every rung is spent and usage is still over
/// the target, it stops with `.protectedDataRemains` and the screen explains why ("kept because it is not backed up / is
/// your own content. Raise the limit or export").
nonisolated enum StorageLadder {
    /// In ladder order. Compaction (§4 rung 4) is lossless and runs on every pass, before the ladder, so it is not a rung.
    enum Rung: String, CaseIterable, Equatable {
        /// Shrink the raw-packet window to nothing (pinned identity frames survive 7 days).
        case shrinkRawPackets
        /// Audit tables (`derived_updates`, `wearable_logs`) 7 → 1 day.
        case trimAudit
        /// Disposable caches (food-product lookups), least recently used first.
        case clearCaches
        /// Downsample old blocks of dense streams (live HR, workout samples, GPS) to 1-minute then hourly — **synced blocks
        /// only**. AGB v1 has no aggregate-block key yet, so this rung is decided but not executed (see the report).
        case downsampleDense
    }

    enum StopReason: Equatable {
        case withinTarget
        /// Every applicable rung was applied and usage is still over the target; the remainder is protected data.
        case protectedDataRemains
    }

    /// The knobs the rungs turn, so a decision can be made without touching storage.
    struct State: Equatable {
        var rawWindowHours: Int
        var auditDays: Int
        var cachesCleared = false
        /// Bytes of blocks that were accepted by the server (`synced_hash == content_hash`) — the only downsample candidates.
        var syncedDenseBytes: Int64 = 0
    }

    struct Outcome: Equatable {
        var applied: [Rung]
        var stop: StopReason
        var usedAfter: Int64
    }

    /// Whether `rung` can still win anything given `state`.
    static func isApplicable(_ rung: Rung, state: State) -> Bool {
        switch rung {
        case .shrinkRawPackets: return state.rawWindowHours > 0
        case .trimAudit: return state.auditDays > 1
        case .clearCaches: return !state.cachesCleared
        case .downsampleDense: return state.syncedDenseBytes > 0
        }
    }

    static func update(_ state: inout State, after rung: Rung) {
        switch rung {
        case .shrinkRawPackets: state.rawWindowHours = 0
        case .trimAudit: state.auditDays = 1
        case .clearCaches: state.cachesCleared = true
        case .downsampleDense: state.syncedDenseBytes = 0
        }
    }

    /// Run the ladder. `used` re-measures after every rung; `apply` executes it. `capBytes == nil` (no limit) applies nothing.
    static func run(used: () -> Int64, capBytes: Int64?, targetPercent: Int, state: inout State,
                    apply: (Rung) -> Void) -> Outcome {
        guard let capBytes else { return Outcome(applied: [], stop: .withinTarget, usedAfter: used()) }
        let target = capBytes * Int64(targetPercent) / 100
        var applied: [Rung] = []
        var current = used()
        for rung in Rung.allCases {
            if current <= target { return Outcome(applied: applied, stop: .withinTarget, usedAfter: current) }
            guard isApplicable(rung, state: state) else { continue }
            apply(rung)
            update(&state, after: rung)
            applied.append(rung)
            current = used()
        }
        return Outcome(applied: applied, stop: current <= target ? .withinTarget : .protectedDataRemains, usedAfter: current)
    }

    // MARK: Banner

    /// What the screen shows about limit and disk. Pure: bytes in, verdict out.
    enum Banner: Equatable {
        case none
        /// Usage is over the limit and the ladder cannot help; `protectedBytes` is what it may not touch.
        case overLimit(usedBytes: Int64, capBytes: Int64)
        /// Free space below `storage_low_disk_free_mb`: raw capture stops, no full VACUUM.
        case lowDisk(freeBytes: Int64)
        /// Below `storage_critical_disk_free_mb`: caches and image writes pause, import is refused.
        case criticalDisk(freeBytes: Int64)
    }

    static func banner(usedBytes: Int64, capBytes: Int64?, freeDiskBytes: Int64) -> Banner {
        let critical = Int64(AgaraConfig.Storage.criticalDiskFreeMb) * 1_048_576
        let low = Int64(AgaraConfig.Storage.lowDiskFreeMb) * 1_048_576
        if freeDiskBytes < critical { return .criticalDisk(freeBytes: freeDiskBytes) }
        if freeDiskBytes < low { return .lowDisk(freeBytes: freeDiskBytes) }
        if let capBytes, usedBytes > capBytes { return .overLimit(usedBytes: usedBytes, capBytes: capBytes) }
        return .none
    }

    /// Optimize now is off on low disk, and on battery below 20 % while not charging (§4 item 6).
    static func canOptimize(freeDiskBytes: Int64, batteryLevel: Float, charging: Bool) -> Bool {
        if freeDiskBytes < Int64(AgaraConfig.Storage.lowDiskFreeMb) * 1_048_576 { return false }
        if batteryLevel >= 0, batteryLevel < 0.20, !charging { return false }
        return true
    }
}
