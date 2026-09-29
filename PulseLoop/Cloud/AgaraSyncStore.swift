import Foundation
import SwiftData
import OSLog

/// Which parts of a block key the wire spells: `v1/<metric>/<source>/<sensor_id>/<utc_day>`.
nonisolated struct ParsedBlockKey: Equatable, Sendable {
    let metric: String
    let source: String
    let sensorId: String
    let day: Int64

    static func parse(_ key: String) -> ParsedBlockKey? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "v1", let day = Int64(parts[4]), parts[4] == String(day),
              parts[3].count == 16, parts[3].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return ParsedBlockKey(metric: parts[1], source: parts[2], sensorId: parts[3], day: day)
    }
}

/// A block that is behind the server, ready to send.
nonisolated struct PendingBlock: Sendable, Equatable {
    var wire: WireBlock
    /// The block object exactly as it goes into the request body (fixed key order, exact decimals).
    var json: String
    var hash: Data
    var revision: Int
    /// Rough size on the wire (base64 payload plus the JSON around it), for batching by `sync_max_body_bytes`.
    var estimatedBytes: Int { json.utf8.count + 1 }
}

/// What applying one page of `GET /changes` did locally.
nonisolated struct PullReport: Equatable, Sendable {
    var seen = 0
    /// Already identical locally (usually the client's own accepted block coming back).
    var alreadyCurrent = 0
    var storedNew = 0
    var mergedLocally = 0
    var rowsInserted = 0
    var rowsDeleted = 0
    /// Skipped: unknown metric or a source that is never blocked.
    var skippedUnknown = 0
    /// Skipped: a local block is unreadable (a merge with it is refused) or the pulled bytes do not decode.
    var skippedUnreadable = 0
    /// The pulled bytes failed verification (bad base64, hash or key mismatch): dropped, never stored.
    var rejectedBad = 0
    /// After applying, at least one block is behind the server again, so another push is due.
    var needsUpload = false

    var changedLocalData: Bool { storedNew + mergedLocally + rowsInserted + rowsDeleted > 0 }

    mutating func add(_ other: PullReport) {
        seen += other.seen; alreadyCurrent += other.alreadyCurrent; storedNew += other.storedNew
        mergedLocally += other.mergedLocally; rowsInserted += other.rowsInserted; rowsDeleted += other.rowsDeleted
        skippedUnknown += other.skippedUnknown; skippedUnreadable += other.skippedUnreadable
        rejectedBad += other.rejectedBad; needsUpload = needsUpload || other.needsUpload
    }
}

