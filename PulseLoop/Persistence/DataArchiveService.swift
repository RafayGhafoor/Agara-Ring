import Compression
import Foundation
import SwiftData

/// Errors surfaced to the Backup UI. `Sendable` + `nonisolated` so they can cross the detached
/// encode/decode task boundary.
nonisolated enum DataArchiveError: LocalizedError, Sendable {
    case unsupportedVersion(found: Int, supported: Int)
    case invalidFile(details: String?)
    case duplicateKeys(entity: String)
    case operationInProgress
    /// The store holds only the labelled sample set ("Explore without ring"); exporting it would pass it off as data.
    case sampleDataLoaded
    /// The phone is out of room: below `storage_critical_disk_free_mb`, or less than twice the inflated archive is free.
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(found, supported):
            return "This file was exported by a newer app version (format \(found); this app reads up to \(supported)). Update the app and try again."
        case .invalidFile:
            return "This file isn't an export from this app, or it's damaged."
        case let .duplicateKeys(entity):
            return "This file contains duplicate \(entity) entries and can't be imported."
        case .operationInProgress:
            return "Another export or import is already running. Wait for it to finish and try again."
        case .sampleDataLoaded:
            return "This phone only holds sample data. Pair your ring, or clear the sample data, before exporting."
        case .insufficientStorage:
            return "There isn't enough free space on this phone to import this backup. Free up some space and try again."
        }
    }
}

/// Full-app export/import: everything in SwiftData plus the settings blobs and coach attachments,
/// as one gzip-compressed JSON file in Android's archive layout (see `AgaraArchive`). Import reads gzip
/// (detected by its `1f 8b` magic, not the name) or the plain `.json` earlier builds wrote. Privacy-first — nothing leaves the device unless
/// the user shares the file themselves. Keychain API keys are deliberately excluded.
///
/// Concurrency: SwiftData stays on the main actor (the whole app runs on `container.mainContext`),
/// but the work is chunked with `Task.yield()` so the UI never freezes, and the expensive JSON
/// encode/decode runs off-main via `Task.detached`.
@MainActor
enum DataArchiveService {
    /// UserDefaults blobs included in the archive. Deliberately excluded: Apple Health watermarks
    /// (device-local — reset after import instead), Keychain API keys (secrets), remembered-ring
    /// BLE identity and widget snapshots (device-local/derived).
    // Install-bound: UserDefaults keys and archive keys (old exports must import), so the `pulseloop.` prefix stays.
    static let settingsKeys: [String] = [
        "pulseloop.metricprefs.v1",
        "pulseloop.workoutprefs.v1",
        "pulseloop.calibration.v1",
        "pulseloop.coach.settings.v1",
        "pulseloop.applehealth.prefs.v1"
    ]

    /// Rows processed between `Task.yield()`s while mapping models to DTOs during export.
    private static let chunkSize = 2000

    /// Re-entrancy guard. The Privacy screen can be left mid-run (the nav pop gesture bypasses
    /// SwiftUI `.disabled`) and re-entered with fresh view state, so the service — not the view —
    /// must refuse a second concurrent run: two interleaved imports would cross their
    /// autosave save/restore defers and break the single-transaction guarantee.
    private static var isBusy = false

    private static func beginExclusiveOperation() throws {
        guard !isBusy else { throw DataArchiveError.operationInProgress }
        isBusy = true
    }

    // MARK: - Export

    /// Snapshots the entire store into archive JSON (uncompressed, in memory). Kept for tests and the
    /// DEBUG headless export; the share-sheet path is `exportFile`, which streams gzip to disk.
    static func exportArchive(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        attachmentsDirectory: URL? = nil,
        includeRawPackets: Bool = false
    ) async throws -> Data {
        guard !SampleDataStore.isActiveNow else { throw DataArchiveError.sampleDataLoaded }
        try beginExclusiveOperation()
        defer { isBusy = false }
        let sink = ArchiveDataSink()
        try await writeArchive(
            to: sink, context: context, defaults: defaults,
            attachmentsDirectory: attachmentsDirectory ?? Self.defaultAttachmentsDirectory(),
            includeRawPackets: includeRawPackets
        )
        return sink.data
    }

