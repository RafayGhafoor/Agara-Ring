import XCTest
import SwiftData
import CoreBluetooth
@testable import PulseLoop

/// Consistency framework phases 4–6 (docs/process/plans/consistency-framework.md): the auto-measure block
/// (`b3 01` set byte-exact against the research doc and the emulator), the parity flags, and the Android ports
/// (delete a reading / an hour of steps with tombstones, the sleep "recorded in N parts" card).
@MainActor
final class ConsistencyPhase456Tests: XCTestCase {

    // MARK: - Phase 4: auto-measure

    /// The real `b3` read reply (three 125-byte frames) — same capture as MeasureHubProtocolTests.
    static let capturedTable = [
        "b3020101a0050318010000a121d00100d10100d20101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10101d20101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10102d20101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10103d2",
        "b30201020101d3021e00d4020101d50400000000d6021e00d70400000000a121d00100d10104d20101d3023c00d4020101d50400000000d6023c00d70400000000a121d00100d10106d20100d3020500d4020000d50400000600d6020500d70400000600a121d00100d10107d20101d3021e00d4020101d50400000000",
        "b3020103d6021e00d70400000000a121d00100d10108d20101d3021e00d4020101d50400000000d6021e00d70400000000",
    ]

    private final class NullWriter: RingCommandWriter { func enqueue(_ command: Data) {} }

    private func capturedEntries() -> [AutoMeasureEntry] {
        let driver = VeepooDriver(writer: NullWriter())
        let uuid = CBUUID(string: VeepooUUIDs.commandNotify)
        var events: [RingDecodedEvent] = []
        for frame in Self.capturedTable { events += driver.ingest(frameData(frame), from: uuid) }
        guard case let .autoMeasureSchedule(entries)? = events.first else { XCTFail("no schedule"); return [] }
        return entries
    }

    /// Every decoded row re-encodes to exactly the 33 bytes the ring sent (so a set changes only d2/d6).
    func testEveryCapturedRowReencodesByteExact() {
        let body = Self.capturedTable.map { Array(frameData($0).dropFirst(4)) }.flatMap { $0 }
        var captured: [Int: [UInt8]] = [:]
        var i = 7
        while i + 2 <= body.count, body[i] == 0xA1 {
            let value = Array(body[(i + 2)..<(i + 2 + Int(body[i + 1]))])
            captured[Int(value[5])] = value
            i += 2 + Int(body[i + 1])
        }
        let entries = capturedEntries()
        XCTAssertEqual(entries.count, 8)
        for entry in entries {
            XCTAssertEqual(Data(AutoMeasure.tlvValue(entry)).hexString, captured[entry.type].map { Data($0).hexString }, "type \(entry.type)")
        }
    }

    /// Heart rate every 60 min: `b3 01 <seq>` + 17-byte chunks (20, 20, 11 bytes), frame-1 byte 5 = chunk count
    /// (research 03 §2.4). Expected bytes computed with the emulator's own `frames.parse_auto_measure_set`.
    func testHeartRateSixtyMinutesSetFramesAreByteExact() throws {
        var hr = try XCTUnwrap(capturedEntries().first { $0.type == 0 })
        hr.intervalMinutes = 60
        XCTAssertEqual(Data(AutoMeasure.setBody(hr)).hexString,
                       "a0050323000000a121d00100d10100d20101d3021e00d4020101d50400000000d6023c00d70400000000")
        let frames = AutoMeasure.setFrames(hr)
        XCTAssertEqual(frames.map(\.hexString), [
            "b30101a0050323000000a121d00100d10100d201",
            "b3010201d3021e00d4020101d50400000000d602",
            "b301033c00d70400000000",
        ])
        XCTAssertEqual(frames.map(\.count), [20, 20, 11])
        XCTAssertEqual(frames[0][5], 3, "frame-1 byte 5 carries the chunk count")
    }

