import XCTest
import SwiftData
@testable import PulseLoop

private typealias Measurement = PulseLoop.Measurement

/// Phase-3 storage: compaction (writer), the ledger, the reader, deletion, crash-resume and the cap ladder.
/// Uses an in-memory store and a pinned clock; nothing here reads a real user's data.
@MainActor
final class BlockStoreTests: XCTestCase {
    private var context: ModelContext!
    /// 2026-09-29T12:00:00Z
    private let now = Date(timeIntervalSince1970: 1_790_596_800)
    private let ring = "a3a04cab4846d63c"
    private var today: Int64 { BlockStore.today(now: now) }

    override func setUpWithError() throws {
        context = try TestSupport.makeContext()
        SensorIdentity.shared.reset()
        ReadingDeletion.invalidate()
    }

    override func tearDown() {
        SensorIdentity.shared.reset()
        ReadingDeletion.invalidate()
    }

    // MARK: Helpers

    /// `count` readings on UTC day `day`, one every `stepMs`, values from `value(i)`.
    @discardableResult
    private func insertDay(_ day: Int64, kind: MeasurementKind = .heartRate, source: MeasurementSource = .live, sensor: String? = nil,
                           count: Int = 200, stepMs: Int64 = 5_000, startMs: Int64 = 3_600_000, value: (Int) -> Double = { Double(60 + $0 % 40) }) -> [Measurement] {
        (0..<count).map { i in
            let row = Measurement(kind: kind, value: value(i), unit: kind.unit,
                                  timestamp: BlockStore.date(ms: day * AGB.dayMs + startMs + Int64(i) * stepMs), source: source, sensorId: sensor ?? ring)
            context.insert(row)
            return row
        }
    }