    /// The export's file name — Android's: `agara-export-<yyyy-MM-dd-HHmm>.json.gz`.
    static func exportFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "agara-export-\(formatter.string(from: now)).json.gz"
    }

    /// Streams the archive through gzip into a shareable temp file for the share sheet. Earlier exports
    /// and diagnostics reports are deleted first (`ExportFiles.freshDirectory`) — they are copies the user
    /// already shared, and each one holds their whole health history.
    /// Raw BLE packets are included only when `includeRawPackets` is set (Android's "include diagnostics").
    static func exportFile(context: ModelContext, includeRawPackets: Bool = false) async throws -> URL {
        guard !SampleDataStore.isActiveNow else { throw DataArchiveError.sampleDataLoaded }
        try beginExclusiveOperation()
        defer { isBusy = false }
        let url = try ExportFiles.freshDirectory().appendingPathComponent(exportFileName())
        let sink = try GzipFileSink(url: url)
        do {
            try await writeArchive(
                to: sink, context: context, defaults: .standard,
                attachmentsDirectory: Self.defaultAttachmentsDirectory(), includeRawPackets: includeRawPackets
            )
            try await Task.detached(priority: .userInitiated) { try sink.finish() }.value
        } catch {
            sink.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Writes the archive as one JSON document, row by row — the whole file is never in memory. Same
    /// layout as Android's `ArchiveCodec.write`: scalars first, tables in `AgaraArchive` order, `counts`
    /// last (the rows actually written). iOS-only `settings` / `attachments` go before `counts`.
    /// Models are read on the main actor in chunks; each chunk is JSON-encoded and compressed off-main.
    static func writeArchive(
        to sink: ArchiveSink,
        context: ModelContext,
        defaults: UserDefaults,
        attachmentsDirectory: URL,
        includeRawPackets: Bool
    ) async throws {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let head = "{\"formatVersion\":\(AgaraArchive.currentFormatVersion),\"exportedAt\":"
            + "\(ArchiveCoding.millis(Date())),\"appVersion\":" + jsonString(appVersion)
        try sink.write(Data(head.utf8))

        var counts: [(String, Int)] = []
        func table<T: PersistentModel, D: Encodable & Sendable>(
            _ key: String, _ tableName: String, _ type: T.Type, skip: Bool = false, _ map: (T) -> D
        ) async throws {
            try sink.write(Data(",\"\(key)\":[".utf8))
            let n = skip ? 0 : try await streamRows(type, context, sink, map)
            try sink.write(Data("]".utf8))
            counts.append((tableName, n))
        }
        try await table("devices", "devices", Device.self) { ArchiveDevice($0) }
        // Hot rows, then the readings that live in sealed blocks (decoded back to rows: the export format is still v1, one
        // JSON object per reading — Export v2, a zip of blocks, is a later phase). Nothing compacted is left out of a backup.
        try sink.write(Data(",\"measurements\":[".utf8))
        let hotRows = try await streamRows(PulseLoop.Measurement.self, context, sink) { ArchiveMeasurement($0) }
        let sealedRows = try await streamSealedMeasurements(context, sink, leadingComma: hotRows > 0)
        try sink.write(Data("]".utf8))
        counts.append(("measurements", hotRows + sealedRows))
        try await table("activityDaily", "activity_daily", ActivityDaily.self) { ArchiveActivityDaily($0) }
        try await table("activityBuckets", "activity_buckets", ActivityBucketSample.self) { ArchiveActivityBucketSample($0) }
        try await table("batterySamples", "battery_samples", BatterySample.self) { ArchiveBatterySample($0) }
        try await table("deviceMeasurementConfigs", "device_measurement_configs", DeviceMeasurementConfig.self) {
            ArchiveDeviceMeasurementConfig($0)
        }
        try await table("activitySessions", "activity_sessions", ActivitySession.self) { ArchiveActivitySession($0) }
        try await table("activityGpsPoints", "activity_gps_points", ActivityGpsPoint.self) { ArchiveActivityGpsPoint($0) }
        try await table("activityEvents", "activity_events", ActivityEvent.self) { ArchiveActivityEvent($0) }
        try await table("activitySamples", "activity_samples", ActivitySample.self) { ArchiveActivitySample($0) }
        try await table("activitySensorPolls", "activity_sensor_polls", ActivitySensorPollEvent.self) {
            ArchiveActivitySensorPollEvent($0)
        }
        try await table("sleepSessions", "sleep_sessions", SleepSession.self) { ArchiveSleepSession($0) }
        try await table("sleepStageBlocks", "sleep_stage_blocks", SleepStageBlock.self) { ArchiveSleepStageBlock($0) }
        try await table("coachConversations", "coach_conversations", CoachConversation.self) { ArchiveCoachConversation($0) }
        try await table("coachMessages", "coach_messages", CoachMessage.self) { ArchiveCoachMessage($0) }
        try await table("coachMemories", "coach_memories", CoachMemory.self) { ArchiveCoachMemory($0) }
        try await table("coachToolCalls", "coach_tool_calls", CoachToolCall.self) { ArchiveCoachToolCall($0) }
        try await table("userProfiles", "user_profiles", UserProfile.self) { ArchiveUserProfile($0) }
        try await table("userGoals", "user_goals", UserGoal.self) { ArchiveUserGoal($0) }
        try await table("rawPackets", "raw_packets", RawPacketRecord.self, skip: !includeRawPackets) { ArchiveRawPacket($0) }
        try await table("derivedUpdates", "derived_updates", DerivedUpdateRow.self) { ArchiveDerivedUpdate($0) }
        try await table("coachSummaries", "coach_summaries", CoachSummary.self) { ArchiveCoachSummary($0) }
        try await table("wearableLogs", "wearable_logs", WearableLog.self) { ArchiveWearableLog($0) }
        try await table("coachNotificationRecords", "coach_notification_records", CoachNotificationRecord.self) {
            ArchiveCoachNotificationRecord($0)
        }
        try await table("mealEntries", "meal_entries", MealEntry.self) { ArchiveMealEntry($0) }
        try await table("foodProducts", "food_products", CachedFoodProduct.self) { ArchiveFoodProduct($0) }
        // Deletion tombstones (readings + activity buckets), Android's key and shape.
        try await table("measurementDeletions", "measurement_deletions", MeasurementDeletion.self) {
            ArchiveMeasurementDeletion($0)
        }

        var settings: [String: String] = [:]
        for key in settingsKeys {
            if let data = defaults.data(forKey: key), let blob = String(data: data, encoding: .utf8) {
                settings[key] = blob
            }
        }
        let encoder = ArchiveCoding.makeEncoder()
        try sink.write(Data(",\"settings\":".utf8))
        try sink.write(try encoder.encode(settings))
        try sink.write(Data(",\"attachments\":[".utf8))
        for (index, attachment) in collectAttachments(from: attachmentsDirectory).enumerated() {
            if index > 0 { try sink.write(Data(",".utf8)) }
            try sink.write(try encoder.encode(attachment))
        }
        try sink.write(Data("],\"counts\":{".utf8))
        let countsJSON = counts.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",")
        try sink.write(Data((countsJSON + "}}").utf8))
    }

    /// A JSON string literal for `value` (quotes + escapes).
    private static func jsonString(_ value: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8) ?? "\"\"") ?? "\"\""
    }

    /// Streams every row of one model into `sink` as comma-separated JSON objects and returns the count.
    /// Rows are faulted in batches (`fetch(_:batchSize:)`), mapped to DTOs on the main actor a chunk at a
    /// time, then encoded + compressed off-main, so neither the UI nor memory holds the whole table.
    private static func streamRows<T: PersistentModel, D: Encodable & Sendable>(
        _ type: T.Type,
        _ context: ModelContext,
        _ sink: ArchiveSink,
        _ map: (T) -> D
    ) async throws -> Int {
        // Batched fetches can't include unsaved changes; commit them first (the app autosaves anyway).
        if context.hasChanges { try context.save() }
        var descriptor = FetchDescriptor<T>()
        descriptor.includePendingChanges = false
        let rows = try context.fetch(descriptor, batchSize: chunkSize)
        var written = 0
        var index = rows.startIndex
        while index < rows.endIndex {
            let end = rows.index(index, offsetBy: chunkSize, limitedBy: rows.endIndex) ?? rows.endIndex
            let chunk = rows[index..<end].map(map)
            let leadingComma = written > 0
            try await Task.detached(priority: .userInitiated) {
                let encoder = ArchiveCoding.makeEncoder()
                var buffer = Data()
                for (i, dto) in chunk.enumerated() {
                    if leadingComma || i > 0 { buffer.append(0x2C) }   // ","
                    buffer.append(try encoder.encode(dto))
                }
                try sink.write(buffer)
            }.value
            written += chunk.count
            index = end
        }
        return written
    }

    /// Every reading held in a sealed, readable block whose day no longer has rows, as `ArchiveMeasurement` JSON. One block at a
    /// time is decoded on the main actor and encoded off-main. Ids are stable (derived from block key + timestamp), so two
    /// exports of the same data agree. A skipped/quarantined block contributes nothing (its bytes stay in the store).
    private static func streamSealedMeasurements(_ context: ModelContext, _ sink: ArchiveSink, leadingComma: Bool) async throws -> Int {
        if context.hasChanges { try context.save() }
        var descriptor = FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.sealed == true && $0.state == 0 },
                                                           sortBy: [SortDescriptor(\.utcDay), SortDescriptor(\.blockKey)])
        descriptor.includePendingChanges = false
        let blocks = try context.fetch(descriptor)
        var written = 0
        for block in blocks {
            let key = BlockStore.Key(metric: block.metric, sourceRaw: BlockStore.rawSource(forKeySource: block.source),
                                     sensorId: block.sensorId, day: Int64(block.utcDay))
            if BlockStore.hasRows(for: key, context: context) { continue }   // rows win (interrupted seal); they were exported above
            let dtos: [ArchiveMeasurement] = MeasurementSeries.points(of: block, context: context).map { point in
                let m = MeasurementSeries.detached(point)
                m.id = ArchiveInterop.uuid("\(block.blockKey):\(point.ts)")
                m.createdAt = point.date
                return ArchiveMeasurement(m)
            }
            guard !dtos.isEmpty else { continue }
            let comma = leadingComma || written > 0
            try await Task.detached(priority: .userInitiated) {
                let encoder = ArchiveCoding.makeEncoder()
                var buffer = Data()
                for (i, dto) in dtos.enumerated() {
                    if comma || i > 0 { buffer.append(0x2C) }
                    buffer.append(try encoder.encode(dto))
                }
                try sink.write(buffer)
            }.value
            written += dtos.count
        }
        return written
    }

    private static func collectAttachments(from directory: URL) -> [ArchiveAttachment] {
        // Skip hidden files (.DS_Store & co.) — the import validator rejects dot-file names, so
        // exporting one would make the whole archive un-importable.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ArchiveAttachment(file: url.lastPathComponent, base64: data.base64EncodedString())
        }
    }

    // MARK: - Import

    /// Replaces ALL app data with the archive's contents. Fully validates before touching anything;
    /// wipe + inserts commit in a single save, with rollback on any failure — a bad file can never
    /// leave the store half-imported.
    ///
    /// `refreshStores: false` lets unit tests run against injected defaults/directories without
    /// touching the shared singletons.
    static func importArchive(
        _ fileData: Data,
        context: ModelContext,
        defaults: UserDefaults = .standard,
        attachmentsDirectory: URL? = nil,
        refreshStores: Bool = true
    ) async throws {
        try beginExclusiveOperation()
        defer { isBusy = false }

        // 0. A gzip archive (Android's and this app's `.json.gz`) is inflated first; plain JSON as is.
        let data: Data
        if Gzip.isGzip(fileData) {
            do {
                data = try await Task.detached(priority: .userInitiated) { try Gzip.decompress(fileData) }.value
            } catch {
                throw DataArchiveError.invalidFile(details: "gzip: \(error)")
            }
        } else {
            data = fileData
        }

        // 0b. Room to work: never below the critical threshold, and at least twice the inflated archive.
        StorageGuard.refresh()
        guard !StorageGuard.isCriticalDisk, StorageGuard.freeBytes >= Int64(data.count) * 2 else {
            throw DataArchiveError.insufficientStorage
        }

        // 1. Cheap version probe first, so a newer-format file gets a clear error instead of a
        //    generic decode failure.
        guard let probe = try? JSONDecoder().decode(ArchiveVersionProbe.self, from: data) else {
            throw DataArchiveError.invalidFile(details: "missing formatVersion")
        }
        guard probe.formatVersion <= AgaraArchive.currentFormatVersion else {
            throw DataArchiveError.unsupportedVersion(found: probe.formatVersion, supported: AgaraArchive.currentFormatVersion)
        }

        // 2. Full decode off-main. Nothing has been mutated yet, so any failure here is safe.
        let archive: AgaraArchive
        do {
            archive = try await Task.detached(priority: .userInitiated) {
                try ArchiveCoding.makeDecoder().decode(AgaraArchive.self, from: data)
            }.value
        } catch {
            throw DataArchiveError.invalidFile(details: String(describing: error))
        }

        // 3. Validate in memory (unique keys, attachment names) before mutating.
        try validate(archive)

        // 4. Wipe + insert as one transaction. The mutation window is deliberately SYNCHRONOUS
        //    (no awaits): the app's always-on subscribers share this same mainContext and call
        //    save() on their own events, so any suspension point here would let them commit a
        //    half-imported store. With no awaits, main-actor reentrancy is impossible; autosave is
        //    off as belt-and-braces; single save at the end; rollback discards everything
        //    (deletes included) on failure. Let the spinner overlay render first, though.
        await Task.yield()
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }
        do {
            try wipeAllData(context: context)
            insertAll(archive, context: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // 5. Side stores, only after the SwiftData commit succeeded. An attachment write failure
        //    degrades one chat image, not the whole import.
        // An archive without these keys (Android's) leaves this device's settings and attachment files alone.
        if let settings = archive.settings {
            applySettings(settings, defaults: defaults)
        }
        if let attachments = archive.attachments {
            restoreAttachments(attachments, to: attachmentsDirectory ?? Self.defaultAttachmentsDirectory())
        }
        if refreshStores {
            refreshSharedStores()
        }
    }

    /// Whether any of the 24 model tables has at least one row — gates the destructive
    /// "Replace all data?" confirmation.
    static func hasAnyData(context: ModelContext) -> Bool {
        func has<T: PersistentModel>(_ type: T.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<T>())) ?? 0) > 0
        }
        return has(Device.self) || has(ActivityDaily.self) || has(PulseLoop.Measurement.self)
            || has(BatterySample.self) || has(SleepSession.self) || has(SleepStageBlock.self)
            || has(RawPacketRecord.self) || has(DerivedUpdateRow.self) || has(UserProfile.self)
            || has(UserGoal.self) || has(DeviceMeasurementConfig.self) || has(ActivitySession.self)
            || has(ActivitySample.self) || has(ActivityBucketSample.self) || has(ActivityGpsPoint.self)
            || has(ActivityEvent.self) || has(ActivitySensorPollEvent.self) || has(CoachConversation.self)
            || has(CoachMessage.self) || has(CoachMemory.self) || has(CoachToolCall.self)
            || has(CoachNotificationRecord.self) || has(CoachSummary.self) || has(WearableLog.self)
            || has(MealEntry.self) || has(CachedFoodProduct.self)
    }

    /// Deletes every row of every archived model — the 24 core types plus the nutrition log and food
    /// cache (like Android's restore, which empties every table), unlike `SeedData.clearAll`. Tracked deletes, no save, and deliberately synchronous — see
    /// the atomicity note in `importArchive`.
    static func wipeAllData(context: ModelContext) throws {
        try deleteAll(Device.self, context)
        try deleteAll(ActivityDaily.self, context)
        try deleteAll(PulseLoop.Measurement.self, context)
        try deleteAll(BatterySample.self, context)
        try deleteAll(SleepSession.self, context)
        try deleteAll(SleepStageBlock.self, context)
        try deleteAll(RawPacketRow.self, context)
        try deleteAll(RawPacketRecord.self, context)
        try deleteAll(MeasurementBlock.self, context)
        try deleteAll(BlockSync.self, context)
        try deleteAll(DerivedUpdateRow.self, context)
        try deleteAll(UserProfile.self, context)
        try deleteAll(UserGoal.self, context)
        try deleteAll(DeviceMeasurementConfig.self, context)
        try deleteAll(ActivitySession.self, context)
        try deleteAll(ActivitySample.self, context)
        try deleteAll(ActivityBucketSample.self, context)
        try deleteAll(ActivityGpsPoint.self, context)
        try deleteAll(ActivityEvent.self, context)
        try deleteAll(ActivitySensorPollEvent.self, context)
        try deleteAll(CoachConversation.self, context)
        try deleteAll(CoachMessage.self, context)
        try deleteAll(CoachMemory.self, context)
        try deleteAll(CoachToolCall.self, context)
        try deleteAll(CoachNotificationRecord.self, context)
        try deleteAll(CoachSummary.self, context)
        try deleteAll(WearableLog.self, context)
        try deleteAll(MealEntry.self, context)
        try deleteAll(CachedFoodProduct.self, context)
        try deleteAll(MeasurementDeletion.self, context)
        ReadingDeletion.invalidate()
        SyncPlanStore.shared.resetAll()   // nothing is stored any more: the next pass downloads every day
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }

    private static func insertAll(_ archive: AgaraArchive, context: ModelContext) {
        insert(archive.devices, context)
        insert(archive.activityDailies, context)
        insert(archive.measurements, context)
        insert(archive.batterySamples, context)
        insert(archive.sleepSessions, context)
        insert(archive.sleepStageBlocks, context)
        insert(archive.rawPackets, context)
        insert(archive.derivedUpdates, context)
        insert(archive.userProfiles, context)
        insert(archive.userGoals, context)
        insert(archive.deviceMeasurementConfigs, context)
        insert(archive.activitySessions, context)
        insert(archive.activitySamples, context)
        insert(archive.activityBucketSamples, context)
        insert(archive.activityGpsPoints, context)
        insert(archive.activityEvents, context)
        insert(archive.activitySensorPollEvents, context)
        insert(archive.coachConversations, context)
        insert(archive.coachMessages, context)
        insert(archive.coachMemories, context)
        insert(archive.coachToolCalls, context)
        insert(archive.coachNotificationRecords, context)
        insert(archive.coachSummaries, context)
        insert(archive.wearableLogs, context)
        insert(archive.mealEntries, context)
        insert(archive.foodProducts, context)
        insert(archive.measurementDeletions, context)
        ReadingDeletion.invalidate()
    }

    private static func insert(_ rows: [some ArchiveInsertable], _ context: ModelContext) {
        for row in rows {
            row.insert(into: context)
        }
    }

    // MARK: - Validation

    private static func validate(_ archive: AgaraArchive) throws {
        try requireUnique(archive.devices.map(\.id), entity: "device")
        try requireUnique(archive.activityDailies.map(\.id), entity: "daily activity")
        try requireUnique(archive.measurements.map(\.id), entity: "measurement")
        try requireUnique(archive.batterySamples.map(\.id), entity: "battery sample")
        try requireUnique(archive.sleepSessions.map(\.id), entity: "sleep session")
        try requireUnique(archive.sleepStageBlocks.map(\.id), entity: "sleep stage")
        try requireUnique(archive.rawPackets.map(\.id), entity: "raw packet")
        try requireUnique(archive.derivedUpdates.map(\.id), entity: "derived update")
        try requireUnique(archive.userProfiles.map(\.id), entity: "profile")
        try requireUnique(archive.userGoals.map(\.id), entity: "goal")
        try requireUnique(archive.deviceMeasurementConfigs.map(\.deviceId), entity: "measurement config")
        try requireUnique(archive.activitySessions.map(\.id), entity: "workout")
        try requireUnique(archive.activitySamples.map(\.id), entity: "workout sample")
        try requireUnique(archive.activityBucketSamples.map(\.startSeconds), entity: "activity bucket")
        try requireUnique(archive.activityGpsPoints.map(\.id), entity: "GPS point")
        try requireUnique(archive.activityEvents.map(\.id), entity: "workout event")
        try requireUnique(archive.activitySensorPollEvents.map(\.id), entity: "sensor poll")
        try requireUnique(archive.coachConversations.map(\.id), entity: "conversation")
        try requireUnique(archive.coachMessages.map(\.id), entity: "coach message")
        try requireUnique(archive.coachMemories.map(\.id), entity: "coach memory")
        try requireUnique(archive.coachToolCalls.map(\.id), entity: "tool call")
        try requireUnique(archive.coachNotificationRecords.map(\.id), entity: "notification record")
        try requireUnique(archive.coachSummaries.map(\.id), entity: "coach summary")
        try requireUnique(archive.wearableLogs.map(\.id), entity: "wearable log")
        try requireUnique(archive.mealEntries.map(\.id), entity: "meal")
        try requireUnique(archive.foodProducts.map(\.code), entity: "food product")

        // Attachment names come from the file — never let one escape coach_attachments/.
        for attachment in archive.attachments ?? [] {
            let name = attachment.file
            if name.isEmpty || name.contains("/") || name.contains("..") || name.hasPrefix(".") {
                throw DataArchiveError.invalidFile(details: "unsafe attachment name: \(name)")
            }
        }
    }

    private static func requireUnique<K: Hashable>(_ keys: [K], entity: String) throws {
        guard Set(keys).count == keys.count else {
            throw DataArchiveError.duplicateKeys(entity: entity)
        }
    }

    // MARK: - Settings, attachments, stores

    private static func applySettings(_ settings: [String: String], defaults: UserDefaults) {
        for key in settingsKeys {
            if let blob = settings[key], let data = blob.data(using: .utf8) {
                defaults.set(data, forKey: key)
            } else {
                // The source device never customized this blob — return to defaults here too.
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func restoreAttachments(_ attachments: [ArchiveAttachment], to directory: URL) {
        let fm = FileManager.default
        // Replace the directory wholesale: stale files from the wiped dataset must not linger.
        try? fm.removeItem(at: directory)
        guard !attachments.isEmpty else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.base64) else { continue }
            try? data.write(to: directory.appendingPathComponent(attachment.file), options: .atomic)
        }
    }

    /// Re-reads the shared settings singletons from the (just-imported) UserDefaults blobs so the
    /// change shows without a relaunch — same trick as the factory reset. Also re-stamps the Apple
    /// Health watermarks to "now": importing history must not trigger a surprise full re-export
    /// into this device's Health store.
    private static func refreshSharedStores() {
        let defaults = UserDefaults.standard
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        MetricPrefsStore.shared.settings = decode(MetricPrefs.self, "pulseloop.metricprefs.v1") ?? .default
        WorkoutPrefsStore.shared.settings = decode(WorkoutPrefs.self, "pulseloop.workoutprefs.v1") ?? .default
        CalibrationStore.shared.settings = decode(Calibration.self, "pulseloop.calibration.v1") ?? .default
        CoachSettingsStore.shared.settings = decode(CoachSettings.self, "pulseloop.coach.settings.v1") ?? .default
        AppleHealthPrefsStore.shared.prefs = decode(AppleHealthPrefs.self, "pulseloop.applehealth.prefs.v1") ?? .default
        if AppleHealthPrefsStore.shared.prefs.masterEnabled {
            AppleHealthPrefsStore.shared.resetWatermarks(to: Date())
        }
        #if DEBUG
        // The factory-reset flow re-arms `forceOnboarding`; an imported completed profile should
        // land on the main UI, so disarm it.
        defaults.removeObject(forKey: "forceOnboarding")
        #endif
    }

    private static func defaultAttachmentsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("coach_attachments", isDirectory: true)
    }
}

