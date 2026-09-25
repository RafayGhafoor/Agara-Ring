import XCTest
import SwiftData
@testable import PulseLoop

/// Crash list from the 2026-09-26 audit (`docs/process/plans/improvements-review-2026-09-26.md`, batch B).
/// Each test fails if the guarded input can trap again.
@MainActor
final class CrashHardeningTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: StoreRecoveryNotice.key)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: StoreRecoveryNotice.key)
    }

    // MARK: SwiftData store that can't be opened

    /// A store file that isn't a database used to hit `fatalError` on every launch. Now it is moved aside
    /// (with its side files), a fresh store opens, and a one-time notice is queued.
    func testUnreadableStoreIsMovedAsideAndAFreshOneOpens() throws {
        let store = tempDir.appendingPathComponent("default.store")
        try Data("this is not a sqlite database".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let result = ModelContainerFactory.makeRecovering(url: store, now: now)

        let moved = try XCTUnwrap(result.movedAside)
        XCTAssertTrue(moved.lastPathComponent.hasPrefix("default.store.broken-"))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "this is not a sqlite database")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path + "-wal"))
        // The fresh store works.
        let context = result.container.mainContext
        context.insert(UserProfile())
        XCTAssertNoThrow(try context.save())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserProfile>()), 1)
        // One notice, consumed once.
        let notice = try XCTUnwrap(StoreRecoveryNotice.consume())
        XCTAssertTrue(notice.contains(moved.lastPathComponent))
        XCTAssertNil(StoreRecoveryNotice.consume())
    }

    func testHealthyStoreOpensWithoutMovingOrNotice() throws {
        let store = tempDir.appendingPathComponent("ok.store")
        let first = ModelContainerFactory.makeRecovering(url: store)
        XCTAssertNil(first.movedAside)
        first.container.mainContext.insert(UserProfile())
        try first.container.mainContext.save()
        let second = ModelContainerFactory.makeRecovering(url: store)
        XCTAssertNil(second.movedAside)
        XCTAssertNil(StoreRecoveryNotice.consume())
    }

    // MARK: Heart-rate zone steppers

    /// `lo...hi` with `hi < lo` traps; learned boundaries closer than the 5 bpm gap produced that.
    func testZoneStepperRangesNeverInvert() {
        XCTAssertEqual(HeartRateZoneSettingsView.stepRange(63, 55), 63...63)
        XCTAssertEqual(HeartRateZoneSettingsView.stepRange(30, 85), 30...85)
        let d = HeartRateZoneSettingsView.orderedDrafts(low: 58, athletic: 60, elevated: 60, high: 61, athlete: true)
        XCTAssertGreaterThanOrEqual(d.athletic, d.low + 5)
        XCTAssertGreaterThanOrEqual(d.elevated, d.athletic + 5)
        XCTAssertGreaterThanOrEqual(d.high, d.elevated + 5)
        let n = HeartRateZoneSettingsView.orderedDrafts(low: 95, athletic: 60, elevated: 90, high: 80, athlete: false)
        XCTAssertGreaterThanOrEqual(n.elevated, n.low + 5)
        XCTAssertGreaterThanOrEqual(n.high, n.elevated + 5)
    }

    // MARK: Camera where there is none

    func testCameraTapFallsBackToTheLibraryWithoutACamera() {
        XCTAssertEqual(CameraPicker.route(cameraAvailable: false), .library)
        XCTAssertEqual(CameraPicker.route(cameraAvailable: true), .camera)
    }

    // MARK: Info.plist

    /// "Save Image" from a share sheet kills the app without this key.
    func testPhotoLibraryAddUsageDescriptionIsPresent() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String
        XCTAssertFalse((text ?? "").isEmpty)
    }

    // MARK: Sleep segments with a negative duration

    func testNegativeDurationBlockDoesNotTrapTheSessionRebuild() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let session = SleepSession(date: start, startAt: start, endAt: start, totalMinutes: 0)
        context.insert(session)
        let block = SleepStageBlock(sessionId: session.id, startAt: start, startMinute: 0,
                                    durationMinutes: -30, stage: .light)
        context.insert(block)
        try context.save()
        XCTAssertLessThan(block.endAt, block.startAt)
        // The rebuild clamps the segment end to its start instead of forming `start...end` with end < start.
        SleepService.reconcileWakingDay(dateKey: start, context: context,
                                        daySessions: [session], dayBlocks: [block])
        XCTAssertGreaterThanOrEqual(session.endAt, session.startAt)
    }
}
