import XCTest
import SwiftData
@testable import PulseLoop

/// Store-launch phase 5 part 2: the debug-only screenshot hooks (`-fixedNow`, `-storeCapture`) and the seeded
/// workout. Same contract as Android's `AppClockTest` / `StoreCaptureTest` / `SampleWorkoutTest`.
/// The "compiled out of Release" proof is the `configure(debugBuild: false)` cases here plus
/// `PulseLoopiOS/scripts/release_hooks_check.sh`, which compiles the two hook files without `DEBUG` and runs them.
@MainActor
final class StoreCaptureHooksTests: XCTestCase {
    private let zone = TimeZone.current

    override func setUp() {
        super.setUp()
        AppClock.reset()
        StoreCapture.reset()
    }

    override func tearDown() {
        AppClock.reset()
        StoreCapture.reset()
        super.tearDown()
    }

    private func local(_ iso: String) throws -> Date { try XCTUnwrap(AppClock.parse(iso, timeZone: zone), iso) }

    // MARK: - AppClock

    func testWithoutFixedNowTheClockIsTheSystemClock() {
        XCTAssertEqual(AppClock.offset, 0)
        XCTAssertFalse(AppClock.isShifted)
        XCTAssertEqual(AppClock.now.timeIntervalSince(Date()), 0, accuracy: 0.5)
    }

    func testFixedNowShiftsTheClockAndKeepsItTicking() throws {
        let target = try local("2026-09-24T19:30:00")
        let systemNow = Date()
        let shift = AppClock.configure("2026-09-24T19:30:00", debugBuild: true, systemNow: systemNow, timeZone: zone)
        XCTAssertEqual(shift, target.timeIntervalSince(systemNow), accuracy: 0.001)
        XCTAssertTrue(AppClock.isShifted)
        // Right after configure the app clock reads the fixed instant...
        XCTAssertEqual(AppClock.now.timeIntervalSince(target), 0, accuracy: 1.0)
        // ...and it still ticks: two readings a moment apart differ by the real elapsed time (differences unchanged).
        let a = AppClock.now
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(AppClock.now.timeIntervalSince(a), 0.25, accuracy: 0.15)
    }

