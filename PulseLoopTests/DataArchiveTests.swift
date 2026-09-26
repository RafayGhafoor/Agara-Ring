import XCTest
import SwiftData
@testable import PulseLoop

/// Locks down the full-app export/import archive: a complete round trip over all 24 models,
/// wipe completeness, version/corruption rejection (without data loss), and the settings +
/// attachment side channels. Hermetic — in-memory SwiftData, suite-scoped UserDefaults, temp dirs.
@MainActor
final class DataArchiveTests: XCTestCase {

    // MARK: - Helpers

    private func count<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    /// One row of every model type `SeedData.seedDemo` does NOT create, so seed + these = all 24.
    private func insertModelsMissingFromSeed(_ context: ModelContext, deviceId: UUID) {
        context.insert(BatterySample(percent: 57, timestamp: Date(timeIntervalSince1970: 1_750_000_000)))
        context.insert(DeviceMeasurementConfig(deviceId: deviceId))
        let bucket = ActivityBucketSample(
            timestamp: Date(timeIntervalSince1970: 1_750_000_900),
            steps: 123,
            distanceMeters: 88,
            source: "ring_history"
        )
        // Diverge the stored unique key from what the init derives from the timestamp, so the
        // round-trip test proves the importer restores the STORED value instead of re-deriving it.
        bucket.startEpoch += 7
        context.insert(bucket)
        context.insert(ActivitySensorPollEvent(sessionId: UUID(), kind: "hr", status: "success", value: 62))
        context.insert(CoachMemory(key: "prefers", value: "morning runs"))
        context.insert(CoachToolCall(conversationId: UUID(), toolName: "get_hr", label: "Got HR data"))
        context.insert(CoachNotificationRecord(slotRaw: "morning", dateKey: "2026-07-25", title: "Hi", body: "Check in"))
        context.insert(CoachSummary(kind: "today", scopeKey: "2026-07-25", title: "Today", body: "Solid", dataSignature: "sig1"))
        context.insert(WearableLog(category: .sync, level: .info, message: "sync done", metadataJSON: #"{"n":1}"#))
        context.insert(MealEntry(timestamp: Date(timeIntervalSince1970: 1_750_000_000), name: "Toast", mealType: .breakfast, calories: 210))
        context.insert(CachedFoodProduct(code: "123", name: "Bread", energyKcal100g: 250))
        try? context.save()
    }

    private func assertAllCountsEqual(_ a: ModelContext, _ b: ModelContext, file: StaticString = #filePath, line: UInt = #line) {
        func check<T: PersistentModel>(_ type: T.Type) {
            XCTAssertEqual(count(type, a), count(type, b), "\(T.self) count mismatch", file: file, line: line)
            XCTAssertGreaterThan(count(type, b), 0, "\(T.self) should have rows in this test", file: file, line: line)
        }
        check(Device.self); check(ActivityDaily.self); check(PulseLoop.Measurement.self)
        check(BatterySample.self); check(SleepSession.self); check(SleepStageBlock.self)
        check(RawPacketRow.self); check(DerivedUpdateRow.self); check(UserProfile.self)
        check(UserGoal.self); check(DeviceMeasurementConfig.self); check(ActivitySession.self)
        check(ActivitySample.self); check(ActivityBucketSample.self); check(ActivityGpsPoint.self)
        check(ActivityEvent.self); check(ActivitySensorPollEvent.self); check(CoachConversation.self)
        check(CoachMessage.self); check(CoachMemory.self); check(CoachToolCall.self)
        check(CoachNotificationRecord.self); check(CoachSummary.self); check(WearableLog.self)
        check(MealEntry.self); check(CachedFoodProduct.self)
    }

    private func makeSuiteDefaults(_ name: String) -> UserDefaults {
        let suite = "DataArchiveTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Round trip

    func testRoundTripRestoresEverything() async throws {
        let source = try TestSupport.makeContext()
        SeedData.seedDemo(source, completeOnboarding: true)
        let device = try XCTUnwrap(try source.fetch(FetchDescriptor<Device>()).first)
        insertModelsMissingFromSeed(source, deviceId: device.id)

        // Snapshot reference values before export.
        let sourceMeasurements = try source.fetch(FetchDescriptor<PulseLoop.Measurement>(sortBy: [SortDescriptor(\.timestamp)]))
        let referenceMeasurement = try XCTUnwrap(sourceMeasurements.first)
        let refID = referenceMeasurement.id
        let refKind = referenceMeasurement.kindRaw
        let refValue = referenceMeasurement.value
        let refTimestamp = referenceMeasurement.timestamp
        let refCapabilities = device.capabilitiesRaw
        let refBucketEpoch = try XCTUnwrap(try source.fetch(FetchDescriptor<ActivityBucketSample>()).first).startEpoch

        let defaults = makeSuiteDefaults(#function)
        let attachmentsDir = try makeTempDirectory()
        let data = try await DataArchiveService.exportArchive(
            context: source, defaults: defaults, attachmentsDirectory: attachmentsDir, includeRawPackets: true
        )

        // Import into a completely fresh store.
        let target = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(
            data, context: target, defaults: defaults,
            attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )

        assertAllCountsEqual(source, target)

        // Spot-check field-level fidelity: exact UUID, raw strings, ms-tolerant dates.
        let imported = try target.fetch(FetchDescriptor<PulseLoop.Measurement>(predicate: #Predicate { $0.id == refID }))
        let importedMeasurement = try XCTUnwrap(imported.first, "reference measurement must survive with its UUID")
        XCTAssertEqual(importedMeasurement.kindRaw, refKind)
        XCTAssertEqual(importedMeasurement.value, refValue)
        XCTAssertEqual(importedMeasurement.timestamp.timeIntervalSince1970, refTimestamp.timeIntervalSince1970, accuracy: 0.005)

        let importedDevice = try XCTUnwrap(try target.fetch(FetchDescriptor<Device>()).first)
        XCTAssertEqual(importedDevice.id, device.id)
        XCTAssertEqual(importedDevice.capabilitiesRaw, refCapabilities)

        // startEpoch is the bucket's unique upsert key. The fixture deliberately stores a value
        // that differs from what the init would re-derive from the timestamp, so this fails if
        // the importer ever drops the explicit restore.
        let importedBucket = try XCTUnwrap(try target.fetch(FetchDescriptor<ActivityBucketSample>()).first)
        XCTAssertEqual(importedBucket.startEpoch, refBucketEpoch)
        XCTAssertNotEqual(importedBucket.startEpoch, Int(importedBucket.timestamp.timeIntervalSince1970))

        // FK integrity: every child row still points at a parent that exists.
        let sessionIDs = Set(try target.fetch(FetchDescriptor<SleepSession>()).map(\.id))
        for block in try target.fetch(FetchDescriptor<SleepStageBlock>()) {
            XCTAssertTrue(sessionIDs.contains(block.sessionId), "orphaned SleepStageBlock after import")
        }
        let conversationIDs = Set(try target.fetch(FetchDescriptor<CoachConversation>()).map(\.id))
        for message in try target.fetch(FetchDescriptor<CoachMessage>()) {
            XCTAssertTrue(conversationIDs.contains(message.conversationId), "orphaned CoachMessage after import")
        }
    }

    // MARK: - Wipe completeness

    func testWipeAllDataCoversAllModels() async throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true)
        let device = try XCTUnwrap(try context.fetch(FetchDescriptor<Device>()).first)
        insertModelsMissingFromSeed(context, deviceId: device.id)

        try DataArchiveService.wipeAllData(context: context)
        try context.save()

        func assertEmpty<T: PersistentModel>(_ type: T.Type) {
            XCTAssertEqual(count(type, context), 0, "\(T.self) survived wipeAllData")
        }
        assertEmpty(Device.self); assertEmpty(ActivityDaily.self); assertEmpty(PulseLoop.Measurement.self)
        assertEmpty(BatterySample.self); assertEmpty(SleepSession.self); assertEmpty(SleepStageBlock.self)
        assertEmpty(RawPacketRow.self); assertEmpty(DerivedUpdateRow.self); assertEmpty(UserProfile.self)
        assertEmpty(UserGoal.self); assertEmpty(DeviceMeasurementConfig.self); assertEmpty(ActivitySession.self)
        assertEmpty(ActivitySample.self); assertEmpty(ActivityBucketSample.self); assertEmpty(ActivityGpsPoint.self)
        assertEmpty(ActivityEvent.self); assertEmpty(ActivitySensorPollEvent.self); assertEmpty(CoachConversation.self)
        assertEmpty(CoachMessage.self); assertEmpty(CoachMemory.self); assertEmpty(CoachToolCall.self)
        assertEmpty(CoachNotificationRecord.self); assertEmpty(CoachSummary.self); assertEmpty(WearableLog.self)
    }

    // MARK: - Rejection without data loss

    func testImportRejectsNewerFormatVersion() async throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: Date(), into: context)
        let before = count(PulseLoop.Measurement.self, context)

        let newer = Data(#"{"formatVersion": 999}"#.utf8)
        do {
            try await DataArchiveService.importArchive(newer, context: context, refreshStores: false)
            XCTFail("expected unsupportedVersion")
        } catch let DataArchiveError.unsupportedVersion(found, supported) {
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, AgaraArchive.currentFormatVersion)
        }
        XCTAssertEqual(count(PulseLoop.Measurement.self, context), before, "a rejected file must not touch existing data")
    }

    func testImportRejectsCorruptJSONWithoutDataLoss() async throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: Date(), into: context)
        let before = count(PulseLoop.Measurement.self, context)

        // Not JSON at all.
        do {
            try await DataArchiveService.importArchive(Data("not json".utf8), context: context, refreshStores: false)
            XCTFail("expected invalidFile")
        } catch DataArchiveError.invalidFile {
            // expected
        }

        // Valid JSON, right version, but not an archive (truncated).
        do {
            try await DataArchiveService.importArchive(Data(#"{"formatVersion": 1}"#.utf8), context: context, refreshStores: false)
            XCTFail("expected invalidFile")
        } catch DataArchiveError.invalidFile {
            // expected
        }

        XCTAssertEqual(count(PulseLoop.Measurement.self, context), before)
    }

    // MARK: - Settings blobs

    func testSettingsBlobsRoundTrip() async throws {
        let source = try TestSupport.makeContext()
        let exportDefaults = makeSuiteDefaults("export")
        var prefs = MetricPrefs.default
        prefs.hiddenMetrics = ["stress", "hrv"]
        prefs.resolution = .coarse
        let blob = try JSONEncoder().encode(prefs)
        exportDefaults.set(blob, forKey: "pulseloop.metricprefs.v1")

        let data = try await DataArchiveService.exportArchive(
            context: source, defaults: exportDefaults, attachmentsDirectory: try makeTempDirectory()
        )

        let importDefaults = makeSuiteDefaults("import")
        // Pre-set a key the archive doesn't carry: import must clear it back to defaults.
        importDefaults.set(Data("{}".utf8), forKey: "pulseloop.calibration.v1")
        try await DataArchiveService.importArchive(
            data, context: try TestSupport.makeContext(), defaults: importDefaults,
            attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )

        XCTAssertEqual(importDefaults.data(forKey: "pulseloop.metricprefs.v1"), blob, "settings blob must restore byte-identical")
        XCTAssertNil(importDefaults.data(forKey: "pulseloop.calibration.v1"), "keys absent from the archive must reset")
    }

    // MARK: - Attachments

    func testAttachmentsRoundTrip() async throws {
        let sourceDir = try makeTempDirectory()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        try bytes.write(to: sourceDir.appendingPathComponent("photo-a.jpg"))

        let data = try await DataArchiveService.exportArchive(
            context: try TestSupport.makeContext(), defaults: makeSuiteDefaults("attach"), attachmentsDirectory: sourceDir
        )

        let targetDir = try makeTempDirectory()
        // A stale file from the pre-import dataset must not survive the restore.
        try Data([0x00]).write(to: targetDir.appendingPathComponent("stale.jpg"))
        try await DataArchiveService.importArchive(
            data, context: try TestSupport.makeContext(), defaults: makeSuiteDefaults("attach2"),
            attachmentsDirectory: targetDir, refreshStores: false
        )

        XCTAssertEqual(try Data(contentsOf: targetDir.appendingPathComponent("photo-a.jpg")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("stale.jpg").path))
    }

    // MARK: - gzip framing (audit Batch B: streamed .json.gz like Android)

    func testCrc32MatchesTheStandardCheckValue() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Gzip.crc32(Data()), 0)
        // Running checksum over two halves == one pass.
        let a = Data("12345".utf8), b = Data("6789".utf8)
        XCTAssertEqual(Gzip.crc32(b, seed: Gzip.crc32(a)), 0xCBF4_3926)
    }

