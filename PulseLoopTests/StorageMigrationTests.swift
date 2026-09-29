import XCTest
import SwiftData
import SQLite3
@testable import PulseLoop

private typealias Measurement = PulseLoop.Measurement

/// Phase-3 evidence on a **copy** of a real iOS store (the Mac app container backup in `captures/backup/`, git-ignored, so
/// the test skips where it is absent). Proves: the store from before this change opens under the new schema (lightweight
/// migration, `sensorId` backfilled), compaction leaves every reading (count per kind/source/day; value sums within the
/// scale's rounding), the DB shrinks, and the legacy raw-packet rows survive as bytes. Prints counts and sizes only.
@MainActor
final class StorageMigrationTests: XCTestCase {
    private let backup = "captures/backup/mac-container-20260925-233213/Application Support"

    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func copyOfBackup() throws -> URL {
        let src = repoRoot.appendingPathComponent(backup)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.appendingPathComponent("default.store").path),
                          "no store backup at \(backup) (captures/ is git-ignored)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = src.appendingPathComponent("default.store" + suffix)
            if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent("default.store" + suffix)) }
        }
        return dir.appendingPathComponent("default.store")
    }

    private struct Cell: Hashable { let kind: String; let source: String; let day: Int64 }
    private struct Agg { var n = 0; var sum = 0.0 }

    /// Per (kind, source, UTC day): count and value sum, from rows and blocks together (the reader path).
    private func aggregate(_ context: ModelContext) -> [Cell: Agg] {
        var out: [Cell: Agg] = [:]
        for kind in MeasurementKind.allCases {
            for m in MetricsRepository.measurements(kind: kind, context: context) {
                let cell = Cell(kind: m.kindRaw, source: m.sourceRaw, day: BlockStore.utcDay(ms: BlockStore.ms(m.timestamp)))
                out[cell, default: Agg()].n += 1
                out[cell, default: Agg()].sum += m.value
            }
        }
        return out
    }

    func testRealStoreMigratesCompactsLosslesslyAndShrinks() async throws {
        let storeURL = try copyOfBackup()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        // 1. The pre-change store opens under the new schema (lightweight migration; nothing moved aside).
        let container = try ModelContainerFactory.make(url: storeURL)
        let context = ModelContext(container)
        let rowsBefore = try context.fetchCount(FetchDescriptor<Measurement>())
        XCTAssertGreaterThan(rowsBefore, 1000, "the backup should hold thousands of readings")
        let unknown = AgaraConfig.Storage.sensorUnknownId
        let withSensor = try context.fetchCount(FetchDescriptor<Measurement>(predicate: #Predicate { $0.sensorId == unknown }))
        XCTAssertEqual(withSensor, rowsBefore, "every pre-existing row is backfilled with the unknown sensor id")
        let legacyPackets = try context.fetchCount(FetchDescriptor<RawPacketRow>())

        let before = aggregate(context)
        XCTAssertEqual(before.values.reduce(0) { $0 + $1.n }, rowsBefore)
        // What the format keeps per (kind, source, day): one point per distinct millisecond, the larger value on a conflict.
        // Computed from the rows with the canonicaliser itself, so the check is against the spec rule, not against a copy of it.
        var expected: [Cell: Agg] = [:]
        var perCellPoints: [Cell: [AGBPoint]] = [:]
        for row in try context.fetch(FetchDescriptor<Measurement>()) {
            let cell = Cell(kind: row.kindRaw, source: row.sourceRaw, day: BlockStore.utcDay(ms: BlockStore.ms(row.timestamp)))
            perCellPoints[cell, default: []].append(AGBPoint(ts: BlockStore.ms(row.timestamp), value: row.value))
        }
        var sameMillisecondDuplicates = [String: Int]()
        for (cell, pts) in perCellPoints {
            let c = try XCTUnwrap(AGB.canonicalise(pts, metric: cell.kind, utcDay: cell.day))
            let scale = AGB.pow10[c.e]
            expected[cell] = Agg(n: c.count, sum: c.mode == 0 ? Double(c.q.reduce(0, +)) / scale : c.v.reduce(0, +))
            sameMillisecondDuplicates[cell.kind + "/" + cell.source, default: 0] += pts.count - c.count
        }
        let usageBefore = StorageMeter.measure(storeURL: storeURL)
        try XCTSkipUnless(usageBefore.exact, "dbstat is not available in this SQLite build")

        // 2. Maintenance with a clock well after the data, so every day is sealed.
        let now = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14: all backup rows are older than the hot window
        var options = StorageMaintenance.Options(); options.runLadder = false
        let report = StorageMaintenance.run(now: now, context: context, options: options)
        XCTAssertEqual(report.failures, 0)
        XCTAssertGreaterThan(report.blocksCompacted, 0)
        XCTAssertEqual(report.legacyPacketsConverted, legacyPackets)
        try context.save()

        // 3. Nothing lost: counts identical per (kind, source, day); sums within the metric's rounding.
        let after = aggregate(context)
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        var maxSumDelta = 0.0
        for (cell, agg) in before {
            let now = try XCTUnwrap(after[cell])
            let want = try XCTUnwrap(expected[cell])
            XCTAssertEqual(now.n, want.n, "count for \(cell.kind)/\(cell.source)/\(cell.day)")
            XCTAssertEqual(now.sum, want.sum, accuracy: 1e-6, "sum for \(cell.kind)/\(cell.source)/\(cell.day)")
            // Where no two rows share a millisecond the block holds the rows 1:1 (values within the scale's rounding).
            if want.n == agg.n {
                let e = Double(AGB.scales[cell.kind] ?? 0)
                XCTAssertLessThanOrEqual(abs(now.sum - agg.sum), Double(agg.n) * 0.5 / pow(10, e) + 1e-9, "\(cell.kind)/\(cell.source)/\(cell.day)")
            }
            maxSumDelta = max(maxSumDelta, abs(now.sum - want.sum))
        }
        // Every kind/source except the pre-throttle live heart rate is 1:1; the live-HR bursts are the only collapse.
        let collapsed = sameMillisecondDuplicates.filter { $0.value > 0 }
        XCTAssertEqual(Set(collapsed.keys), ["hr/live"], "only the burst-recorded live HR shares milliseconds: \(collapsed)")
        let rowsAfter = try context.fetchCount(FetchDescriptor<Measurement>())
        let blocks = try context.fetchCount(FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.sealed == true }))
        let ledgers = try context.fetchCount(FetchDescriptor<BlockSync>())
        XCTAssertEqual(rowsAfter, 0, "every backup day is sealed, so no hot rows remain")
        XCTAssertEqual(ledgers, blocks)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawPacketRow>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawPacketRecord>()), legacyPackets, "legacy trace rows survive as bytes")

        // 4. The size drop. Checkpoint, give free pages back, measure again.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        sqlite3_exec(raw, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        sqlite3_close(raw)
        let reclaimed = StorageMeter.reclaim(storeURL: storeURL)
        let usageAfter = StorageMeter.measure(storeURL: storeURL)
        let mb = { (b: Int64) in String(format: "%.2f MB", Double(b) / 1_048_576) }
        let summary = """
        rows \(rowsBefore) -> \(rowsAfter) hot; blocks \(blocks); points kept \(after.values.reduce(0) { $0 + $1.n }); same-millisecond duplicates collapsed \(collapsed); legacy packets \(legacyPackets); max |sum delta vs spec rule| \(maxSumDelta)
        health readings: \(mb(usageBefore.bytes(.healthReadings))) -> \(mb(usageAfter.bytes(.healthReadings)))
        diagnostics:     \(mb(usageBefore.bytes(.diagnostics))) -> \(mb(usageAfter.bytes(.diagnostics)))
        live bytes:      \(mb(usageBefore.usedBytes)) -> \(mb(usageAfter.usedBytes)); files \(mb(usageBefore.fileBytes)) -> \(mb(usageAfter.fileBytes)); reclaimed \(mb(reclaimed))
        """
        print("STORAGE-MIGRATION-EVIDENCE\n\(summary)")
        add(XCTAttachment(string: summary))
        XCTAssertLessThan(usageAfter.bytes(.healthReadings) * 10, usageBefore.bytes(.healthReadings), "readings are at least 10x smaller as blocks")
        XCTAssertLessThan(usageAfter.fileBytes, usageBefore.fileBytes)
        // The blocks read back through the chart path.
        XCTAssertFalse(MetricsService.metricRange(metric: .heartRate, range: .twelveMonths, context: context).isEmpty)
    }
}
