import XCTest
import SwiftData
@testable import PulseLoop

private typealias Measurement = PulseLoop.Measurement

/// Storage plumbing that needs a real on-disk store: the usage meter (`dbstat`), the maintenance owner ("Optimize now"),
/// persistent-history purge, the archive round trip over compacted readings, and the low-disk guards.
@MainActor
final class StorageCenterTests: XCTestCase {
    private var dir: URL!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        container = try ModelContainerFactory.make(url: dir.appendingPathComponent("default.store"))
        context = ModelContext(container)
        StorageGuard.set(freeBytes: .max)
        SensorIdentity.shared.reset()
        ReadingDeletion.invalidate()
    }

    override func tearDown() {
        StorageGuard.probe = { StorageMeter.freeDiskBytes() }
        StorageGuard.set(freeBytes: .max)
        try? FileManager.default.removeItem(at: dir)
    }

    private var storeURL: URL { dir.appendingPathComponent("default.store") }

    /// Readings every `stepSeconds` for `days` days ending `daysAgo` days before now.
    private func seed(daysAgo: Int, days: Int = 1, perDay: Int = 400, kind: MeasurementKind = .heartRate) {
        let start = Date().addingTimeInterval(-Double(daysAgo + days) * 86_400)
        for d in 0..<days {
            for i in 0..<perDay {
                context.insert(Measurement(kind: kind, value: Double(55 + (i + d) % 60), unit: kind.unit,
                                           timestamp: start.addingTimeInterval(Double(d) * 86_400 + 3_600 + Double(i) * 30),
                                           source: .live, sensorId: "a3a04cab4846d63c"))
            }
        }
        try? context.save()
    }

    // MARK: Classification

    func testDbstatNamesMapToTheRightClass() {
        let cases: [(String, StorageClass)] = [
            ("ZMEASUREMENT", .healthReadings), ("Z_Measurement_UNIQUE_id", .healthReadings),
            ("Z_Measurement_SwiftDataIndexOnBinarykindRawtimestamp", .healthReadings),
            ("ZMEASUREMENTBLOCK", .healthReadings), ("Z_MeasurementBlock_UNIQUE_blockKey", .healthReadings), ("ZBLOCKSYNC", .healthReadings),
            ("ZACTIVITYDAILY", .dailySummaries), ("ZSLEEPSESSION", .dailySummaries),
            ("ZACTIVITYGPSPOINT", .workouts), ("ZACTIVITYSESSION", .workouts),
            ("ZCOACHMESSAGE", .coach), ("Z_CoachMessage_UNIQUE_id", .coach),
            ("ZRAWPACKETRECORD", .diagnostics), ("ZRAWPACKETROW", .diagnostics), ("ZWEARABLELOG", .diagnostics),
            ("ACHANGE", .diagnostics), ("ATRANSACTION", .diagnostics), ("ACHANGE_ZTRANSACTIONID_INDEX", .diagnostics),
            ("Z_TRANSACTION_TransactionTimestampIndex", .diagnostics),
            ("ZCACHEDFOODPRODUCT", .caches), ("sqlite_schema", .other), ("Z_MODELCACHE", .other), ("Z_PRIMARYKEY", .other),
        ]
        for (name, expected) in cases { XCTAssertEqual(StorageClass.classify(objectName: name), expected, name) }
    }

    // MARK: The meter

    func testTheMeterReadsPerClassSizesFromDbstatAndFreePages() throws {
        seed(daysAgo: 3, days: 2, perDay: 800)
        for i in 0..<300 { context.insert(RawPacketRecord(timestamp: Date().addingTimeInterval(Double(-i)), direction: .incoming, commandId: 0x03, payload: Data(repeating: 7, count: 20))) }
        try context.save()
        let usage = StorageMeter.measure(storeURL: storeURL)
        XCTAssertTrue(usage.exact, "dbstat is compiled into the iOS SQLite (the plan's open question)")
        XCTAssertGreaterThan(usage.bytes(.healthReadings), 100_000)
        XCTAssertGreaterThan(usage.bytes(.diagnostics), 10_000)
        XCTAssertGreaterThan(usage.fileBytes, 0)
        XCTAssertGreaterThan(usage.freeDiskBytes, 0)
        XCTAssertLessThanOrEqual(usage.usedBytes, usage.fileBytes + 512 * 1024, "class sizes account for the file")
        // Deleting most rows frees pages inside the file; the meter reports them as reclaimable, not as usage.
        try context.delete(model: Measurement.self)
        try context.save()
        let after = StorageMeter.measure(storeURL: storeURL)
        XCTAssertLessThan(after.bytes(.healthReadings), usage.bytes(.healthReadings) / 4)
    }

    func testAMissingStoreFallsBackToTheEstimateAndSaysSo() {
        let usage = StorageMeter.measure(storeURL: dir.appendingPathComponent("nope.store"), fallbackEstimate: { [.healthReadings: 1234] })
        XCTAssertFalse(usage.exact)
        XCTAssertEqual(usage.bytes(.healthReadings), 1234)
    }

    // MARK: Persistent history

    func testPersistentHistoryOlderThanTheRetentionIsPurged() throws {
        seed(daysAgo: 30, perDay: 50)
        let before = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).count
        XCTAssertGreaterThan(before, 0, "SwiftData records every save in persistent history")
        // Inside the retention window nothing goes.
        XCTAssertTrue(StorageMaintenance.purgePersistentHistory(now: Date(), context: context))
        XCTAssertEqual(try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).count, before)
        // A day past the window it all does.
        XCTAssertTrue(StorageMaintenance.purgePersistentHistory(now: Date().addingTimeInterval(2 * 86_400), context: context))
        XCTAssertEqual(try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).count, 0)
    }

    // MARK: Optimize now, end to end on a file store

    func testOptimizeNowCompactsInTheBackgroundAndReportsProgressOnTheSyncProgressModel() async throws {
        seed(daysAgo: 20, days: 5, perDay: 400)
        seed(daysAgo: 1, days: 1, perDay: 100)
        let center = StorageCenter()
        center.defaults = UserDefaults(suiteName: "storage-center-test-\(UUID().uuidString)")!
        center.attach(container: container)
        await center.refreshUsage()
        let before = try XCTUnwrap(center.usage)
        XCTAssertNil(center.lastRunAt)
        center.optimizeNow()
        XCTAssertTrue(center.isRunning)
        XCTAssertEqual(SyncProgress.shared.job?.title, "Optimizing storage", "progress rides the one sync-progress model")
        await center.waitForIdle()
        XCTAssertFalse(center.isRunning)
        XCTAssertNil(SyncProgress.shared.job)
        let report = try XCTUnwrap(center.lastReport)
        XCTAssertEqual(report.blocksCompacted, 5)
        XCTAssertEqual(report.rowsCompacted, 2000)
        XCTAssertEqual(report.failures, 0)
        XCTAssertNotNil(center.lastRunAt)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Measurement>()), 100, "only the recent day is still rows")
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.sealed == true })), 5)
        let after = try XCTUnwrap(center.usage)
        XCTAssertLessThan(after.bytes(.healthReadings), before.bytes(.healthReadings))
        // Not due again inside the interval.
        center.runIfDue()
        XCTAssertFalse(center.isRunning)
    }

    // MARK: Backup and restore over compacted readings

    func testAnExportStillCarriesCompactedReadingsAndImportsThemBack() async throws {
        seed(daysAgo: 25, days: 3, perDay: 200)
        seed(daysAgo: 2, days: 1, perDay: 50)
        let originals = try context.fetch(FetchDescriptor<Measurement>()).map { BlockStore.ms($0.timestamp) }.sorted()
        XCTAssertEqual(originals.count, 650)
        var options = StorageMaintenance.Options(); options.runLadder = false
        let report = StorageMaintenance.run(now: Date(), context: context, options: options)
        XCTAssertEqual(report.blocksCompacted, 3)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Measurement>()), 50)

        let defaults = UserDefaults(suiteName: "storage-export-\(UUID().uuidString)")!
        let attachments = dir.appendingPathComponent("att", isDirectory: true)
        let data = try await DataArchiveService.exportArchive(context: context, defaults: defaults, attachmentsDirectory: attachments)
        // Import into a fresh store (replace-all) and compare.
        let other = try ModelContainerFactory.make(inMemory: true)
        let target = ModelContext(other)
        try await DataArchiveService.importArchive(data, context: target, defaults: defaults, attachmentsDirectory: attachments, refreshStores: false)
        let restored = try target.fetch(FetchDescriptor<Measurement>()).map { BlockStore.ms($0.timestamp) }.sorted()
        XCTAssertEqual(restored, originals, "every reading is in the backup, compacted or not")
        XCTAssertTrue(try target.fetch(FetchDescriptor<Measurement>()).allSatisfy { $0.sensorId == AgaraConfig.Storage.sensorUnknownId },
                      "imported rows carry the unknown sensor id")
    }

    // MARK: Low disk

    func testLowDiskStopsRawCaptureAndCriticalDiskPausesCachesAndRefusesImport() async throws {
        StorageGuard.set(freeBytes: 600 * 1_048_576)
        XCTAssertFalse(StorageGuard.isLowDisk)
        StorageGuard.set(freeBytes: 400 * 1_048_576)
        XCTAssertTrue(StorageGuard.isLowDisk); XCTAssertFalse(StorageGuard.isCriticalDisk)
        XCTAssertFalse(RawPacketCapture.isEnabled, "capture stops below storage_low_disk_free_mb")

        StorageGuard.set(freeBytes: 50 * 1_048_576)
        StorageGuard.probe = { 50 * 1_048_576 }   // the import re-reads the disk before it starts
        XCTAssertTrue(StorageGuard.isCriticalDisk)
        let product = FoodProduct(code: "123", name: "Test", brand: nil, energyKcal100g: 1, protein100g: 1, carbs100g: 1, fat100g: 1,
                                  fiber100g: nil, sugars100g: nil, saturatedFat100g: nil, sodiumMg100g: nil, servingSizeText: nil, servingQuantityG: nil)
        _ = NutritionRepository.upsertCachedProduct(product, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CachedFoodProduct>()), 0, "caches pause on a critical disk")
        do {
            try await DataArchiveService.importArchive(Data("{}".utf8), context: context, refreshStores: false)
            XCTFail("import must be refused")
        } catch let error as DataArchiveError {
            guard case .insufficientStorage = error else { return XCTFail("\(error)") }
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testMaintenanceNeverRunsInsideTheHotWindowEvenWhenAsked() throws {
        seed(daysAgo: AgaraConfig.Ring.historyWindowDays, days: 1, perDay: 100)   // inside the ring's own history window
        let report = StorageMaintenance.run(now: Date(), context: context)
        XCTAssertEqual(report.blocksCompacted, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Measurement>()), 100)
    }
}