/// The database side of the sync engine, on a background `ModelContext` (never the main one), so building batches of
/// megabytes of blocks never stalls the UI. Reads `measurement_blocks` + the `block_sync` ledger, writes the ledger
/// with what the server accepted, and applies pulled blocks with the union-read rules of storage-format §10/§11.
@ModelActor
actor AgaraSyncStore {
    private static let log = Logger(subsystem: "com.agara.ring", category: "agara-sync")

    // MARK: Push side

    /// Blocks whose ledger says the server is behind, newest days first, minus what the server already refused
    /// (`rejected`: `block_key → hash hex`). Only readable blocks with points; only sources that are ever blocked
    /// (`mock`/demo never is). At most `limit` blocks and about `maxBytes` of body.
    func pending(rejected: [String: String], limit: Int, maxBytes: Int) -> [PendingBlock] {
        let ledgers = (try? modelContext.fetch(FetchDescriptor<BlockSync>())) ?? []
        var candidates: [(key: String, day: Int64, ledger: BlockSync)] = []
        for ledger in ledgers where !ledger.isSynced {
            guard let parsed = ParsedBlockKey.parse(ledger.blockKey), Self.isUploadable(source: parsed.source, metric: parsed.metric) else { continue }
            if rejected[ledger.blockKey] == AGB.hex(ledger.contentHash) { continue }
            candidates.append((ledger.blockKey, parsed.day, ledger))
        }
        candidates.sort { $0.day != $1.day ? $0.day > $1.day : $0.key < $1.key }

        var out: [PendingBlock] = []
        var bytes = 0
        for candidate in candidates {
            if out.count >= limit { break }
            guard let block = BlockStore.block(candidate.key, context: modelContext), block.state == 0, block.n != nil,
                  let pending = Self.makePending(block: block, ledger: candidate.ledger, context: modelContext) else { continue }
            if !out.isEmpty, bytes + pending.estimatedBytes > maxBytes { break }
            out.append(pending)
            bytes += pending.estimatedBytes
        }
        return out
    }

    /// Unsynced, uploadable blocks per metric (the per-metric progress totals).
    func unsyncedCounts(rejected: [String: String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for ledger in (try? modelContext.fetch(FetchDescriptor<BlockSync>())) ?? [] where !ledger.isSynced {
            guard let parsed = ParsedBlockKey.parse(ledger.blockKey), Self.isUploadable(source: parsed.source, metric: parsed.metric) else { continue }
            if rejected[ledger.blockKey] == AGB.hex(ledger.contentHash) { continue }
            counts[parsed.metric, default: 0] += 1
        }
        return counts
    }

    /// Sources that are ever synced. `mock` (sample data, demo) never is, whatever created the block.
    static func isUploadable(source: String, metric: String) -> Bool {
        AGB.sources.contains(source) && AGB.scales[metric] != nil
    }

    private static func makePending(block: MeasurementBlock, ledger: BlockSync, context: ModelContext) -> PendingBlock? {
        guard let n = block.n else { return nil }
        let key = BlockStore.Key(metric: block.metric, sourceRaw: BlockStore.rawSource(forKeySource: block.source),
                                 sensorId: block.sensorId, day: Int64(block.utcDay))
        var dead = BlockStore.tombstones(for: key, context: context)
        if block.source == "history" { dead.formUnion(historyTombstones(for: key, context: context)) }
        let decoded = AGB.decode(block.data)
        guard decoded.isOK, let text = WireBlockBuilder.json(blockKey: block.blockKey, revision: ledger.revision, sealed: block.sealed, decoded: decoded,
                                                             tombstones: dead.sorted(), container: block.data) else { return nil }
        let wire = WireBlock(
            blockKey: block.blockKey, metric: block.metric, source: block.source, sensorId: block.sensorId, utcDay: block.utcDay,
            revision: ledger.revision, sealed: block.sealed,
            fmt: WireFormat(major: block.fmtMajor ?? 1, minor: block.fmtMinor ?? 0, codec: block.codec ?? 0),
            contentHash: AGB.hex(ledger.contentHash),
            summary: WireSummary(n: n, min: block.vMin, max: block.vMax, sum: block.vSum, firstTs: block.tFirst, lastTs: block.tLast),
            tombstones: dead.isEmpty ? nil : dead.sorted(), data: block.data.base64EncodedString())
        return PendingBlock(wire: wire, json: text, hash: ledger.contentHash, revision: ledger.revision)
    }

    /// `history:<metric>:<ts>` deletions of this series-day (a deleted history reading is a tombstone for the point).
    private static func historyTombstones(for key: BlockStore.Key, context: ModelContext) -> Set<Int64> {
        let lo = BlockStore.dayStart(key.day).addingTimeInterval(-1), hi = BlockStore.dayStart(key.day + 1).addingTimeInterval(1)
        let metric = key.metric
        let d = FetchDescriptor<MeasurementDeletion>(predicate: #Predicate { $0.kindRaw == metric && $0.timestamp >= lo && $0.timestamp <= hi })
        let prefix = "history:\(metric):"
        var out = Set<Int64>()
        for row in (try? context.fetch(d)) ?? [] where row.measurementId.hasPrefix(prefix) {
            if let ts = Int64(row.measurementId.dropFirst(prefix.count)), BlockStore.utcDay(ms: ts) == key.day { out.insert(ts) }
        }
        return out
    }

    /// Record what the server accepted for the blocks that were **sent**: `synced_hash` is the hash that was sent (a
    /// block that changed while the request was in flight stays unsynced because `content_hash` moved on).
    /// Returns the keys the server rejected (with the hash that was sent) so the caller can remember them.
    @discardableResult
    func apply(results: [BlockResult], sent: [PendingBlock], now: Date) -> [String: String] {
        let sentByKey = Dictionary(sent.map { ($0.wire.blockKey, $0) }, uniquingKeysWith: { first, _ in first })
        let stamp = BlockStore.ms(now)
        var rejected: [String: String] = [:]
        for result in results {
            guard let sentBlock = sentByKey[result.blockKey] else { continue }
            switch result.status {
            case "accepted", "duplicate", "merged":
                guard let ledger = BlockStore.ledger(result.blockKey, context: modelContext) else { continue }
                ledger.syncedRevision = sentBlock.revision
                ledger.syncedHash = sentBlock.hash
                ledger.syncedAt = stamp
            case "rejected":
                rejected[result.blockKey] = AGB.hex(sentBlock.hash)
                Self.log.error("server rejected a block: \(result.reason ?? "?", privacy: .public)")
            default:
                break   // an unknown status leaves the block unsynced; it is sent again next time
            }
        }
        try? modelContext.save()
        return rejected
    }

    /// Forget that anything was synced (another account signed in, or the account was deleted): every block is unsynced again.
    func resetSyncedFlags() {
        for ledger in (try? modelContext.fetch(FetchDescriptor<BlockSync>())) ?? [] {
            ledger.syncedRevision = nil; ledger.syncedHash = nil; ledger.syncedAt = nil
        }
        try? modelContext.save()
    }

    /// (synced, total) uploadable blocks, for the account screen.
    func ledgerCounts() -> (synced: Int, total: Int) {
        var synced = 0, total = 0
        for ledger in (try? modelContext.fetch(FetchDescriptor<BlockSync>())) ?? [] {
            guard let parsed = ParsedBlockKey.parse(ledger.blockKey), Self.isUploadable(source: parsed.source, metric: parsed.metric) else { continue }
            total += 1
            if ledger.isSynced { synced += 1 }
        }
        return (synced, total)
    }

    // MARK: Pull side

    /// Decode-verify and store one page of pulled blocks (storage-format §10, §11 and the notes at its end):
    ///  * a block identical to what we hold only marks the ledger synced;
    ///  * a day still open (inside `storage_hot_days`), or one that still has rows, gets the server's missing points as
    ///    rows (rows are the truth for open days; the next snapshot is the union);
    ///  * a sealed day is union-merged into the local block (server tombstones and local deletions both honoured), which
    ///    bumps the local revision; if the union equals the server's block it is marked synced, else it is uploaded once.
    func applyPulled(_ blocks: [WireBlock], units: [String: String], now: Date) -> PullReport {
        var report = PullReport()
        for wire in blocks {
            report.seen += 1
            apply(wire, units: units, now: now, report: &report)
        }
        try? modelContext.save()
        return report
    }

    private func apply(_ wire: WireBlock, units: [String: String], now: Date, report: inout PullReport) {
        // 1. The key and its fields must agree, and the source must be one that is ever blocked.
        guard let parsed = ParsedBlockKey.parse(wire.blockKey), parsed.metric == wire.metric, parsed.source == wire.source,
              parsed.sensorId == wire.sensorId, parsed.day == Int64(wire.utcDay) else { report.rejectedBad += 1; return }
        guard Self.isUploadable(source: parsed.source, metric: parsed.metric) else { report.skippedUnknown += 1; return }
        // 2. The container must decode, and the hash must be the payload's.
        guard let container = Data(base64Encoded: wire.data) else { report.rejectedBad += 1; return }
        let decoded = AGB.decode(container)
        guard decoded.isOK, let payloadHash = decoded.contentHash else { report.skippedUnreadable += 1; return }
        guard AGB.hex(payloadHash) == wire.contentHash else { report.rejectedBad += 1; return }
        let day = parsed.day
        guard decoded.timestamps.allSatisfy({ BlockStore.utcDay(ms: $0) == day }) else { report.rejectedBad += 1; return }
        let serverTombs = Set(wire.tombstones ?? [])
        let stamp = BlockStore.ms(now)
        let key = BlockStore.Key(metric: parsed.metric, sourceRaw: BlockStore.rawSource(forKeySource: parsed.source),
                                 sensorId: parsed.sensorId, day: day)

        // 3. Identical to the local copy: nothing to store.
        let local = BlockStore.block(wire.blockKey, context: modelContext)
        if let local, local.state == 0, let ledger = BlockStore.ledger(wire.blockKey, context: modelContext), ledger.contentHash == payloadHash {
            markSynced(wire.blockKey, hash: payloadHash, stamp: stamp)
            report.alreadyCurrent += 1
            return
        }
        if let local, local.state != 0 { report.skippedUnreadable += 1; return }   // a merge with an unreadable block is refused

        let openDay = day >= BlockStore.sealBoundary(now: now)
        let kind = MeasurementKind(rawValue: parsed.metric)
        let rowsExist = BlockStore.hasRows(for: key, context: modelContext)

        if kind != nil, openDay || rowsExist {
            insertRows(decoded: decoded, serverTombstones: serverTombs, key: key, kind: kind!, unit: units[parsed.metric] ?? "", serverHash: payloadHash, now: now, report: &report)
            return
        }

        // 4. Block path: no rows involved.
        let dead = serverTombs.union(BlockStore.tombstones(for: key, context: modelContext))
        if let local {
            let localDecoded = AGB.decode(local.data)
            guard localDecoded.isOK else { report.skippedUnreadable += 1; return }
            guard let merged = try? AGB.mergePoints(localDecoded.points + decoded.points, metric: parsed.metric, utcDay: day, tombstones: dead) else {
                report.skippedUnreadable += 1; return
            }
            if merged.contentHash != (BlockStore.ledger(wire.blockKey, context: modelContext)?.contentHash ?? Data()) {
                if merged.pointCount == 0 {
                    report.alreadyCurrent += 1
                    return
                }
                BlockStore.store(merged, key: key, sealed: local.sealed || wire.sealed, context: modelContext, now: now)
                report.mergedLocally += 1
            } else {
                report.alreadyCurrent += 1
            }
            if merged.contentHash == payloadHash { markSynced(wire.blockKey, hash: payloadHash, stamp: stamp) } else { report.needsUpload = true }
        } else {
            // New to this device. Tombstones the server holds are already removed from its bytes, but a point the user
            // deleted here must not come back from an older copy either.
            let localDead = BlockStore.tombstones(for: key, context: modelContext)
            var enc = AGBEncoded(container: container, payload: Data(decoded.payload ?? []), contentHash: payloadHash,
                                 pointCount: decoded.timestamps.count, dropped: AGBDropped())
            if !localDead.isEmpty, decoded.timestamps.contains(where: { localDead.contains($0) }),
               let filtered = try? AGB.mergePoints(decoded.points, metric: parsed.metric, utcDay: day, tombstones: localDead) {
                enc = filtered
            }
            guard enc.pointCount > 0 else { report.alreadyCurrent += 1; return }
            BlockStore.store(enc, key: key, sealed: wire.sealed || !openDay, context: modelContext, now: now)
            report.storedNew += 1
            if enc.contentHash == payloadHash { markSynced(wire.blockKey, hash: payloadHash, stamp: stamp) } else { report.needsUpload = true }
        }
    }

    /// The row path for an open day (or one with rows): insert the points we lack, drop rows the server's tombstones name,
    /// then rebuild the open snapshot from the rows so the ledger compares like with like.
    private func insertRows(decoded: AGBDecoded, serverTombstones: Set<Int64>, key: BlockStore.Key, kind: MeasurementKind, unit: String,
                            serverHash: Data, now: Date, report: inout PullReport) {
        let stamp = BlockStore.ms(now)
        let localDead = BlockStore.tombstones(for: key, context: modelContext)
        var existing = BlockStore.rows(for: key, context: modelContext)
        var known = Set(existing.map { BlockStore.ms($0.timestamp) })

        // Deletions made on another device.
        for row in existing where serverTombstones.contains(BlockStore.ms(row.timestamp)) {
            let ts = BlockStore.ms(row.timestamp)
            if let source = key.sourceKey {
                let id = "block:\(key.metric):\(source):\(ts)"
                modelContext.insert(MeasurementDeletion(measurementId: id, kindRaw: key.metric, timestamp: row.timestamp, deletedAt: now))
            }
            modelContext.delete(row)
            known.remove(ts)
            report.rowsDeleted += 1
        }
        existing.removeAll { serverTombstones.contains(BlockStore.ms($0.timestamp)) }

        let source = MeasurementSource(rawValue: key.sourceRaw) ?? .history
        var inserted = 0
        for point in decoded.points where !known.contains(point.ts) && !localDead.contains(point.ts) {
            modelContext.insert(Measurement(kind: kind, value: point.value, unit: unit, timestamp: BlockStore.date(ms: point.ts),
                                            source: source, sensorId: key.sensorId))
            inserted += 1
        }
        report.rowsInserted += inserted

        // Rebuild the snapshot from the rows (unless a sealed block already holds the day).
        try? modelContext.save()
        guard let blockKey = key.blockKey else { return }
        let sealedHere = BlockStore.block(blockKey, context: modelContext).map { $0.sealed } ?? false
        let rows = BlockStore.rows(for: key, context: modelContext)
        let points = rows.map { AGBPoint(ts: BlockStore.ms($0.timestamp), value: $0.value) }
        if !sealedHere, let enc = AGB.encodeBlock(points: points, metric: key.metric, utcDay: key.day) {
            let ledgerHash = BlockStore.ledger(blockKey, context: modelContext)?.contentHash
            if ledgerHash != enc.contentHash { BlockStore.store(enc, key: key, sealed: false, context: modelContext, now: now) }
            if enc.contentHash == serverHash { markSynced(blockKey, hash: serverHash, stamp: stamp) } else { report.needsUpload = true }
        } else if sealedHere {
            report.needsUpload = report.needsUpload || inserted > 0   // maintenance folds the new rows into the sealed block
        }
        if inserted == 0, report.rowsDeleted == 0 { report.alreadyCurrent += 1 }
    }

    private func markSynced(_ blockKey: String, hash: Data, stamp: Int64) {
        guard let ledger = BlockStore.ledger(blockKey, context: modelContext), ledger.contentHash == hash else { return }
        ledger.syncedRevision = ledger.revision
        ledger.syncedHash = hash
        ledger.syncedAt = stamp
    }
}