    func testOffersOnlyWhatTheRingAccepts() {
        let entries = capturedEntries()
        let hr = entries.first { $0.type == 0 }!
        XCTAssertEqual(AutoMeasure.intervals(for: hr), [30, 60, 90, 120, 150, 180, 210, 240])
        XCTAssertTrue(AutoMeasure.isShortest(30, for: hr))
        XCTAssertFalse(AutoMeasure.isShortest(60, for: hr))
        let spo2 = entries.first { $0.type == 4 }!
        XCTAssertEqual(AutoMeasure.intervals(for: spo2), [60, 120, 180, 240])
        let lorenz = entries.first { $0.type == 6 }!
        XCTAssertTrue(AutoMeasure.isLocked(lorenz), "d4 00 00 → read-only")
        XCTAssertFalse(AutoMeasure.isLocked(hr))
        XCTAssertEqual(lorenz.allowedWindow, [0, 0, 6, 0])
        XCTAssertEqual(AutoMeasure.label(minutes: 90), "1 h 30 min")
        // A row stored before the step was decoded has nothing to offer → locked, never a bogus picker.
        let legacy = AutoMeasureEntry.decodeList(#"[{"type":0,"enabled":true,"intervalMinutes":30,"startHour":0,"startMinute":0,"endHour":0,"endMinute":0}]"#)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertTrue(AutoMeasure.isLocked(legacy[0]))
    }

    func testSetAckDecodesAndTriggersReadBack() {
        let driver = VeepooDriver(writer: NullWriter())
        let uuid = CBUUID(string: VeepooUUIDs.commandNotify)
        guard case let .settingAck(cmd, ok)? = driver.ingest(frameData("b30101" + String(repeating: "00", count: 17)), from: uuid).first
        else { return XCTFail("no ack") }
        XCTAssertEqual(cmd, 0xB3); XCTAssertTrue(ok)
        guard case let .settingAck(_, refused)? = driver.ingest(frameData("b30100" + String(repeating: "00", count: 17)), from: uuid).first
        else { return XCTFail("no nack") }
        XCTAssertFalse(refused)

        let recorder = FrameRecorder()
        let engine = VeepooSyncEngine(writer: recorder, decoder: VeepooDecoder(), historyDays: 1)
        engine.isFeatureOn = { $0 == .autoMeasureSettings }
        engine.connectionDidStart()
        var hr = capturedEntries().first { $0.type == 0 }!
        hr.intervalMinutes = 60
        XCTAssertFalse(engine.setAutoMeasure(hr), "nothing before auth")
        engine.handle(.commandAck(commandId: 0xA1))
        recorder.commands.removeAll()
        XCTAssertTrue(engine.setAutoMeasure(hr))
        XCTAssertEqual(recorder.commands, AutoMeasure.setFrames(hr))
        recorder.commands.removeAll()
        engine.handle(.settingAck(commandId: 0xB3, ok: true))
        XCTAssertEqual(recorder.commands, [VeepooEncoder.autoMeasureRead()], "ack → read the table back")
        engine.isFeatureOn = { _ in false }
        XCTAssertFalse(engine.setAutoMeasure(hr), "flag off → no ring write")
        engine.connectionDidEnd()
    }

    func testStoreSettlesOnReadBackAndFailsOnRefusal() {
        let store = AutoMeasureStore()
        var sent: [AutoMeasureEntry] = []
        store.sender = { sent.append($0); return true }
        let entries = capturedEntries()
        var hr = entries.first { $0.type == 0 }!
        hr.intervalMinutes = 60
        store.set(hr)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(store.writes[0], .saving)
        XCTAssertEqual(store.displayed(entries[0]).intervalMinutes, 60, "shows the requested value while saving")
        // Read-back holding the new value settles the write.
        store.handle(.autoMeasureSchedule(entries.map { $0.type == 0 ? hr : $0 }))
        XCTAssertNil(store.writes[0])
        XCTAssertEqual(store.schedule.first { $0.type == 0 }?.intervalMinutes, 60)
        // A refusal fails it.
        var spo2 = entries.first { $0.type == 4 }!
        spo2.enabled = false
        store.set(spo2)
        store.handle(.decodedPacket(.settingAck(commandId: 0xB3, ok: false)))
        XCTAssertEqual(store.writes[4], .failed("The ring refused the change."))
        // Locked rows are never sent; offline reports why.
        store.set(entries.first { $0.type == 6 }!)
        XCTAssertEqual(sent.count, 2)
        store.sender = { _ in false }
        store.set(hr)
        XCTAssertEqual(store.writes[0], .failed("Connect your ring to change this."))
    }

    // MARK: - Phase 5: About

    func testAboutLinksComeFromTheCatalog() {
        XCTAssertEqual(AboutSettingsView.telURL("(213) 286-1434")?.absoluteString, "tel:+12132861434")
        XCTAssertEqual(AboutSettingsView.socialLinks.map(\.id), ["website", "instagram", "telegram"])
        XCTAssertEqual(AboutSettingsView.contactLinks.first?.url.absoluteString, "mailto:" + AgaraCopy.supportEmail)
        XCTAssertNil(AboutSettingsView.link("x", "X", "globe", "  "), "an empty catalog value hides the icon")
        XCTAssertTrue(AboutSettingsView.appVersionLabel.contains("("))
    }

    // MARK: - Phase 6: flags

    func testParityFlagsDefaultOffAndGroupOverrides() {
        for flag in AgaraFeatureStore.parityFlags { XCTAssertFalse(flag.defaultOn, "\(flag) must ship off") }
        let parity = AgaraFeatureStore.parse("parity=on")
        XCTAssertEqual(Set(parity.keys), Set(AgaraFeatureStore.parityFlags))
        let all = AgaraFeatureStore.parse("all=on,coach=off")
        XCTAssertEqual(all.count, AgaraFeature.allCases.count)
        XCTAssertEqual(all[.coach], false)
        XCTAssertEqual(all[.nutrition], true)
    }

    func testMiddaySlotDropsWithoutCheckinExtras() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at14 = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 14))!
        XCTAssertEqual(CoachNotificationSlot.current(for: at14, morningHour: 8, middayHour: 13, eveningHour: 19, calendar: cal), .midday)
        XCTAssertNil(CoachNotificationSlot.current(for: at14, morningHour: 8, middayHour: CoachNotificationSlot.noMidday,
                                                   eveningHour: 19, calendar: cal))
        let next = CoachNotificationSlot.nextWindowStart(after: cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9))!,
                                                         morningHour: 8, middayHour: CoachNotificationSlot.noMidday,
                                                         eveningHour: 19, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: next), 19, "skips straight to the evening")
    }

    // MARK: - Phase 6: delete a reading

    private func rows(_ context: ModelContext, _ kind: MeasurementKind) -> [PulseLoop.Measurement] {
        let raw = kind.rawValue
        return (try? context.fetch(FetchDescriptor<PulseLoop.Measurement>(predicate: #Predicate { $0.kindRaw == raw }))) ?? []
    }

    /// Delete a history reading → a tombstone, and the next sync of that slot writes nothing back (across a
    /// "sync done" that clears the in-memory dedupe, i.e. like a later launch).
    func testDeletedHistoryReadingStaysDeletedAfterResync() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_790_000_000)
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 71, timestamp: ts))
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 64, timestamp: ts.addingTimeInterval(300)))
        subscriber.flush()
        let target = try XCTUnwrap(rows(context, .heartRate).first { $0.value == 71 })

        XCTAssertEqual(ReadingDeletion.delete([target], context: context), 1)
        let tombstones = try context.fetch(FetchDescriptor<MeasurementDeletion>())
        XCTAssertEqual(tombstones.map(\.measurementId), ["history:hr:1790000000000"])

        subscriber.persist(.syncProgress(stage: "done"))
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 71, timestamp: ts))
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 64, timestamp: ts.addingTimeInterval(300)))
        subscriber.flush()
        XCTAssertEqual(rows(context, .heartRate).map(\.value), [64], "the deleted reading must not come back")
    }

    func testLiveReadingHasNoTombstoneAndBloodPressureGoesAsAPair() throws {
        let context = try TestSupport.makeContext()
        let ts = Date(timeIntervalSince1970: 1_790_000_000)
        let live = PulseLoop.Measurement(kind: .heartRate, value: 80, unit: "bpm", timestamp: ts, source: .live)
        let sys = PulseLoop.Measurement(kind: .bloodPressureSystolic, value: 121, unit: "mmHg", timestamp: ts, source: .history)
        let dia = PulseLoop.Measurement(kind: .bloodPressureDiastolic, value: 79, unit: "mmHg", timestamp: ts, source: .history)
        [live, sys, dia].forEach(context.insert)
        try context.save()

        ReadingDeletion.delete([live], context: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MeasurementDeletion>()).isEmpty, "a live UUID row is never regenerated")

        XCTAssertEqual(ReadingDeletion.delete([sys], context: context), 2, "deleting the systolic takes the diastolic")
        XCTAssertTrue(rows(context, .bloodPressureDiastolic).isEmpty)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<MeasurementDeletion>()).map(\.measurementId)),
                       ["history:bp_sys:1790000000000", "history:bp_dia:1790000000000"])
        XCTAssertTrue(ReadingDeletion.isHistoryDeleted(kindRaw: "bp_dia", timestamp: ts, context: context))
        XCTAssertFalse(ReadingDeletion.isHistoryDeleted(kindRaw: "hr", timestamp: ts, context: context))
    }

    /// Every confirmation's wording comes from brand.yaml (both apps say the same).
    func testConfirmCopyComesFromTheCatalog() {
        let reading = ConfirmAction.deleteReading(value: "71 bpm", time: "3:05 PM", fromHistory: true) {}
        XCTAssertEqual(reading.title, AgaraCopy.confirmDeleteReadingTitle)
        XCTAssertEqual(reading.message, "71 bpm at 3:05 PM.\n\n" + AgaraCopy.confirmDeleteReadingBody)
        XCTAssertEqual(reading.severity, .destructive)
        XCTAssertEqual(ConfirmAction.deleteSteps(steps: 1_200, hours: "2 PM – 3 PM") {}.title, AgaraCopy.confirmDeleteStepsHourTitle)
        XCTAssertEqual(ConfirmAction.deleteMeal(name: nil) {}.message, AgaraCopy.confirmDeleteMealBody)
        XCTAssertEqual(ConfirmAction.resetAppData {}.title, AgaraCopy.confirmResetAppDataTitle)
        XCTAssertEqual(ConfirmAction.reseedDemo {}.message, AgaraCopy.confirmReseedDemoBody)
        XCTAssertEqual(ConfirmAction.clearDemo {}.title, AgaraCopy.confirmClearDemoTitle)
        XCTAssertEqual(ConfirmAction.replaceAllData {}.title, AgaraCopy.confirmReplaceDataTitle)
        XCTAssertEqual(ConfirmAction.signOutCloud {}.message, AgaraCopy.confirmSignOutBody)
        XCTAssertEqual(ConfirmAction.disconnectStrava {}.title, AgaraCopy.confirmDisconnectStravaTitle)
        XCTAssertEqual(AgaraNotification.measurementFailed("Heart rate").title, AgaraCopy.notificationMeasuredFailedTitle)
        XCTAssertEqual(OnboardingStep.syncing.rawValue, "syncing", "the saved step value both apps share")
    }

    // MARK: - Phase 6: delete an hour of steps

    func testDeletingAnHourRestatesTheDayAndHoldsAgainstTheRing() throws {
        let context = try TestSupport.makeContext()
        let day = Calendar.current.startOfDay(for: Date())
        let hour9 = day.addingTimeInterval(9 * 3600)
        let hour10 = day.addingTimeInterval(10 * 3600)
        ActivityService.applyActivityBucket(date: hour9, steps: 400, distanceMeters: 300, context: context)
        ActivityService.applyActivityBucket(date: hour9.addingTimeInterval(900), steps: 600, distanceMeters: 450, context: context)
        ActivityService.applyActivityBucket(date: hour10, steps: 250, distanceMeters: 200, context: context)
        try context.save()
        XCTAssertEqual(MetricsRepository.activity(on: day, context: context)?.steps, 1_250)

        XCTAssertEqual(ActivityBucketDeletion.deleteBuckets(from: hour9, to: hour9.addingTimeInterval(3600), context: context), 1_000)
        let row = try XCTUnwrap(MetricsRepository.activity(on: day, context: context))
        XCTAssertEqual(row.steps, 250, "the day falls — no ratchet on a delete")
        XCTAssertEqual(row.deletedSteps, 1_000)
        XCTAssertEqual(row.deletedDistanceMeters, 750)
        XCTAssertEqual(row.calories, 0, "the ring's calorie figure counted the deleted block")

        // The ring's live cumulative total still includes the block: corrected by the deficit.
        ActivityService.applyActivityUpdate(ActivityDailyUpdate(date: day, steps: 1_300, calories: 90, distanceMeters: 1_000,
                                                                activeMinutes: nil, source: "ring", syncedAt: Date()), context: context)
        XCTAssertEqual(row.steps, 300)
        XCTAssertEqual(row.distanceMeters, 250)
        XCTAssertEqual(row.calories, 0, "calories are not raised while a deficit exists")

        // A re-synced history bucket for the deleted hour is ignored (tombstone).
        ActivityService.applyActivityBucket(date: hour9, steps: 400, distanceMeters: 300, context: context)
        let buckets = try context.fetch(FetchDescriptor<ActivityBucketSample>())
        XCTAssertEqual(buckets.map(\.steps), [250])
        XCTAssertEqual(ActivityBucketDeletion.ratchetAgainstRing(stored: 10, ringTotal: 5, deleted: 20), 10)
        XCTAssertEqual(ReadingDeletion.activityKey(startEpoch: 1_790_000_000), "activity:1790000000000")
    }

    func testTombstonesAndDeficitRideTheArchive() async throws {
        let context = try TestSupport.makeContext()
        let ts = Date(timeIntervalSince1970: 1_790_000_000)
        ReadingDeletion.record(key: ReadingDeletion.historyKey(kindRaw: "hr", timestamp: ts), kindRaw: "hr", timestamp: ts, context: context)
        ReadingDeletion.record(key: ReadingDeletion.activityKey(startEpoch: 1_790_000_000), kindRaw: "activity_bucket", timestamp: ts, context: context)
        let daily = ActivityDaily(date: ts, steps: 100)
        daily.deletedSteps = 40
        context.insert(daily)
        try context.save()

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try await DataArchiveService.exportArchive(context: context, defaults: defaults, attachmentsDirectory: dir)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exported = try XCTUnwrap(root["measurementDeletions"] as? [[String: Any]])
        XCTAssertEqual(Set(exported.compactMap { $0["kindRaw"] as? String }), ["HEART_RATE", "ACTIVITY_BUCKET"])

        let target = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(data, context: target, defaults: defaults, attachmentsDirectory: dir,
                                                   refreshStores: false)
        XCTAssertTrue(ReadingDeletion.isHistoryDeleted(kindRaw: "hr", timestamp: ts, context: target))
        XCTAssertTrue(ReadingDeletion.isActivityDeleted(startEpoch: 1_790_000_000, context: target))
        XCTAssertEqual(try target.fetch(FetchDescriptor<ActivityDaily>()).first?.deletedSteps, 40)
    }

    // MARK: - Phase 6: sleep "recorded in N parts"

    func testSleepRecordRunsGroupByRecordThenFallBackToGaps() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ min: Int) -> Date { t0.addingTimeInterval(TimeInterval(min * 60)) }
        // Two records a minute apart (05:57 → 05:58 style): only recordStartAt can tell them apart.
        let stamped: [(start: Date, minutes: Int, awake: Bool, record: Date?)] = [
            (at(0), 60, false, at(0)), (at(60), 30, true, at(0)), (at(90), 120, false, at(0)),
            (at(211), 90, false, at(211)),
        ]
        let runs = SleepRecordRuns.runs(stamped)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].asleepMinutes, 180, "awake blocks don't count as asleep")
        XCTAssertEqual(runs[0].endAt, at(210))
        XCTAssertEqual(runs[1].startAt, at(211))
        // One record → one run (the card stays hidden).
        XCTAssertEqual(SleepRecordRuns.runs(stamped.map { ($0.start, $0.minutes, $0.awake, at(0)) }).count, 1)
        // Legacy rows (no recordStartAt): split at gaps of 2 min or more.
        let legacy: [(start: Date, minutes: Int, awake: Bool, record: Date?)] = [
            (at(0), 60, false, nil), (at(61), 30, false, nil), (at(95), 30, false, nil),
        ]
        XCTAssertEqual(SleepRecordRuns.runs(legacy).count, 2)
    }
}