/// Shared shape of the 24 DTOs' model-restoring side, so `insertAll` can chunk generically.
@MainActor
protocol ArchiveInsertable {
    func insert(into context: ModelContext)
}

extension ArchiveDevice: ArchiveInsertable {}
extension ArchiveMeasurementDeletion: ArchiveInsertable {}
extension ArchiveActivityDaily: ArchiveInsertable {}
extension ArchiveMeasurement: ArchiveInsertable {}
extension ArchiveBatterySample: ArchiveInsertable {}
extension ArchiveSleepSession: ArchiveInsertable {}
extension ArchiveSleepStageBlock: ArchiveInsertable {}
extension ArchiveRawPacket: ArchiveInsertable {}
extension ArchiveDerivedUpdate: ArchiveInsertable {}
extension ArchiveUserProfile: ArchiveInsertable {}
extension ArchiveUserGoal: ArchiveInsertable {}
extension ArchiveDeviceMeasurementConfig: ArchiveInsertable {}
extension ArchiveActivitySession: ArchiveInsertable {}
extension ArchiveActivitySample: ArchiveInsertable {}
extension ArchiveActivityBucketSample: ArchiveInsertable {}
extension ArchiveActivityGpsPoint: ArchiveInsertable {}
extension ArchiveActivityEvent: ArchiveInsertable {}
extension ArchiveActivitySensorPollEvent: ArchiveInsertable {}
extension ArchiveCoachConversation: ArchiveInsertable {}
extension ArchiveCoachMessage: ArchiveInsertable {}
extension ArchiveCoachMemory: ArchiveInsertable {}
extension ArchiveCoachToolCall: ArchiveInsertable {}
extension ArchiveCoachNotificationRecord: ArchiveInsertable {}
extension ArchiveCoachSummary: ArchiveInsertable {}
extension ArchiveWearableLog: ArchiveInsertable {}
extension ArchiveMealEntry: ArchiveInsertable {}
extension ArchiveFoodProduct: ArchiveInsertable {}