    func testTheGreetingHourDayBoundariesAndLastNightFollowTheClock() throws {
        AppClock.configure("2026-09-24T19:30:00", debugBuild: true, timeZone: zone)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: AppClock.now), 19)
        XCTAssertEqual(greetingForHour(AppClock.now), greetingForHour(try local("2026-09-24T19:30:00")))
        XCTAssertEqual(AppClock.startOfToday(), try local("2026-09-24T00:00:00"))
        XCTAssertTrue(AppClock.isToday(try local("2026-09-24T06:52:00")))
        XCTAssertTrue(AppClock.isYesterday(try local("2026-09-23T22:58:00")))
        XCTAssertFalse(AppClock.isToday(try local("2026-09-23T22:58:00")))
        // A system Date() (a TimelineView tick) is brought onto the app clock.
        XCTAssertEqual(cal.component(.day, from: AppClock.adjust(Date())), 24)
    }

    func testParsesLocalAndOffsetIso8601() throws {
        let z = TimeZone(secondsFromGMT: 2 * 3600)!
        XCTAssertNotNil(AppClock.parse("2026-09-24T19:30"))
        XCTAssertEqual(AppClock.parse("2026-09-24T17:30:00Z"), AppClock.parse("2026-09-24T19:30:00+02:00"))
        XCTAssertEqual(AppClock.parse("2026-09-24T19:30:00", timeZone: z), AppClock.parse("2026-09-24T17:30:00Z"))
        XCTAssertEqual(AppClock.parse("  2026-09-24T19:30:00.500Z ")?.timeIntervalSince(AppClock.parse("2026-09-24T19:30:00Z")!), 0.5)
        XCTAssertNil(AppClock.parse(nil))
        XCTAssertNil(AppClock.parse(""))
        XCTAssertNil(AppClock.parse("tomorrow"))
    }

    func testBlankOrUnparsableFixedNowLeavesTheSystemClockAndResetsAnEarlierShift() {
        AppClock.configure("2026-09-24T19:30:00", debugBuild: true, timeZone: zone)
        XCTAssertTrue(AppClock.isShifted)
        XCTAssertEqual(AppClock.configure(nil, debugBuild: true), 0)
        XCTAssertFalse(AppClock.isShifted)
        XCTAssertEqual(AppClock.configure("garbage", debugBuild: true), 0)
        XCTAssertEqual(AppClock.now.timeIntervalSince(Date()), 0, accuracy: 0.5)
    }

    func testAReleaseBuildCannotShiftTheClock() {
        // The DEBUG-only gate: with debugBuild false (what Release passes) `fixedNow` is ignored, even a valid one,
        // and an earlier shift is cleared.
        AppClock.configure("2026-09-24T19:30:00", debugBuild: true, timeZone: zone)
        XCTAssertEqual(AppClock.configure("2026-09-24T19:30:00", debugBuild: false), 0)
        XCTAssertFalse(AppClock.isShifted)
        XCTAssertEqual(AppClock.now.timeIntervalSince(Date()), 0, accuracy: 0.5)
    }

    func testTheTestBuildIsADebugBuild() {
        // If this ever fails, the hooks are not testable here and the Release script is the only proof.
        XCTAssertTrue(AppClock.isDebugBuild)
        XCTAssertTrue(DebugLaunch.isEnabled)
    }

    // MARK: - StoreCapture

    func testStoreCaptureParsesTheOnValuesOnly() {
        for on in ["YES", "yes", "on", "TRUE", "1", " Yes "] { XCTAssertTrue(StoreCapture.parse(on), on) }
        for off in ["NO", "off", "0", "", "maybe"] { XCTAssertFalse(StoreCapture.parse(off), off) }
        XCTAssertFalse(StoreCapture.parse(nil))
    }

    func testStoreCaptureShowsMayaJustNowAndHidesDebugChrome() {
        XCTAssertEqual(StoreCapture.profile("Emulator"), "Emulator")
        XCTAssertEqual(StoreCapture.relative("5 min ago"), "5 min ago")
        XCTAssertTrue(StoreCapture.showsDebugChrome, "a debug build that is not capturing keeps its debug rows")

        XCTAssertTrue(StoreCapture.configure("YES", debugBuild: true))
        XCTAssertEqual(StoreCapture.profile("Emulator"), "Maya")
        XCTAssertEqual(StoreCapture.profileName, "Maya")
        XCTAssertEqual(StoreCapture.relative("5 min ago"), "just now")
        XCTAssertFalse(StoreCapture.showsDebugChrome, "Developer / debug rows are hidden while capturing")
    }

    func testStoreCaptureIsRefusedInRelease() {
        XCTAssertFalse(StoreCapture.configure("YES", debugBuild: false))
        XCTAssertFalse(StoreCapture.isActive)
        XCTAssertEqual(StoreCapture.profile("Sample"), "Sample")
        StoreCapture.configure("YES", debugBuild: true)
        XCTAssertFalse(StoreCapture.configure("YES", debugBuild: false), "a Release configure also switches an earlier one off")
        XCTAssertFalse(StoreCapture.isActive)
    }

    func testUpdatedLabelsReadJustNowUnderCapture() {
        let device = DeviceHeroStatus.make(
            state: .connected, connectedName: "Agara Ring", knownName: "Agara Ring", nickname: nil, batteryPercent: 86,
            lastSync: AppClock.now.addingTimeInterval(-3 * 3600), now: AppClock.now, isCharging: false, chargeEstimate: nil)
        XCTAssertNotEqual(device.syncText, "Synced just now")
        StoreCapture.configure("YES", debugBuild: true)
        let captured = DeviceHeroStatus.make(
            state: .connected, connectedName: "Agara Ring", knownName: "Agara Ring", nickname: nil, batteryPercent: 86,
            lastSync: AppClock.now.addingTimeInterval(-3 * 3600), now: AppClock.now, isCharging: false, chargeEstimate: nil)
        XCTAssertEqual(captured.syncText, "Synced just now")
    }

    func testStoreCaptureBlocksArchiveExport() async throws {
        let context = try TestSupport.makeContext()
        StoreCapture.configure("YES", debugBuild: true)
        do {
            _ = try await DataArchiveService.exportArchive(context: context)
            XCTFail("the archive must refuse while the sample walk may be present")
        } catch DataArchiveError.sampleDataLoaded {
            // expected
        }
    }

    // MARK: - SampleWorkout

    func testTheWalkIs45MinutesAtHalfPastFiveAndEndsBeforeTheEveningClock() throws {
        let now = try local("2026-09-24T19:30:00")
        let walk = SampleWorkout.build(now: now)
        let cal = Calendar.current
        XCTAssertEqual(walk.session.type, "walk")
        XCTAssertEqual(walk.session.status, .finished)
        XCTAssertEqual(cal.component(.hour, from: walk.session.startedAt), 17)
        XCTAssertEqual(cal.component(.minute, from: walk.session.startedAt), 30)
        XCTAssertTrue(cal.isDate(walk.session.startedAt, inSameDayAs: now), "under the 19:30 hero clock it is today's walk")
        XCTAssertEqual(walk.session.endedAt?.timeIntervalSince(walk.session.startedAt), 45 * 60)
        // Before it has finished, the most recent completed walk is yesterday's.
        let morning = SampleWorkout.build(now: try local("2026-09-24T07:30:00"))
        XCTAssertTrue(cal.isDate(morning.session.startedAt, inSameDayAs: try local("2026-09-23T12:00:00")))
    }

    func testHeartRatePeaksNear128AndStaysPlausible() throws {
        let walk = SampleWorkout.build(now: try local("2026-09-24T19:30:00"))
        let values = walk.heartRate.map(\.value)
        XCTAssertEqual(walk.heartRate.count, 46)
        XCTAssertEqual(values.max(), 128)
        XCTAssertEqual(walk.session.maxHeartRate, 128)
        XCTAssertGreaterThanOrEqual(values.min() ?? 0, 60)
        XCTAssertTrue((100...120).contains(walk.session.avgHeartRate ?? 0), "avg \(walk.session.avgHeartRate ?? 0)")
        XCTAssertEqual(SampleWorkout.heartRate(atMinute: 26), 128)
        // Same numbers as Android's SampleWorkout.heartRateAt.
        XCTAssertEqual(Double((0...45).map(SampleWorkout.heartRate(atMinute:)).reduce(0, +)), values.reduce(0, +))
    }

    func testRouteIsAClosedLoopOfAbout4Point2KmWithMonotonicTime() throws {
        let walk = SampleWorkout.build(now: try local("2026-09-24T19:30:00"))
        let pts = walk.gpsPoints
        XCTAssertEqual(pts.count, 181)
        XCTAssertTrue(pts.allSatisfy { $0.accepted })
        XCTAssertEqual(walk.session.gpsPointCount, 181)
        let distance = try XCTUnwrap(walk.session.distanceMeters)
        XCTAssertEqual(distance, 4_200, accuracy: 150, "distance \(distance)")
        for (a, b) in zip(pts, pts.dropFirst()) { XCTAssertLessThan(a.timestamp, b.timestamp) }
        XCTAssertEqual(pts.first?.timestamp, walk.session.startedAt)
        XCTAssertEqual(try XCTUnwrap(pts.last).timestamp.timeIntervalSince(walk.session.startedAt), 45 * 60, accuracy: 1)
        // Open country, one fixed origin (same coordinates as Android).
        XCTAssertTrue(pts.allSatisfy { abs($0.latitude - 47.0) < 0.02 && abs($0.longitude - 8.0) < 0.03 })
    }

    func testEveryRowIsRecognisableAsSampleAndHeartRateOnly() throws {
        let walk = SampleWorkout.build(now: try local("2026-09-24T19:30:00"))
        XCTAssertTrue(SampleWorkout.isSample(walk.session))
        XCTAssertFalse(SampleWorkout.isSample(UUID()))
        XCTAssertEqual(walk.session.id, SampleWorkout.sessionID(start: walk.session.startedAt), "deterministic per start")
        XCTAssertTrue(walk.heartRate.allSatisfy { $0.source == "mock" && $0.kind == MeasurementKind.heartRate.rawValue && $0.sessionId == walk.session.id })
        XCTAssertTrue(walk.gpsPoints.allSatisfy { $0.sessionId == walk.session.id })
        XCTAssertNil(walk.session.avgSpO2, "no SpO2 on the sample walk")
    }

    func testSampleDataCarriesExactlyOneWorkoutAndItIsWipedWithTheRest() throws {
        let context = try TestSupport.makeContext()
        SeedData.seedDemo(context, completeOnboarding: true, sample: true)
        let sessions = try context.fetch(FetchDescriptor<ActivitySession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(SampleWorkout.isSample(try XCTUnwrap(sessions.first)))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivityGpsPoint>()), 181)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySample>()), 46)
        // No blood pressure, glucose, lipids, fatigue or temperature anywhere in the sample set.
        let banned = Set([MeasurementKind.bloodPressureSystolic, .bloodPressureDiastolic, .bloodSugar, .fatigue, .temperature,
                          .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid].map(\.rawValue))
        let kinds = Set(try context.fetch(FetchDescriptor<PulseLoop.Measurement>()).map(\.kindRaw))
        XCTAssertTrue(kinds.isDisjoint(with: banned), "\(kinds)")
        // Wiped when a real ring pairs (SampleDataStore.wipeForRealRing -> SeedData.clearData).
        SeedData.clearData(context, keepingProfile: true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivityGpsPoint>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySample>()), 0)
    }

    func testInsertIsIdempotentAndCanCreditActiveMinutesOnce() throws {
        let context = try TestSupport.makeContext()
        let now = try local("2026-09-24T19:30:00")
        XCTAssertNotNil(SampleWorkout.insert(into: context, now: now, creditActiveMinutes: true))
        XCTAssertNil(SampleWorkout.insert(into: context, now: now, creditActiveMinutes: true), "second launch adds nothing")
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySession>()), 1)
        let day = try XCTUnwrap(MetricsRepository.activity(on: now, context: context))
        XCTAssertEqual(day.activeMinutes, 45)
        XCTAssertEqual(day.distanceMeters, 0, "the ring's own totals already contain the walk; distance is not added")
    }

    func testTheWalkNeverReachesStravaHealthOrTheArchive() throws {
        let context = try TestSupport.makeContext()
        let walk = try XCTUnwrap(SampleWorkout.insert(into: context, now: try local("2026-09-24T19:30:00"), creditActiveMinutes: false))
        try context.save()
        XCTAssertTrue(SampleWorkout.isSample(walk), "the marker the Strava queue and the Health workout export filter on")
        let real = ActivitySession(type: "run", status: .finished, startedAt: AppClock.now.addingTimeInterval(-7200),
                                   endedAt: AppClock.now.addingTimeInterval(-3600))
        XCTAssertFalse(SampleWorkout.isSample(real))
    }
}