    func testGzipHeaderTrailerAndBodyAreStandard() throws {
        let input = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 7)) })
        let gz = try Gzip.compress(input)
        let bytes = [UInt8](gz)
        XCTAssertEqual(Array(bytes.prefix(3)), [0x1F, 0x8B, 0x08], "gzip magic + deflate method")
        XCTAssertTrue(Gzip.isGzip(gz))
        func le32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        XCTAssertEqual(le32(bytes.count - 8), Gzip.crc32(input), "trailer CRC-32")
        XCTAssertEqual(le32(bytes.count - 4), UInt32(input.count), "trailer ISIZE")
        // The body is plain raw DEFLATE: an independent decoder (NSData's) reads it.
        let body = Data(bytes[10..<(bytes.count - 8)])
        let inflated = try (body as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(inflated, input)
        XCTAssertEqual(try Gzip.decompress(gz), input)
        XCTAssertLessThan(gz.count, input.count)
    }

    func testGzipDecompressRejectsDamage() throws {
        var gz = try Gzip.compress(Data(repeating: 0x41, count: 1000))
        gz[gz.count - 5] ^= 0xFF                      // CRC byte
        XCTAssertThrowsError(try Gzip.decompress(gz)) { XCTAssertEqual($0 as? Gzip.Failure, .checksumMismatch) }
        let short = try Gzip.compress(Data("abc".utf8)).prefix(12)
        XCTAssertThrowsError(try Gzip.decompress(Data(short)))
    }

    func testStreamedFileSinkMatchesOneShot() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("a.json.gz")
        let sink = try GzipFileSink(url: url)
        var all = Data()
        for i in 0..<300 {                            // many small writes, like the row-by-row export
            let chunk = Data("{\"row\":\(i),\"pad\":\"\(String(repeating: "x", count: i % 97))\"},".utf8)
            try sink.write(chunk)
            all.append(chunk)
        }
        try sink.finish()
        XCTAssertEqual(try Gzip.decompress(try Data(contentsOf: url)), all)
    }

    // MARK: - Export file, cleanup, options

    func testExportFileIsGzipAndReplacesEarlierExports() async throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true)
        let tmp = FileManager.default.temporaryDirectory
        let legacy = tmp.appendingPathComponent("pulseloop-export-2020-01-01-0000.json")
        try Data("{}".utf8).write(to: legacy)
        let first = try await DataArchiveService.exportFile(context: context)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("agara-export-"))
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".json.gz"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy temp export not deleted")
        let stale = first.deletingLastPathComponent().appendingPathComponent("agara-diagnostics-old.json")
        try Data("{}".utf8).write(to: stale)

        let second = try await DataArchiveService.exportFile(context: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "earlier export/diagnostics file kept")
        let data = try Data(contentsOf: second)
        XCTAssertEqual(Array(data.prefix(2)), [0x1F, 0x8B])

        let target = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(
            data, context: target, defaults: makeSuiteDefaults(#function),
            attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )
        XCTAssertEqual(count(PulseLoop.Measurement.self, target), count(PulseLoop.Measurement.self, context))
        XCTAssertEqual(count(SleepStageBlock.self, target), count(SleepStageBlock.self, context))
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    func testRawPacketsAreOptIn() async throws {
        let context = try TestSupport.makeContext()
        context.insert(RawPacketRow(timestamp: Date(), direction: .incoming, commandId: 0xDF, hexPayload: "df00"))
        try context.save()
        let dir = try makeTempDirectory()
        func json(_ include: Bool) async throws -> [String: Any] {
            let data = try await DataArchiveService.exportArchive(
                context: context, defaults: makeSuiteDefaults("raw\(include)"), attachmentsDirectory: dir,
                includeRawPackets: include
            )
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let plain = try await json(false)
        XCTAssertEqual((plain["rawPackets"] as? [Any])?.count, 0)
        XCTAssertEqual((plain["counts"] as? [String: Int])?["raw_packets"], 0)
        let withPackets = try await json(true)
        XCTAssertEqual((withPackets["rawPackets"] as? [Any])?.count, 1)
        XCTAssertEqual((withPackets["counts"] as? [String: Int])?["raw_packets"], 1)
    }

    /// The JSON is Android's `AgaraArchive`: its keys in its order, epoch-ms timestamps, enum names.
    func testExportUsesAndroidArchiveLayout() async throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true)
        let device = try XCTUnwrap(try context.fetch(FetchDescriptor<Device>()).first)
        insertModelsMissingFromSeed(context, deviceId: device.id)
        context.insert(CoachMessage(conversationId: UUID(), role: "user", body: "hi", attachmentsJSON: "[]"))
        try context.save()
        let data = try await DataArchiveService.exportArchive(
            context: context, defaults: makeSuiteDefaults(#function), attachmentsDirectory: try makeTempDirectory()
        )
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let androidKeys = [
            "formatVersion", "exportedAt", "appVersion", "counts", "devices", "measurements", "activityDaily",
            "activityBuckets", "batterySamples", "deviceMeasurementConfigs", "activitySessions", "activityGpsPoints",
            "activityEvents", "activitySamples", "activitySensorPolls", "sleepSessions", "sleepStageBlocks",
            "coachConversations", "coachMessages", "coachMemories", "coachToolCalls", "userProfiles", "userGoals",
            "rawPackets", "derivedUpdates", "coachSummaries", "wearableLogs", "coachNotificationRecords",
            "mealEntries", "foodProducts", "measurementDeletions",
        ]
        XCTAssertEqual(Set(root.keys), Set(androidKeys + ["settings", "attachments"]))
        // Table order in the file = AgaraArchive declaration order; counts last.
        let text = String(decoding: data, as: UTF8.self)
        let positions = androidKeys.dropFirst(4).compactMap { text.range(of: "\"\($0)\":[")?.lowerBound }
        XCTAssertEqual(positions.count, androidKeys.count - 4)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(text.hasSuffix("}}"), "counts object closes the document")

        XCTAssertTrue(root["exportedAt"] is NSNumber, "timestamps are epoch-ms numbers")
        let measurement = try XCTUnwrap((root["measurements"] as? [[String: Any]])?.first)
        XCTAssertTrue(measurement["timestamp"] is NSNumber)
        let kinds = Set(((root["measurements"] as? [[String: Any]]) ?? []).compactMap { $0["kindRaw"] as? String })
        XCTAssertTrue(kinds.contains("HEART_RATE"), "\(kinds)")
        XCTAssertFalse(kinds.contains("hr"))
        let bucket = try XCTUnwrap((root["activityBuckets"] as? [[String: Any]])?.first)
        let bucketMs = try XCTUnwrap((bucket["startEpoch"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(bucketMs, 100_000_000_000, "bucket key is epoch ms")
        let stage = try XCTUnwrap((root["sleepStageBlocks"] as? [[String: Any]])?.first?["stageRaw"] as? String)
        XCTAssertEqual(stage, stage.uppercased())
        let session = try XCTUnwrap((root["sleepSessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(session["sourceRaw"] as? String, "ring")
        let messages = try XCTUnwrap(root["coachMessages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { $0["attachmentsJson"] as? String == "[]" })
        XCTAssertFalse(messages.contains { $0["attachmentsJSON"] != nil })
        let log = try XCTUnwrap((root["wearableLogs"] as? [[String: Any]])?.first)
        XCTAssertEqual(log["event"] as? String, "sync done")
        XCTAssertEqual(log["categoryRaw"] as? String, "SYNC")
        XCTAssertEqual(log["levelRaw"] as? String, "INFO")
        XCTAssertNil(log["message"])
        let counts = try XCTUnwrap(root["counts"] as? [String: Int])
        XCTAssertEqual(counts["measurements"], (root["measurements"] as? [Any])?.count)
        XCTAssertNotNil(counts["activity_daily"])
    }

    // MARK: - Cross-platform + legacy import

    /// An archive framed exactly as Android's `ArchiveCodec.write` + `GZIPOutputStream` produce it (compact
    /// JSON in `AgaraArchive` order, every field present, epoch-ms Longs, enum names, counts last). Built by
    /// following the Kotlin code field by field with Python's json + gzip (Android-side ids are UUID strings,
    /// raw-packet ids integers; `recordStartAt` 0 and meal `updatedAt` 0 are Android's "unknown").
    private static let androidArchiveBase64 = [
        "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",
        "Mj8PgxWZQtN/evoPfq1W4oUXAAA=",
    ].joined()

    func testImportsAnAndroidArchive() async throws {
        let gz = try XCTUnwrap(Data(base64Encoded: Self.androidArchiveBase64))
        XCTAssertTrue(Gzip.isGzip(gz))
        let context = try TestSupport.makeContext()
        let defaults = makeSuiteDefaults(#function)
        let prefs = Data(#"{"keep":true}"#.utf8)
        defaults.set(prefs, forKey: "pulseloop.metricprefs.v1")
        let attachments = try makeTempDirectory()
        try Data([1]).write(to: attachments.appendingPathComponent("keep.jpg"))

        try await DataArchiveService.importArchive(
            gz, context: context, defaults: defaults, attachmentsDirectory: attachments, refreshStores: false
        )

        let t0 = Date(timeIntervalSince1970: 1_790_400_000)
        let device = try XCTUnwrap(try context.fetch(FetchDescriptor<Device>()).first)
        XCTAssertEqual(device.nickname, "Left hand")
        XCTAssertEqual(device.id, UUID(uuidString: "0b9f3c1e-8a4d-4f6e-9c2b-1d7e5a3f8b20"))
        XCTAssertEqual(device.updatedAt, t0)

        let measurements = try context.fetch(FetchDescriptor<PulseLoop.Measurement>(sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(measurements.map(\.kindRaw), ["hr", "spo2"], "Android enum names map to iOS kinds")
        XCTAssertEqual(measurements.first?.value, 72)
        XCTAssertEqual(measurements.first?.timestamp, t0.addingTimeInterval(-3600))
        let packet = try XCTUnwrap(try context.fetch(FetchDescriptor<RawPacketRow>()).first)
        XCTAssertEqual(measurements.first?.rawPacketId, packet.id, "integer raw-packet id maps consistently")
        XCTAssertEqual(packet.id, ArchiveInterop.uuid("42"))

        let daily = try XCTUnwrap(try context.fetch(FetchDescriptor<ActivityDaily>()).first)
        XCTAssertEqual(daily.steps, 8421)
        XCTAssertEqual(daily.estimatedActiveCalories, 280)
        let bucket = try XCTUnwrap(try context.fetch(FetchDescriptor<ActivityBucketSample>()).first)
        XCTAssertEqual(bucket.startEpoch, 1_790_400_000 - 900, "ms bucket key → unix seconds")
        XCTAssertEqual(bucket.timestamp, t0.addingTimeInterval(-900))

        let blocks = try context.fetch(FetchDescriptor<SleepStageBlock>(sortBy: [SortDescriptor(\.startMinute)]))
        XCTAssertEqual(blocks.map(\.stageRaw), ["light", "deep"])
        XCTAssertNotNil(blocks.first?.recordStartAt)
        XCTAssertNil(blocks.last?.recordStartAt, "Android's 0 = unknown record start")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SleepSession>()).first?.score, 64)

        let message = try XCTUnwrap(try context.fetch(FetchDescriptor<CoachMessage>()).first)
        XCTAssertEqual(message.attachmentsJSON, #"[{"file":"x.jpg"}]"#)
        let log = try XCTUnwrap(try context.fetch(FetchDescriptor<WearableLog>()).first)
        XCTAssertEqual(log.message, "history sync finished")
        XCTAssertEqual(log.metadataJSON, #"{"days":7}"#)
        XCTAssertEqual(log.category, .sync)
        XCTAssertEqual(log.level, .info)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<CoachNotificationRecord>()).first)
        XCTAssertEqual(record.slotRaw, "morning")
        XCTAssertEqual(record.dateKey.count, 10)
        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<UserProfile>()).first)
        XCTAssertEqual(profile.name, "Sam")
        XCTAssertTrue(profile.onboardingCompleted)
        let goal = try XCTUnwrap(try context.fetch(FetchDescriptor<UserGoal>()).first)
        XCTAssertEqual(goal.steps, 9000)
        XCTAssertEqual(goal.intakeCalories, 2100)
        XCTAssertEqual(goal.intakeProteinG, 120)
        let meal = try XCTUnwrap(try context.fetch(FetchDescriptor<MealEntry>()).first)
        XCTAssertEqual(meal.name, "Oat latte")
        XCTAssertEqual(meal.updatedAt, meal.createdAt, "Android's 0 updatedAt falls back to createdAt")
        let food = try XCTUnwrap(try context.fetch(FetchDescriptor<CachedFoodProduct>()).first)
        XCTAssertEqual(food.useCount, 3)

        // No `settings` / `attachments` keys in an Android archive: this device's are left alone.
        XCTAssertEqual(defaults.data(forKey: "pulseloop.metricprefs.v1"), prefs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent("keep.jpg").path))
    }

    /// An archive as every earlier iOS build wrote it — plain JSON, ISO-8601 dates, iOS key names and
    /// spellings, unix-second bucket keys — still imports.
    func testImportsAnOlderPlainJSONiOSArchive() async throws {
        let legacy = #"""
        {"formatVersion":1,"exportedAt":"2026-07-25T10:00:00.123Z","appVersion":"2.7.0","counts":{},
         "devices":[],"measurements":[{"id":"11111111-2222-3333-4444-555555555555","kindRaw":"hr","value":61,
           "unit":"bpm","timestamp":"2026-07-25T09:00:00Z","sourceRaw":"history","confidenceRaw":"known",
           "rawPacketId":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","createdAt":"2026-07-25T09:00:01.500Z"}],
         "activityDailies":[{"id":"21111111-2222-3333-4444-555555555555","date":"2026-07-25T00:00:00Z","steps":5,
           "calories":1,"distanceMeters":2,"activeMinutes":0,"source":"ring","createdAt":"2026-07-25T09:00:00Z",
           "updatedAt":"2026-07-25T09:00:00Z"}],
         "batterySamples":[],"sleepSessions":[],"sleepStageBlocks":[],"rawPackets":[],"derivedUpdates":[],
         "userProfiles":[],"userGoals":[],"deviceMeasurementConfigs":[],"activitySessions":[],"activitySamples":[],
         "activityBucketSamples":[{"startEpoch":1753434000,"date":"2026-07-25T00:00:00Z",
           "timestamp":"2026-07-25T09:00:00Z","steps":12,"distanceMeters":9,"source":"ring_history",
           "updatedAt":"2026-07-25T09:00:00Z"}],
         "activityGpsPoints":[],"activityEvents":[],
         "activitySensorPollEvents":[{"id":"31111111-2222-3333-4444-555555555555",
           "sessionId":"41111111-2222-3333-4444-555555555555","timestamp":"2026-07-25T09:00:00Z","kind":"hr",
           "status":"success"}],
         "coachConversations":[],"coachMemories":[],"coachToolCalls":[],"coachNotificationRecords":[],
         "coachSummaries":[],
         "coachMessages":[{"id":"51111111-2222-3333-4444-555555555555",
           "conversationId":"61111111-2222-3333-4444-555555555555","role":"user","body":"hi",
           "attachmentsJSON":"[1]","createdAt":"2026-07-25T09:00:00Z"}],
         "wearableLogs":[{"id":"71111111-2222-3333-4444-555555555555","timestamp":"2026-07-25T09:00:00Z",
           "deviceTypeRaw":"veepoo","categoryRaw":"error","levelRaw":"warning","message":"lost link",
           "metadataJSON":"{}"}],
         "settings":{},"attachments":[]}
        """#
        let context = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(
            Data(legacy.utf8), context: context, defaults: makeSuiteDefaults(#function),
            attachmentsDirectory: try makeTempDirectory(), refreshStores: false
        )
        let m = try XCTUnwrap(try context.fetch(FetchDescriptor<PulseLoop.Measurement>()).first)
        XCTAssertEqual(m.kindRaw, "hr")
        XCTAssertEqual(m.rawPacketId, UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let iso = ISO8601DateFormatter()
        let expected = try XCTUnwrap(iso.date(from: "2026-07-25T09:00:01Z")).addingTimeInterval(0.5)
        XCTAssertEqual(m.createdAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(count(ActivityDaily.self, context), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ActivityBucketSample>()).first?.startEpoch, 1_753_434_000)
        XCTAssertEqual(count(ActivitySensorPollEvent.self, context), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CoachMessage>()).first?.attachmentsJSON, "[1]")
        let log = try XCTUnwrap(try context.fetch(FetchDescriptor<WearableLog>()).first)
        XCTAssertEqual(log.message, "lost link")
        XCTAssertEqual(log.deviceTypeRaw, "veepoo")
        XCTAssertEqual(log.categoryRaw, "error")
    }

    func testIntegerIdsMapToStableUUIDs() {
        XCTAssertEqual(ArchiveInterop.uuid("42"), ArchiveInterop.uuid("42"))
        XCTAssertNotEqual(ArchiveInterop.uuid("42"), ArchiveInterop.uuid("43"))
        let real = UUID()
        XCTAssertEqual(ArchiveInterop.uuid(real.uuidString.lowercased()), real)
        XCTAssertEqual(ArchiveInterop.bucketSeconds(1_790_400_000_000), 1_790_400_000)
        XCTAssertEqual(ArchiveInterop.bucketSeconds(1_790_400_000), 1_790_400_000)
    }
}