// MARK: - Streaming sinks

/// Where `DataArchiveService.writeArchive` sends the archive's bytes, in order. Written from one task
/// at a time (the export awaits each chunk), never concurrently.
nonisolated protocol ArchiveSink: AnyObject, Sendable {
    func write(_ data: Data) throws
}

/// Collects the archive in memory (tests, the DEBUG headless export).
nonisolated final class ArchiveDataSink: ArchiveSink, @unchecked Sendable {
    private(set) var data = Data()
    func write(_ chunk: Data) throws { data.append(chunk) }
}

/// Streams the archive through gzip into a file: a 10-byte RFC 1952 header, raw DEFLATE from the
/// Compression framework (`COMPRESSION_ZLIB` is raw RFC 1951 deflate, no zlib wrapper), then the
/// CRC-32 + ISIZE trailer. The same bytes Java's `GZIPOutputStream` frames (Android's export).
nonisolated final class GzipFileSink: ArchiveSink, @unchecked Sendable {
    private let handle: FileHandle
    private let deflater: GzipDeflater

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        self.handle = handle
        deflater = try GzipDeflater { try handle.write(contentsOf: $0) }
    }

    func write(_ data: Data) throws { try deflater.write(data) }

    /// Flush the deflate stream, write the trailer and close the file.
    func finish() throws {
        try deflater.finish()
        try handle.close()
    }

    /// Release the stream after a failed export (the caller deletes the partial file).
    func abandon() {
        deflater.abandon()
        try? handle.close()
    }
}