    private func rowCount(_ kind: MeasurementKind? = nil) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Measurement>())) ?? []
        return kind.map { k in all.filter { $0.kindRaw == k.rawValue }.count } ?? all.count
    }

    private func blocks() -> [MeasurementBlock] { (try? context.fetch(FetchDescriptor<MeasurementBlock>(sortBy: [SortDescriptor(\.blockKey)]))) ?? [] }
    private func ledgers() -> [BlockSync] { (try? context.fetch(FetchDescriptor<BlockSync>(sortBy: [SortDescriptor(\.blockKey)]))) ?? [] }

    private func compactAll() -> StorageMaintenance.CompactionSummary {
        try? context.save()
        return StorageMaintenance.compactAll(now: now, context: context)
    }

    // MARK: Sealing rules

    func testOnlyDaysOlderThanTheHotWindowAreSealed() throws {
        XCTAssertGreaterThan(AgaraConfig.Storage.hotDays, AgaraConfig.Ring.historyWindowDays, "the hot window must exceed the ring's history window")
        insertDay(today - 11)                 // sealed
        insertDay(today - 10)                 // open: sealed iff utc_day < today − 10
        insertDay(today - Int64(AgaraConfig.Ring.historyWindowDays))   // ring window: never touched
        insertDay(today)
        let s = compactAll()
        XCTAssertEqual(s.blocks, 1)
        XCTAssertEqual(blocks().filter(\.sealed).map(\.utcDay), [Int(today - 11)])
        XCTAssertEqual(rowCount(), 600, "three hot days keep every row")
    }

    func testCompactionWritesVerifiedBlockLedgerAndSummaryThenDeletesTheRows() throws {
        let rows = insertDay(today - 15, count: 300)
        let values = rows.map(\.value), stamps = rows.map { BlockStore.ms($0.timestamp) }
        let s = compactAll()
        XCTAssertEqual(s.blocks, 1); XCTAssertEqual(s.rows, 300); XCTAssertEqual(s.points, 300)
        XCTAssertEqual(rowCount(), 0)
        let block = try XCTUnwrap(blocks().first)
        XCTAssertEqual(block.blockKey, "v1/hr/live/\(ring)/\(today - 15)")
        XCTAssertTrue(block.sealed); XCTAssertEqual(block.state, 0)
        XCTAssertEqual(block.n, 300)
        XCTAssertEqual(block.vMin, values.min()); XCTAssertEqual(block.vMax, values.max()); XCTAssertEqual(block.vSum, values.reduce(0, +))
        XCTAssertEqual(block.tFirst, stamps.first); XCTAssertEqual(block.tLast, stamps.last)
        XCTAssertEqual(block.fmtMajor, 1); XCTAssertEqual(block.fmtMinor, 0)
        XCTAssertEqual(block.crc32, Int64(AGB.decode(block.data).crc32!))
        let ledger = try XCTUnwrap(ledgers().first)
        XCTAssertEqual(ledger.revision, 1)
        XCTAssertEqual(ledger.contentHash, AGB.decode(block.data).contentHash)
        XCTAssertNil(ledger.syncedRevision); XCTAssertNil(ledger.syncedHash)
        XCTAssertFalse(ledger.isSynced, "with the cloud off every block stays unsynced")
    }

    func testCompactionIsIdempotent() throws {
        insertDay(today - 12, count: 120)
        _ = compactAll()
        let hash = ledgers().first?.contentHash
        let again = compactAll()
        XCTAssertEqual(again.blocks, 0)
        XCTAssertEqual(ledgers().first?.revision, 1)
        XCTAssertEqual(ledgers().first?.contentHash, hash)
        XCTAssertEqual(blocks().count, 1)
    }

    func testSeriesAreSeparatedByMetricSourceAndSensor() throws {
        let day = today - 20
        insertDay(day, kind: .heartRate, source: .live, sensor: "1111111111111111", count: 50)
        insertDay(day, kind: .heartRate, source: .live, sensor: "2222222222222222", count: 50, startMs: 7_200_000)
        insertDay(day, kind: .heartRate, source: .history, sensor: "1111111111111111", count: 50, stepMs: 60_000)
        insertDay(day, kind: .spo2, source: .history, sensor: "1111111111111111", count: 20, stepMs: 60_000, value: { _ in 97 })
        insertDay(day, kind: .heartRate, source: .legacyVendor, sensor: AgaraConfig.Storage.sensorUnknownId, count: 10)
        let s = compactAll()
        XCTAssertEqual(s.blocks, 5)
        let keys = Set(blocks().map(\.blockKey))
        XCTAssertTrue(keys.contains("v1/hr/legacy/0000000000000000/\(day)"), "the earlier ring family's raw value maps to `legacy`")
        XCTAssertTrue(keys.contains("v1/spo2/history/1111111111111111/\(day)"))
        XCTAssertEqual(rowCount(), 0)
    }

    func testSampleDataUnknownMetricsAndWorkoutLinkedRowsAreNeverBlocked() throws {
        let day = today - 20
        insertDay(day, source: .mock, count: 30)
        let linked = insertDay(day, source: .workout, count: 10)
        linked[3].activitySessionId = UUID()
        let s = compactAll()
        XCTAssertEqual(s.blocks, 0)
        XCTAssertEqual(s.skipped[.ineligible], 1)
        XCTAssertEqual(s.skipped[.workoutLinked], 1)
        XCTAssertEqual(rowCount(), 40)
        XCTAssertTrue(blocks().isEmpty)
    }

    func testRowsDatedBefore2020OrInTheFutureStayHotAndAreNeverMerged() throws {
        let old = Int64(BlockStore.minEpochMs / AGB.dayMs) - 40
        insertDay(old, count: 12)
        insertDay(today + 3, count: 12)
        let s = compactAll()
        XCTAssertEqual(s.blocks, 0)
        XCTAssertEqual(rowCount(), 24)
    }

    func testMoreThanTheFormatHoldsKeepsRowsHot() throws {
        // A series-day whose canonical form would exceed the block limit is skipped, rows untouched.
        let key = BlockStore.Key(metric: "hr", sourceRaw: "live", sensorId: ring, day: today - 15)
        XCTAssertNil(AGB.encodeBlock(points: (0...AGB.maxPoints).map { AGBPoint(ts: key.day * AGB.dayMs + Int64($0), value: 60) }, metric: "hr", utcDay: key.day))
    }

    // MARK: Crash safety

    private struct Crash: Error {}

    func testACrashBeforeCommitLosesOnlyTheCurrentChunkAndTheRerunFinishesTheJob() throws {
        insertDay(today - 14, count: 100)
        insertDay(today - 13, count: 100)
        try context.save()
        // Crash while the second series-day is staged (block + ledger written, rows not yet deleted, not committed).
        var calls = 0
        let crashed = StorageMaintenance.compactAll(now: now, context: context, failpoint: { calls += 1; if calls == 2 { throw Crash() } })
        XCTAssertEqual(crashed.blocks, 1)
        XCTAssertEqual(crashed.failures, 1)
        XCTAssertEqual(rowCount(), 100, "the failed chunk's rows are intact")
        XCTAssertEqual(blocks().count, 1, "no half-written block survives the rollback")
        XCTAssertEqual(ledgers().count, 1)
        let rerun = compactAll()
        XCTAssertEqual(rerun.blocks, 1)
        XCTAssertEqual(rowCount(), 0)
        XCTAssertEqual(blocks().count, 2)
        XCTAssertEqual(ledgers().map(\.revision), [1, 1])
    }

    func testAnInterruptedVerifyThenDeleteLeavesRowsWinningAndTheNextPassFinishes() throws {
        let day = today - 16
        let rows = insertDay(day, count: 80)
        try context.save()
        // Stage exactly what an interrupted transaction would leave: the block exists AND the rows still exist.
        let key = BlockStore.Key(metric: "hr", sourceRaw: "live", sensorId: ring, day: day)
        let enc = try XCTUnwrap(AGB.encodeBlock(points: rows.map { AGBPoint(ts: BlockStore.ms($0.timestamp), value: $0.value) }, metric: "hr", utcDay: day))
        BlockStore.store(enc, key: key, sealed: true, context: context, now: now)
        // A row edited after the block was written proves which side the reader trusts.
        rows[0].value = 199
        try context.save()
        let read = MetricsRepository.measurements(kind: .heartRate, start: BlockStore.date(ms: day * AGB.dayMs), end: BlockStore.date(ms: (day + 1) * AGB.dayMs),
                                                  limit: 1000, context: context)
        XCTAssertEqual(read.count, 80, "no double count while both exist")
        XCTAssertEqual(read.first(where: { $0.timestamp == rows[0].timestamp })?.value, 199, "the rows win")
        let s = compactAll()
        XCTAssertEqual(s.blocks, 1)
        XCTAssertEqual(rowCount(), 0)
        XCTAssertEqual(ledgers().first?.revision, 2, "the merged content differs, so the revision moved once")
    }

    // MARK: Reader

    func testTheReaderReturnsTheSamePointsBeforeAndAfterCompaction() throws {
        for d in 1...6 { insertDay(today - 12 - Int64(d), count: 150, value: { Double(55 + ($0 * d) % 50) }) }
        insertDay(today - 2, count: 90)
        try context.save()
        let start = BlockStore.date(ms: (today - 30) * AGB.dayMs), end = now
        func snapshot() -> [String] {
            MetricsRepository.measurements(kind: .heartRate, start: start, end: end, limit: 100_000, context: context)
                .sorted { $0.timestamp < $1.timestamp }.map { "\(BlockStore.ms($0.timestamp))|\($0.value)|\($0.sourceRaw)|\($0.sensorId)" }
        }
        let before = snapshot()
        XCTAssertEqual(before.count, 990)
        XCTAssertGreaterThan(compactAll().blocks, 0)
        XCTAssertEqual(rowCount(), 90, "only the recent day is still a row")
        XCTAssertEqual(snapshot(), before, "same readings, same values, same order")
        XCTAssertEqual(MetricsRepository.measurements(kind: .heartRate, context: context).count, 990)
    }

    func testLatestAndOldestSpanRowsAndBlocks() throws {
        insertDay(today - 30, count: 10)
        try context.save()
        XCTAssertEqual(MetricsRepository.oldestMeasurementTimestamp(context: context), BlockStore.date(ms: (today - 30) * AGB.dayMs + 3_600_000))
        _ = compactAll()
        XCTAssertEqual(rowCount(), 0)
        let latest = try XCTUnwrap(MetricsRepository.latestMeasurement(kind: .heartRate, context: context))
        XCTAssertEqual(latest.timestamp, BlockStore.date(ms: (today - 30) * AGB.dayMs + 3_600_000 + 9 * 5_000), "with no rows left, the newest sealed point is the latest")
        XCTAssertEqual(MetricsRepository.oldestMeasurementTimestamp(context: context), BlockStore.date(ms: (today - 30) * AGB.dayMs + 3_600_000))
        insertDay(today - 1, count: 5)
        let newest = try XCTUnwrap(MetricsRepository.latestMeasurement(kind: .heartRate, context: context))
        XCTAssertEqual(BlockStore.today(now: newest.timestamp), today - 1)
    }

    func testWeekMonthYearZoomUsesTheSummaryColumnsWithoutDecoding() throws {
        let sealedDays = (0..<40).map { today - 12 - Int64($0) }
        for (i, d) in sealedDays.enumerated() { insertDay(d, count: 100, value: { _ in Double(60 + i) }) }
        try context.save()
        _ = compactAll()
        XCTAssertEqual(rowCount(), 0)
        // Poison the payload of every block but keep the summary columns: a stats() over whole days must not notice.
        let originals = blocks().map { ($0, $0.data) }
        for b in blocks() { b.data = Data([0x00]) }
        let lo = sealedDays.min()! * AGB.dayMs, hi = (sealedDays.max()! + 1) * AGB.dayMs
        let stats = MeasurementSeries.stats(metric: "hr", fromMs: lo, toMs: hi, context: context)
        XCTAssertEqual(stats.count, 4000)
        XCTAssertEqual(stats.sum, sealedDays.indices.reduce(0.0) { $0 + Double(60 + $1) * 100 })
        XCTAssertEqual(blocks().filter { $0.state != 0 }.count, 0, "nothing was decoded, so nothing was quarantined")
        for (b, d) in originals { b.data = d }
        let daily = MeasurementSeries.daySummaries(metric: "hr", fromDay: sealedDays.min()!, toDay: sealedDays.max()!, context: context)
        XCTAssertEqual(daily.count, 40)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.n }, 4000)
        // A window that cuts a day in half decodes just that block.
        let half = MeasurementSeries.stats(metric: "hr", fromMs: sealedDays.max()! * AGB.dayMs + 3_600_000 + 50 * 5_000, toMs: hi, context: context)
        XCTAssertEqual(half.count, 50)
    }

    func testSampledAveragesMatchBeforeAndAfterCompactionForUniformDays() throws {
        for i in 0..<45 { insertDay(today - 12 - Int64(i), count: 60, stepMs: 60_000, value: { _ in Double(70 + i) }) }
        try context.save()
        func series(_ range: MetricRange) -> [MetricSample] {
            MetricsService.metricRange(metric: .heartRate, range: range, context: context)
        }
        let beforeMonth = series(.thirtyDays), beforeYear = series(.twelveMonths)
        XCTAssertFalse(beforeYear.isEmpty)
        _ = compactAll()
        XCTAssertEqual(rowCount(), 0)
        let afterMonth = series(.thirtyDays), afterYear = series(.twelveMonths)
        XCTAssertEqual(afterMonth.count, beforeMonth.count)
        XCTAssertEqual(afterYear.count, beforeYear.count)
        for (a, b) in zip(afterYear, beforeYear) { XCTAssertEqual(a.value, b.value, accuracy: 0.6, "a year bucket's mean is the exact mean, the row path samples") }
    }

    // MARK: Late points, merge, deletion

    func testALateRowForASealedDayIsMergedAndBumpsTheRevision() throws {
        let day = today - 25
        insertDay(day, count: 50)
        _ = compactAll()
        let before = try XCTUnwrap(ledgers().first)
        XCTAssertEqual(before.revision, 1)
        let late = Measurement(kind: .heartRate, value: 88, unit: "bpm", timestamp: BlockStore.date(ms: day * AGB.dayMs + 80_000_000), source: .live, sensorId: ring)
        context.insert(late)
        _ = compactAll()
        XCTAssertEqual(rowCount(), 0)
        XCTAssertEqual(try XCTUnwrap(ledgers().first).revision, 2)
        XCTAssertEqual(blocks().first?.n, 51)
        // Merging the same point again changes nothing.
        context.insert(Measurement(kind: .heartRate, value: 88, unit: "bpm", timestamp: late.timestamp, source: .live, sensorId: ring))
        _ = compactAll()
        XCTAssertEqual(try XCTUnwrap(ledgers().first).revision, 2)
    }

    func testDeletingACompactedReadingRewritesTheBlockAndTombstonesIt() throws {
        let day = today - 22
        insertDay(day, count: 30)
        _ = compactAll()
        let all = MetricsRepository.measurements(kind: .heartRate, context: context)
        XCTAssertEqual(all.count, 30)
        XCTAssertNil(all[0].modelContext, "readings from blocks are detached rows")
        let victim = all[7]
        XCTAssertEqual(ReadingDeletion.delete([victim], context: context, now: now), 1)
        XCTAssertEqual(MetricsRepository.measurements(kind: .heartRate, context: context).count, 29)
        XCTAssertEqual(ledgers().first?.revision, 2)
        let ts = BlockStore.ms(victim.timestamp)
        let tomb = try context.fetch(FetchDescriptor<MeasurementDeletion>())
        XCTAssertTrue(tomb.contains { $0.measurementId == "block:hr:live:\(ts)" })
        // A late copy of the deleted point must not come back.
        context.insert(Measurement(kind: .heartRate, value: victim.value, unit: "bpm", timestamp: victim.timestamp, source: .live, sensorId: ring))
        _ = compactAll()
        XCTAssertEqual(MetricsRepository.measurements(kind: .heartRate, context: context).count, 29)
    }

    // MARK: Unreadable blocks

    func testACorruptBlockIsQuarantinedKeptAndNeverAMergeInput() throws {
        let day = today - 18
        insertDay(day, count: 40)
        _ = compactAll()
        let block = try XCTUnwrap(blocks().first)
        var bytes = [UInt8](block.data); bytes[bytes.count - 2] ^= 0xFF
        block.data = Data(bytes)
        let stored = block.data
        XCTAssertTrue(MetricsRepository.measurements(kind: .heartRate, context: context).isEmpty, "a gap, not a crash")
        XCTAssertEqual(block.state, 2)
        XCTAssertNotNil(block.reason)
        XCTAssertNil(block.n)
        XCTAssertEqual(block.data, stored, "bytes are never modified or deleted")
        XCTAssertEqual(ledgers().first?.contentHash, AGB.containerHash(stored), "the ledger identifies an unreadable block by its container")
        XCTAssertFalse(((try? context.fetch(FetchDescriptor<WearableLog>())) ?? []).isEmpty, "logged to WearableLog")
        insertDay(day, count: 3, startMs: 80_000_000)
        let s = compactAll()
        XCTAssertEqual(s.skipped[.blockUnreadable], 1)
        XCTAssertEqual(rowCount(), 3, "the merge with an unreadable block is refused and touches neither input")
    }

    func testABlockFromANewerVersionIsSkippedAsAGapAndRedecodedOnUpgrade() throws {
        let day = today - 19
        insertDay(day, count: 20)
        _ = compactAll()
        let block = try XCTUnwrap(blocks().first)
        let good = block.data
        var newer = [UInt8](good); newer[2] = 2   // format_major 2
        block.data = Data(newer)
        XCTAssertTrue(MetricsRepository.measurements(kind: .heartRate, context: context).isEmpty)
        XCTAssertEqual(block.state, 1)
        XCTAssertEqual(block.reason, "unknown_version")
        block.data = good                          // "a later build can read it"
        XCTAssertEqual(BlockStore.redecodeSkipped(context: context, now: now), 1)
        XCTAssertEqual(block.state, 0)
        XCTAssertEqual(MetricsRepository.measurements(kind: .heartRate, context: context).count, 20)
    }

    func testVerifyRejectsABlockThatDoesNotMatchTheRows() throws {
        let day = today - 15
        let pts = (0..<20).map { AGBPoint(ts: day * AGB.dayMs + Int64($0) * 1000, value: 70) }
        let enc = try XCTUnwrap(AGB.encodeBlock(points: pts, metric: "hr", utcDay: day))
        XCTAssertTrue(BlockStore.verify(enc, points: pts, metric: "hr", day: day))
        var other = pts; other[5].value = 71
        XCTAssertFalse(BlockStore.verify(enc, points: other, metric: "hr", day: day))
        XCTAssertFalse(BlockStore.verify(enc, points: Array(pts.dropLast()), metric: "hr", day: day))
    }

    // MARK: Open-day snapshots

    func testOpenDaysGetADerivedSnapshotAndTheRowsStayTheSourceOfTruth() throws {
        let day = today - 3
        let rows = insertDay(day, count: 40)
        try context.save()
        XCTAssertEqual(try BlockStore.snapshotOpenDays(now: now, context: context), 1)
        var snap = try XCTUnwrap(blocks().first)
        XCTAssertFalse(snap.sealed)
        XCTAssertEqual(ledgers().first?.revision, 1)
        XCTAssertEqual(rowCount(), 40, "rows are not deleted")
        // Unchanged rows: no new snapshot, no revision bump.
        XCTAssertEqual(try BlockStore.snapshotOpenDays(now: now, context: context), 0)
        rows[0].value = 150
        try context.save()
        XCTAssertEqual(try BlockStore.snapshotOpenDays(now: now, context: context), 1)
        snap = try XCTUnwrap(blocks().first)
        XCTAssertEqual(ledgers().first?.revision, 2)
        // Charts never read an open block.
        XCTAssertEqual(MeasurementSeries.points(metric: "hr", from: .distantPast, to: .distantFuture, context: context).count, 0)
        // Sealing later replaces the snapshot from the rows alone (a revised value must not lose to the stale snapshot).
        rows[0].value = 61
        try context.save()
        let later = now.addingTimeInterval(20 * 86_400)
        _ = StorageMaintenance.compactAll(now: later, context: context)
        let sealed = try XCTUnwrap(blocks().first)
        XCTAssertTrue(sealed.sealed)
        XCTAssertEqual(sealed.vMax, 99.0, "the revised 61 replaced the snapshot's 150 (max of the other values is 99)")
        XCTAssertEqual(rowCount(), 0)
    }

    // MARK: Raw packets, identity, history

    func testRawPacketsAreBytesAndTheWindowKeepsPinnedIdentityFrames() throws {
        func add(_ command: Int, hoursAgo: Double) {
            context.insert(RawPacketRecord(timestamp: now.addingTimeInterval(-hoursAgo * 3600), direction: .incoming, commandId: command,
                                           payload: Data([UInt8(command), 1, 2, 3])))
        }
        add(0x03, hoursAgo: 1); add(0x03, hoursAgo: 60)      // 60 h old: outside the 48 h window
        add(0xA1, hoursAgo: 60); add(0xE0, hoursAgo: 24 * 8)  // pinned inside 7 days, gone after
        try context.save()
        StorageMaintenance.pruneRawPacketWindow(now: now, context: context)
        let left = try context.fetch(FetchDescriptor<RawPacketRecord>(sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(left.map(\.commandId).sorted(), [0x03, 0xA1])
        XCTAssertEqual(left.first?.hexPayload, left.first.map { $0.payload.hexString })
        // Row cap: the newest N survive.
        for i in 0..<30 { context.insert(RawPacketRecord(timestamp: now.addingTimeInterval(Double(-i)), direction: .incoming, commandId: 0x10, payload: Data([1]))) }
        try context.save()
        StorageMaintenance.pruneRawPackets(maxRows: 10, context: context)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawPacketRecord>()), 10)
        StorageMaintenance.pruneRawPackets(maxRows: 0, context: context)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawPacketRecord>()), 0)
    }

    func testLegacyHexRowsAreConvertedToBytesOnce() throws {
        context.insert(RawPacketRow(timestamp: now, direction: .incoming, commandId: 0xDF, hexPayload: "df010203"))
        try context.save()
        XCTAssertEqual(StorageMaintenance.convertLegacyRawPackets(context: context), 1)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RawPacketRow>()), 0)
        let converted = try XCTUnwrap(try context.fetch(FetchDescriptor<RawPacketRecord>()).first)
        XCTAssertEqual([UInt8](converted.payload), [0xDF, 1, 2, 3])
        XCTAssertEqual(StorageMaintenance.convertLegacyRawPackets(context: context), 0)
    }

    func testRowsGetTheirSensorIdFromTheLinkOrTheInstall() throws {
        let unknown = AgaraConfig.Storage.sensorUnknownId
        XCTAssertEqual(Measurement(kind: .heartRate, value: 60, unit: "bpm", timestamp: now, source: .live).sensorId, unknown, "before the a1 reply")
        SensorIdentity.shared.setRing(mac: "41:42:06:87:57:41")
        let ringId = try XCTUnwrap(AGB.sensorId(ringMac: "41:42:06:87:57:41"))
        XCTAssertEqual(Measurement(kind: .heartRate, value: 60, unit: "bpm", timestamp: now, source: .live).sensorId, ringId)
        XCTAssertEqual(Measurement(kind: .heartRate, value: 60, unit: "bpm", timestamp: now, source: .history).sensorId, ringId)
        let manual = Measurement(kind: .bloodPressureSystolic, value: 120, unit: "mmHg", timestamp: now, source: .manual)
        XCTAssertEqual(manual.sensorId, SensorIdentity.shared.installSensorId, "phone-sourced rows carry the per-install id")
        XCTAssertNotEqual(manual.sensorId, ringId)
        SensorIdentity.shared.setRing(sensorId: nil)
        XCTAssertEqual(Measurement(kind: .heartRate, value: 60, unit: "bpm", timestamp: now, source: .live).sensorId, unknown, "after a disconnect")
        XCTAssertEqual(SensorIdentity.shared.clientId, SensorIdentity.shared.clientId, "stable per install")
    }

    func testTheA1ReplyYieldsTheRingSensorIdWithoutExposingTheMac() throws {
        var frame = Data(repeating: 0, count: 20)
        frame[0] = 0xA1; frame[3] = 1
        for (i, b) in [0x41, 0x57, 0x87, 0x06, 0x42, 0x41].enumerated() { frame[12 + i] = UInt8(b) }
        let decoder = VeepooDecoder()
        XCTAssertEqual(decoder.ringSensorId(frame: frame), AGB.sensorId(ringMac: "41:42:06:87:57:41"))
        let events = RingEventBridge.events(for: .ringIdentity(sensorId: "aaaaaaaaaaaaaaaa"))
        guard case let .ringIdentified(id)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(id, "aaaaaaaaaaaaaaaa")
        let json = RingDecodedEvent.ringIdentity(sensorId: "aaaaaaaaaaaaaaaa").debugJSON
        XCTAssertNil(json.range(of: #"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"#, options: .regularExpression), "no MAC in diagnostics: \(json)")
    }

    // MARK: Cap ladder

    func testTheLadderStopsAtTheTargetAndAppliesRungsInOrder() {
        var used: Int64 = 300 * 1_048_576
        var state = StorageLadder.State(rawWindowHours: 48, auditDays: 7)
        var applied: [StorageLadder.Rung] = []
        let outcome = StorageLadder.run(used: { used }, capBytes: 250 * 1_048_576, targetPercent: 90, state: &state) { rung in
            applied.append(rung)
            switch rung {
            case .shrinkRawPackets: used -= 40 * 1_048_576
            case .trimAudit: used -= 20 * 1_048_576
            case .clearCaches: used -= 20 * 1_048_576
            case .downsampleDense: used -= 1
            }
        }
        // target = 225 MB: 300 → 260 → 240 → 220 stops after three rungs.
        XCTAssertEqual(applied, [.shrinkRawPackets, .trimAudit, .clearCaches])
        XCTAssertEqual(outcome.stop, .withinTarget)
    }

    func testTheLadderNeverStartsWhenWithinTargetOrWithNoLimit() {
        var state = StorageLadder.State(rawWindowHours: 48, auditDays: 7)
        var calls = 0
        XCTAssertEqual(StorageLadder.run(used: { 100 }, capBytes: 1_000, targetPercent: 90, state: &state, apply: { _ in calls += 1 }).stop, .withinTarget)
        XCTAssertEqual(StorageLadder.run(used: { 10_000 }, capBytes: nil, targetPercent: 90, state: &state, apply: { _ in calls += 1 }).stop, .withinTarget)
        XCTAssertEqual(calls, 0)
    }

    func testProtectedDataRemainsWhenEveryRungIsSpentAndNothingUnsyncedIsDownsampled() {
        var state = StorageLadder.State(rawWindowHours: 48, auditDays: 7)   // syncedDenseBytes = 0: cloud off, all unsynced
        var applied: [StorageLadder.Rung] = []
        let outcome = StorageLadder.run(used: { 999_999_999 }, capBytes: 1_000_000, targetPercent: 90, state: &state) { applied.append($0) }
        XCTAssertEqual(applied, [.shrinkRawPackets, .trimAudit, .clearCaches], "downsampling is only ever offered for synced blocks")
        XCTAssertEqual(outcome.stop, .protectedDataRemains)
        state = StorageLadder.State(rawWindowHours: 0, auditDays: 1, cachesCleared: true, syncedDenseBytes: 5_000_000)
        applied = []
        _ = StorageLadder.run(used: { 999_999_999 }, capBytes: 1_000_000, targetPercent: 90, state: &state) { applied.append($0) }
        XCTAssertEqual(applied, [.downsampleDense])
    }

    func testBannerVerdicts() {
        let mb: Int64 = 1_048_576
        XCTAssertEqual(StorageLadder.banner(usedBytes: 10 * mb, capBytes: 250 * mb, freeDiskBytes: 5_000 * mb), .none)
        XCTAssertEqual(StorageLadder.banner(usedBytes: 260 * mb, capBytes: 250 * mb, freeDiskBytes: 5_000 * mb), .overLimit(usedBytes: 260 * mb, capBytes: 250 * mb))
        XCTAssertEqual(StorageLadder.banner(usedBytes: 260 * mb, capBytes: nil, freeDiskBytes: 5_000 * mb), .none)
        XCTAssertEqual(StorageLadder.banner(usedBytes: 1, capBytes: 250 * mb, freeDiskBytes: 400 * mb), .lowDisk(freeBytes: 400 * mb))
        XCTAssertEqual(StorageLadder.banner(usedBytes: 1, capBytes: 250 * mb, freeDiskBytes: 90 * mb), .criticalDisk(freeBytes: 90 * mb))
        XCTAssertFalse(StorageLadder.canOptimize(freeDiskBytes: 400 * mb, batteryLevel: 0.9, charging: false), "low disk")
        XCTAssertFalse(StorageLadder.canOptimize(freeDiskBytes: 5_000 * mb, batteryLevel: 0.15, charging: false), "battery < 20 % and not charging")
        XCTAssertTrue(StorageLadder.canOptimize(freeDiskBytes: 5_000 * mb, batteryLevel: 0.15, charging: true))
        XCTAssertTrue(StorageLadder.canOptimize(freeDiskBytes: 5_000 * mb, batteryLevel: -1, charging: false), "unknown battery level")
    }

    func testStoragePrefsUseTheCatalogDefaultsAndChoices() {
        let defaults = UserDefaults(suiteName: "storage-prefs-test")!
        defaults.removePersistentDomain(forName: "storage-prefs-test")
        let prefs = StoragePrefs(defaults: defaults)
        XCTAssertEqual(prefs.capMb, AgaraConfig.Storage.capDefaultMb)
        XCTAssertEqual(prefs.capBytes, 250 * 1_048_576)
        XCTAssertEqual(StoragePrefs.capOptionsMb, [100, 250, 500, 1000, 0])
        XCTAssertEqual(StoragePrefs.retentionOptionsDays, [0, 365, 180, 90])
        prefs.capMb = 0
        XCTAssertNil(prefs.capBytes, "0 = no limit")
    }
}
