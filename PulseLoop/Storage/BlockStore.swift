import Foundation
import SwiftData
import OSLog

// The block store: compaction (writer), open-day snapshots, the ledger, and the read helpers behind
// `MeasurementSeries`. Rules: docs/ring/storage-format.md §10-§11 and storage-compression.md §5-§6.
// Everything takes a `ModelContext` and is synchronous, so the same code runs on the main context (tests, the reader)
// and on a background context (`StorageMaintenanceActor`). Never touches days ≤ ring_history_window_days (the hot
// window is `storage_hot_days`, which must exceed it) and never deletes a row before its block was verified by decoding.

nonisolated enum BlockStore {
    static let log = Logger(subsystem: "com.agara.ring", category: "storage")

    /// 2020-01-01T00:00:00Z: rows dated before it, or after now + 1 day, are never compacted (§10, §13).
    static let minEpochMs: Int64 = 1_577_836_800_000
    static let hotDays = Int64(AgaraConfig.Storage.hotDays)

    // MARK: Time

    /// `floor(timeIntervalSince1970 × 1000 + 0.5)` (§2).
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000 + 0.5).rounded(.down)) }
    static func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func utcDay(ms: Int64) -> Int64 { ms >= 0 ? ms / AGB.dayMs : -((-ms + AGB.dayMs - 1) / AGB.dayMs) }
    static func today(now: Date) -> Int64 { utcDay(ms: ms(now)) }
    /// A block is sealed iff `utc_day < today − H` (§10).
    static func sealBoundary(now: Date) -> Int64 { today(now: now) - hotDays }
    static func dayStart(_ day: Int64) -> Date { date(ms: day * AGB.dayMs) }

    // MARK: Keys

    /// One series-day as the rows spell it (`sourceRaw` may be the decode-only `colmi`).
    struct Key: Hashable {
        let metric: String
        let sourceRaw: String
        let sensorId: String
        let day: Int64

        var sourceKey: String? { AGB.sourceKey(sourceRaw) }
        var blockKey: String? { sourceKey.map { AGB.blockKey(metric: metric, source: $0, sensorId: sensorId, utcDay: day) } }
    }

    /// The row-side spelling of a key's source (`legacy` in keys is `colmi` on rows).
    static func rawSource(forKeySource source: String) -> String { source == "legacy" ? "colmi" : source }

    // MARK: Fetch helpers

    static func block(_ blockKey: String, context: ModelContext) -> MeasurementBlock? {
        var d = FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.blockKey == blockKey })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    static func ledger(_ blockKey: String, context: ModelContext) -> BlockSync? {
        var d = FetchDescriptor<BlockSync>(predicate: #Predicate { $0.blockKey == blockKey })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// The rows of one series-day. The window is widened by one second because a `Date` rounds to milliseconds and the
    /// UTC-day of the *rounded* instant decides membership; rows outside are filtered out again.
    static func rows(for key: Key, context: ModelContext) -> [Measurement] {
        let lo = dayStart(key.day).addingTimeInterval(-1), hi = dayStart(key.day + 1).addingTimeInterval(1)
        let metric = key.metric, source = key.sourceRaw, sensor = key.sensorId
        let d = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == metric && $0.sourceRaw == source && $0.sensorId == sensor && $0.timestamp >= lo && $0.timestamp <= hi },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return ((try? context.fetch(d)) ?? []).filter { utcDay(ms: ms($0.timestamp)) == key.day }
    }

    static func hasRows(for key: Key, context: ModelContext) -> Bool {
        let lo = dayStart(key.day).addingTimeInterval(-1), hi = dayStart(key.day + 1).addingTimeInterval(1)
        let metric = key.metric, source = key.sourceRaw, sensor = key.sensorId
        var d = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == metric && $0.sourceRaw == source && $0.sensorId == sensor && $0.timestamp >= lo && $0.timestamp <= hi }
        )
        d.fetchLimit = 1
        return ((try? context.fetchCount(d)) ?? 0) > 0
    }

    // MARK: Writing a block + its ledger row (same transaction as the rows it replaces)

    /// Insert or update the block row from an encoded container and bump the ledger (`revision` +1 iff the payload hash changed).
    @discardableResult
    static func store(_ enc: AGBEncoded, key: Key, sealed: Bool, context: ModelContext, now: Date) -> MeasurementBlock? {
        guard let blockKey = key.blockKey, let source = key.sourceKey else { return nil }
        let decoded = AGB.decode(enc.container)
        guard decoded.isOK, let summary = decoded.summary else { return nil }
        let stamp = ms(now)
        let row = block(blockKey, context: context)
            ?? MeasurementBlock(blockKey: blockKey, metric: key.metric, source: source, sensorId: key.sensorId,
                                utcDay: Int(key.day), sealed: sealed, data: enc.container, now: stamp)
        if row.modelContext == nil { context.insert(row) }
        row.sealed = sealed
        row.state = 0
        row.reason = nil
        row.n = summary.n > 0 ? summary.n : nil
        row.tFirst = summary.firstTs; row.tLast = summary.lastTs
        row.vMin = summary.min; row.vMax = summary.max; row.vSum = summary.sum
        row.fmtMajor = decoded.major; row.fmtMinor = decoded.minor; row.codec = decoded.codec
        row.crc32 = decoded.crc32.map(Int64.init)
        row.data = enc.container
        row.updatedAt = stamp
        bumpLedger(blockKey: blockKey, hash: enc.contentHash, context: context, stamp: stamp)
        return row
    }

    @discardableResult
    static func bumpLedger(blockKey: String, hash: Data, context: ModelContext, stamp: Int64) -> BlockSync {
        if let ledger = ledger(blockKey, context: context) {
            if ledger.contentHash != hash { ledger.revision += 1; ledger.contentHash = hash }
            ledger.updatedAt = stamp
            return ledger
        }
        let ledger = BlockSync(blockKey: blockKey, revision: 1, contentHash: hash, now: stamp)
        context.insert(ledger)
        return ledger
    }

    // MARK: Compaction of one series-day (§10 "sealed")

    enum SkipReason: String, Equatable {
        case notSealable          // the day is inside the hot window
        case ineligible           // unknown metric, or a source that is never blocked (sample data)
        case outOfRange           // dated before 2020 or more than a day in the future — stays hot, flagged
        case noRows
        case workoutLinked        // a row carries an activity-session link: kept hot, whole series-day
        case blockUnreadable      // an existing block is skipped/quarantined: a merge with it is refused
        case tooManyPoints        // more than the format holds: the rows stay hot
        case verifyFailed         // the block did not decode back to the rows: nothing was written
    }

    enum CompactResult: Equatable {
        case compacted(rows: Int, points: Int)
        case skipped(SkipReason)
    }

    /// Test hook: called after the block and ledger are staged, before the rows are deleted and the transaction commits.
    typealias Failpoint = () throws -> Void

    static func compact(_ key: Key, now: Date, context: ModelContext, failpoint: Failpoint? = nil) throws -> CompactResult {
        guard key.day < sealBoundary(now: now) else { return .skipped(.notSealable) }
        guard let blockKey = key.blockKey, AGB.scales[key.metric] != nil else { return .skipped(.ineligible) }
        guard key.day * AGB.dayMs >= minEpochMs, key.day * AGB.dayMs <= ms(now) + AGB.dayMs else { return .skipped(.outOfRange) }
        let rows = rows(for: key, context: context)
        guard !rows.isEmpty else { return .skipped(.noRows) }
        guard !rows.contains(where: { $0.activitySessionId != nil }) else { return .skipped(.workoutLinked) }

        var points = rows.map { AGBPoint(ts: ms($0.timestamp), value: $0.value) }
        if let existing = block(blockKey, context: context) {
            if existing.state != 0 { return .skipped(.blockUnreadable) }
            // A sealed block is the source of truth: rows for its day are late points and merge into it. An open
            // snapshot is derived from rows, so the rows alone define the sealed block (a revised history value must not
            // lose to a stale snapshot under the larger-value rule).
            if existing.sealed {
                let d = AGB.decode(existing.data)
                guard d.isOK else { markUnreadable(existing, d.status, context: context, now: now); return .skipped(.blockUnreadable) }
                points += d.points
            }
        }
        // A point the user deleted stays deleted: a late row (import, a phone-clock change) must not resurrect it.
        let dead = tombstones(for: key, context: context)
        if !dead.isEmpty { points.removeAll { dead.contains($0.ts) } }
        guard let enc = AGB.encodeBlock(points: points, metric: key.metric, utcDay: key.day) else { return .skipped(.tooManyPoints) }
        // Verify by decoding: header, CRC, hash, then point-for-point equality with the canonical form of what we meant to store.
        guard verify(enc, points: points, metric: key.metric, day: key.day) else {
            log.error("block verify failed for \(blockKey, privacy: .public); rows kept")
            return .skipped(.verifyFailed)
        }
        guard store(enc, key: key, sealed: true, context: context, now: now) != nil else { return .skipped(.verifyFailed) }
        do {
            try failpoint?()
            for row in rows { context.delete(row) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return .compacted(rows: rows.count, points: enc.pointCount)
    }

    static func verify(_ enc: AGBEncoded, points: [AGBPoint], metric: String, day: Int64) -> Bool {
        let d = AGB.decode(enc.container)
        guard d.isOK, d.contentHash == enc.contentHash, let expected = AGB.canonicalise(points, metric: metric, utcDay: day) else { return false }
        guard d.timestamps == expected.ts, d.valueMode.map(UInt8.init) == expected.mode else { return false }
        if expected.mode == 0 { return d.q == expected.q }
        return d.values.map(\.bitPattern) == expected.v.map(\.bitPattern)
    }

    // MARK: Open-day snapshots (§10 "open")

    /// Re-canonicalise every open day from its rows and store the snapshot when the hash moved (`revision` +1). The rows
    /// stay the source of truth; this exists so `block_sync` is populated from 1.0 and recent days are syncable. Returns
    /// the number of snapshots written.
    @discardableResult
    static func snapshotOpenDays(now: Date, context: ModelContext) throws -> Int {
        var written = 0
        let first = sealBoundary(now: now), last = today(now: now)
        for day in first...last {
            let lo = dayStart(day).addingTimeInterval(-1), hi = dayStart(day + 1).addingTimeInterval(1)
            let d = FetchDescriptor<Measurement>(predicate: #Predicate { $0.timestamp >= lo && $0.timestamp <= hi })
            let rows = ((try? context.fetch(d)) ?? []).filter { utcDay(ms: ms($0.timestamp)) == day }
            var grouped: [Key: [Measurement]] = [:]
            for row in rows { grouped[Key(metric: row.kindRaw, sourceRaw: row.sourceRaw, sensorId: row.sensorId, day: day), default: []].append(row) }
            for (key, keyRows) in grouped.sorted(by: { ($0.key.metric, $0.key.sourceRaw, $0.key.sensorId) < ($1.key.metric, $1.key.sourceRaw, $1.key.sensorId) }) {
                guard let blockKey = key.blockKey, AGB.scales[key.metric] != nil,
                      day * AGB.dayMs >= minEpochMs, day * AGB.dayMs <= ms(now) + AGB.dayMs else { continue }
                if let existing = block(blockKey, context: context), existing.sealed || existing.state != 0 { continue }
                let points = keyRows.map { AGBPoint(ts: ms($0.timestamp), value: $0.value) }
                guard let enc = AGB.encodeBlock(points: points, metric: key.metric, utcDay: day) else { continue }
                if let ledger = ledger(blockKey, context: context), ledger.contentHash == enc.contentHash { continue }
                if store(enc, key: key, sealed: false, context: context, now: now) != nil { written += 1 }
            }
        }
        // A snapshot whose rows are all gone (user deleted them) is stale: drop it, and its ledger row if never synced.
        let lowDay = Int(first)
        let stale = FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.sealed == false && $0.utcDay >= lowDay })
        for snap in (try? context.fetch(stale)) ?? [] {
            let key = Key(metric: snap.metric, sourceRaw: rawSource(forKeySource: snap.source), sensorId: snap.sensorId, day: Int64(snap.utcDay))
            if !hasRows(for: key, context: context) {
                if let l = ledger(snap.blockKey, context: context), l.syncedHash == nil { context.delete(l) }
                context.delete(snap)
                written += 1
            }
        }
        if context.hasChanges { try context.save() }
        return written
    }

    // MARK: Deleting a reading that already lives in a block (§10 "Deletion")

    /// Timestamps (ms) the user deleted from this series-day: `MeasurementDeletion` rows keyed `block:<metric>:<source>:<ts>`.
    static func tombstones(for key: Key, context: ModelContext) -> Set<Int64> {
        guard let source = key.sourceKey else { return [] }
        let lo = dayStart(key.day).addingTimeInterval(-1), hi = dayStart(key.day + 1).addingTimeInterval(1)
        let metric = key.metric
        let d = FetchDescriptor<MeasurementDeletion>(predicate: #Predicate { $0.kindRaw == metric && $0.timestamp >= lo && $0.timestamp <= hi })
        let prefix = "block:\(metric):\(source):"
        var out = Set<Int64>()
        for row in (try? context.fetch(d)) ?? [] where row.measurementId.hasPrefix(prefix) {
            if let ts = Int64(row.measurementId.dropFirst(prefix.count)) { out.insert(ts) }
        }
        return out
    }

    struct PointRef: Hashable {
        let metric: String
        let sourceRaw: String
        let sensorId: String
        let ts: Int64
    }

    /// Re-encode the sealed block of each point without it (a revision bump), or delete the block if it empties. The
    /// caller writes the tombstones. Returns the points that were actually found and removed. Saves.
    @discardableResult
    static func removePoints(_ refs: [PointRef], now: Date, context: ModelContext) -> [PointRef] {
        var removed: [PointRef] = []
        let grouped = Dictionary(grouping: refs) { Key(metric: $0.metric, sourceRaw: $0.sourceRaw, sensorId: $0.sensorId, day: utcDay(ms: $0.ts)) }
        for (key, group) in grouped {
            guard let blockKey = key.blockKey, let existing = block(blockKey, context: context), existing.state == 0 else { continue }
            let dec = AGB.decode(existing.data)
            guard dec.isOK else { markUnreadable(existing, dec.status, context: context, now: now); continue }
            let present = Set(dec.timestamps)
            let gone = Set(group.map(\.ts)).intersection(present)
            guard !gone.isEmpty else { continue }
            guard let enc = try? AGB.mergePoints(dec.points, metric: key.metric, utcDay: key.day, tombstones: gone) else { continue }
            if enc.pointCount == 0 {
                if let l = ledger(blockKey, context: context), l.syncedHash == nil { context.delete(l) }
                context.delete(existing)
            } else {
                store(enc, key: key, sealed: existing.sealed, context: context, now: now)
            }
            removed += group.filter { gone.contains($0.ts) }
        }
        try? context.save()
        return removed
    }

    // MARK: Unreadable blocks (§8)

    /// Record a decode failure on the stored block: state 1 (skipped: made by a newer version) or 2 (quarantined). The
    /// bytes are never modified or deleted. The ledger hash becomes the hash of the stored container (identification only).
    static func markUnreadable(_ block: MeasurementBlock, _ status: AGBStatus, context: ModelContext, now: Date) {
        switch status {
        case .ok: return
        case let .skip(reason): block.state = 1; block.reason = reason
        case let .quarantine(reason): block.state = 2; block.reason = reason
        }
        block.n = nil; block.tFirst = nil; block.tLast = nil; block.vMin = nil; block.vMax = nil; block.vSum = nil
        block.updatedAt = ms(now)
        bumpLedger(blockKey: block.blockKey, hash: AGB.containerHash(block.data), context: context, stamp: ms(now))
        context.insert(WearableLog(category: .error, level: .error, message: "storage block \(block.state == 1 ? "skipped" : "quarantined")",
                                   metadataJSON: #"{"block_key":"\#(block.blockKey)","reason":"\#(block.reason ?? "")"}"#))
        try? context.save()
    }

    /// Once per upgrade: blocks in state skip may be readable by this build (§8). Returns how many became readable.
    @discardableResult
    static func redecodeSkipped(context: ModelContext, now: Date) -> Int {
        let d = FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.state == 1 })
        var recovered = 0
        for block in (try? context.fetch(d)) ?? [] {
            let dec = AGB.decode(block.data)
            guard dec.isOK, let s = dec.summary else { continue }
            block.state = 0; block.reason = nil
            block.n = s.n > 0 ? s.n : nil; block.tFirst = s.firstTs; block.tLast = s.lastTs
            block.vMin = s.min; block.vMax = s.max; block.vSum = s.sum
            block.fmtMajor = dec.major; block.fmtMinor = dec.minor; block.codec = dec.codec; block.crc32 = dec.crc32.map(Int64.init)
            if let hash = dec.contentHash { bumpLedger(blockKey: block.blockKey, hash: hash, context: context, stamp: ms(now)) }
            recovered += 1
        }
        if recovered > 0 { try? context.save() }
        return recovered
    }
}