/// Incremental gzip writer over raw DEFLATE. `output` receives compressed bytes as they are produced.
nonisolated final class GzipDeflater: @unchecked Sendable {
    private let output: (Data) throws -> Void
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private let bufferSize = 64 * 1024
    private let buffer: UnsafeMutablePointer<UInt8>
    private var crc: UInt32 = 0
    private var size: UInt32 = 0     // ISIZE is the input length mod 2^32
    private var open = true

    init(output: @escaping (Data) throws -> Void) throws {
        self.output = output
        buffer = .allocate(capacity: bufferSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            buffer.deallocate()
            stream.deallocate()
            throw Gzip.Failure.stream("deflate init")
        }
        // ID1 ID2 CM=deflate FLG=0 MTIME=0 XFL=0 OS=3 (Unix) — what GZIPOutputStream writes, too.
        try output(Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]))
    }

    deinit { abandon() }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        crc = Gzip.crc32(data, seed: crc)
        size &+= UInt32(truncatingIfNeeded: data.count)
        try data.withUnsafeBytes { raw in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = raw.count
            try pump(finalize: false)
        }
    }

    func finish() throws {
        guard open else { return }
        stream.pointee.src_size = 0
        try pump(finalize: true)
        var trailer = Data(capacity: 8)
        for value in [crc, size] {
            for shift in stride(from: 0, to: 32, by: 8) { trailer.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
        }
        try output(trailer)
        abandon()
    }

    func abandon() {
        guard open else { return }
        open = false
        compression_stream_destroy(stream)
        stream.deallocate()
        buffer.deallocate()
    }

    private func pump(finalize: Bool) throws {
        let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        while true {
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = bufferSize
            let status = compression_stream_process(stream, flags)
            let produced = bufferSize - stream.pointee.dst_size
            if produced > 0 { try output(Data(bytes: buffer, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // Input consumed and the output buffer had room left: nothing more to drain for now.
                if !finalize, stream.pointee.src_size == 0, produced < bufferSize { return }
            default:
                throw Gzip.Failure.stream("deflate")
            }
        }
    }
}

/// gzip framing (RFC 1952) around the Compression framework's raw DEFLATE.
nonisolated enum Gzip {
    enum Failure: Error, Equatable {
        case notGzip
        case unsupportedMethod
        case truncated
        case stream(String)
        case checksumMismatch
        case sizeMismatch
    }

    /// Starts with the gzip magic `1f 8b`.
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Compress `data` into one gzip member (tests and small payloads; the export streams instead).
    static func compress(_ data: Data) throws -> Data {
        var out = Data()
        let deflater = try GzipDeflater { out.append($0) }
        try deflater.write(data)
        try deflater.finish()
        return out
    }

    /// Inflate a single-member gzip file (what `GZIPOutputStream` and this app write), checking its CRC-32
    /// and size. The Compression decoder reads its input greedily, so it can't report where the deflate
    /// stream ended; the trailer is therefore taken as the file's last 8 bytes.
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        try inflateMember(bytes, into: &out)
        return out
    }

    private static func inflateMember(_ bytes: [UInt8], into out: inout Data) throws {
        let start = 0
        guard bytes.count - start >= 18 else { throw Failure.truncated }
        guard bytes[start] == 0x1F, bytes[start + 1] == 0x8B else { throw Failure.notGzip }
        guard bytes[start + 2] == 0x08 else { throw Failure.unsupportedMethod }
        let flags = bytes[start + 3]
        var p = start + 10
        if flags & 0x04 != 0 {                                  // FEXTRA
            guard p + 2 <= bytes.count else { throw Failure.truncated }
            p += 2 + (Int(bytes[p]) | (Int(bytes[p + 1]) << 8))
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT: zero-terminated
            while p < bytes.count, bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 }                         // FHCRC
        let trailer = bytes.count - 8
        guard p < trailer else { throw Failure.truncated }

        let before = out.count
        try inflateRaw(bytes, from: p, to: trailer, into: &out)
        func le32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        let member = out.subdata(in: before..<out.count)
        guard crc32(member) == le32(trailer) else { throw Failure.checksumMismatch }
        guard UInt32(truncatingIfNeeded: member.count) == le32(trailer + 4) else { throw Failure.sizeMismatch }
    }

    /// Inflate the raw DEFLATE stream in `bytes[start..<end]`.
    private static func inflateRaw(_ bytes: [UInt8], from start: Int, to end: Int, into out: inout Data) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.stream("inflate init")
        }
        defer { compression_stream_destroy(stream) }
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        try bytes.withUnsafeBufferPointer { all in
            let total = end - start
            stream.pointee.src_ptr = all.baseAddress! + start
            stream.pointee.src_size = total
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                // FINALIZE: all the input is here; the decoder stops at the end of the deflate stream.
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { out.append(buffer, count: produced) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    if produced == 0, stream.pointee.src_size == 0 { throw Failure.truncated }
                default:
                    throw Failure.stream("inflate")
                }
            }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (IEEE 802.3, the gzip/zlib polynomial). `seed` continues a running checksum.
    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        crcTable.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { raw in
                for byte in raw.bindMemory(to: UInt8.self) {
                    c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
                }
            }
        }
        return ~c
    }
}

// MARK: - Export temp files

/// Shareable export files live in one folder under the temp directory, emptied before every export
/// (backup or diagnostics) — Android's `ExportFiles.freshDir`. Each one is a full copy of the user's
/// health data that has already been handed to the share sheet; keeping them only grows the disk
/// footprint and the exposure.
nonisolated enum ExportFiles {
    static let directoryName = "exports"
    /// Names earlier builds wrote straight into the temp directory.
    static let legacyPrefixes = ["pulseloop-export-", "pulseloop-diagnostics-", "agara-export-", "agara-diagnostics-"]

    static func freshDirectory(base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for url in old where legacyPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
                try? fm.removeItem(at: url)
            }
        }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
