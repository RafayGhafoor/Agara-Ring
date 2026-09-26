import XCTest
import UserNotifications
@testable import PulseLoop

// Consistency framework (docs/process/plans/consistency-framework.md), phases 1–3: the measurement registry
// and app-scoped service, the notification layer, the sync-progress model, and the small pure rules behind
// ConfirmAction, IconTile and AgaraChart. Each test fails when the rule it names breaks.

/// A ring that answers each test with a set value, optionally after being released by the test.
@MainActor
private final class FakeDevice: MeasurementDevice {
    var hr: Int? = 72
    var spo2: Int? = 97
    var bp: RingSyncCoordinator.BloodPressureReading? = .init(systolic: 118, diastolic: 76)
    var stress: Int? = 30
    var glucose: Double? = 99
    var components: BloodComponentsReading?
    /// When set, `measureHR` waits until the test calls `releaseHR()` (or the task is cancelled).
    var holdHR = false
    private(set) var hrStarted = 0
    private(set) var hrCancelled = false
    private var released = false

    func releaseHR() { released = true }

    func measureHR() async -> Int? {
        hrStarted += 1
        while holdHR, !released {
            if Task.isCancelled { hrCancelled = true; return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return hr
    }
    func measureSpO2() async -> Int? { spo2 }
    func measureBloodPressure() async -> RingSyncCoordinator.BloodPressureReading? { bp }
    func measureStress() async -> Int? { stress }
    func measureGlucose() async -> Double? { glucose }
    func measureBloodComponents() async -> BloodComponentsReading? { components }
}

@MainActor
private final class NotificationRecorder {
    var posted: [UNNotificationRequest] = []
    var removed: [String] = []
    lazy var center = AgaraNotifications(isAppInBackground: false,
                                         deliver: { [unowned self] in self.posted.append($0) },
                                         removeDelivered: { [unowned self] in self.removed += $0 })
}

@MainActor
final class MeasurementServiceTests: XCTestCase {
    private var device: FakeDevice!
    private var recorder: NotificationRecorder!
    private var connected = true
    private var paired = true
    private var backgroundWorkBegun = 0
    private var backgroundWorkEnded = 0

    override func setUp() {
        super.setUp()
        device = FakeDevice()
        recorder = NotificationRecorder()
        connected = true
        paired = true
        backgroundWorkBegun = 0
        backgroundWorkEnded = 0
    }

    private func makeService() -> MeasurementService {
        let env = MeasurementService.Environment(
            device: { [unowned self] in self.device },
            isConnected: { [unowned self] in self.connected },
            hasPairedRing: { [unowned self] in self.paired },
            demoReading: { _ in MeasurementReading(value: 64) },
            failureMessage: { [unowned self] spec in
                self.connected ? spec.kind.failureMessage : "Your ring isn't connected. Reconnect it and try again."
            },
            beginBackgroundWork: { [unowned self] in
                self.backgroundWorkBegun += 1
                return { self.backgroundWorkEnded += 1 }
            },
            sleep: { _ in await Task.yield() }
        )
        return MeasurementService(environment: env, notifications: recorder.center)
    }

    private func spec(_ id: String) -> MeasurementSpec { MeasurementRegistry.spec(id: id)! }

    private func waitUntil(_ timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition never became true", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testHeartRateRunsToAStoredResultWithoutAForegroundNotification() async {
        let service = makeService()
        XCTAssertTrue(service.start(spec("heartRate")))
        XCTAssertTrue(service.isRunning)
        await waitUntil { service.stage == .result }
        XCTAssertEqual(service.reading?.value, 72)
        XCTAssertEqual(service.resultText, "72 bpm")
        XCTAssertTrue(service.hasUnacknowledgedOutcome)
        // Foreground: the sheet/pill shows the result; no notification (plan decision 2).
        XCTAssertTrue(recorder.posted.isEmpty)
        XCTAssertEqual(backgroundWorkBegun, 1)
        XCTAssertEqual(backgroundWorkEnded, 1)
    }

    func testInTheBackgroundProgressAndResultAreNotified() async {
        recorder.center.isAppInBackground = true
        let service = makeService()
        service.start(spec("spo2"))
        await waitUntil { service.stage == .result }
        await waitUntil { self.recorder.posted.count >= 2 }
        let titles = recorder.posted.map(\.content.title)
        XCTAssertEqual(titles.first, AgaraCopy.notificationMeasuringTitle)
        XCTAssertEqual(titles.last, AgaraCopy.notificationMeasuredTitle)
        XCTAssertEqual(recorder.posted.last?.content.body, "Blood oxygen: 97 %")
        // Progress and result share one id, so the result replaces "Measuring…".
        XCTAssertEqual(Set(recorder.posted.map(\.identifier)), [AgaraNotification.measurementId])
        XCTAssertEqual(AgaraNotifications.deepLink(from: recorder.posted.last!.content.userInfo), .measure)
    }

    func testOnlyOneTestAtATime() async {
        device.holdHR = true
        let service = makeService()
        XCTAssertTrue(service.start(spec("heartRate")))
        await waitUntil { self.device.hrStarted == 1 }
        XCTAssertFalse(service.start(spec("spo2")), "a second optical test must be refused")
        XCTAssertTrue(service.start(spec("heartRate")), "reopening the running test is fine")
        XCTAssertEqual(service.spec?.id, "heartRate")
        device.releaseHR()
        await waitUntil { service.stage == .result }
        XCTAssertEqual(device.hrStarted, 1, "reopening must not start the ring twice")
    }

    func testCancelStopsTheRingAndReturnsToIdle() async {
        device.holdHR = true
        let service = makeService()
        service.start(spec("heartRate"))
        await waitUntil { self.device.hrStarted == 1 }
        service.cancel()
        XCTAssertFalse(service.isActive)
        await waitUntil { self.device.hrCancelled }
        XCTAssertTrue(recorder.removed.contains(AgaraNotification.measurementId))
    }

    func testLeavingTheAppMidTestPostsMeasuringAndComingBackClearsIt() async {
        device.holdHR = true
        let service = makeService()
        service.start(spec("heartRate"))
        await waitUntil { service.stage == .searching }
        recorder.center.appDidChangeState(background: true)
        await waitUntil { !self.recorder.posted.isEmpty }
        XCTAssertEqual(recorder.posted.first?.content.title, AgaraCopy.notificationMeasuringTitle)
        recorder.center.appDidChangeState(background: false)
        XCTAssertTrue(recorder.removed.contains(AgaraNotification.measurementId))
        device.releaseHR()
        await waitUntil { service.stage == .result }
    }

    func testPairedButDisconnectedErrorsInsteadOfInventingAReading() async {
        connected = false
        let service = makeService()
        service.start(spec("heartRate"))
        await waitUntil { service.stage == .error }
        XCTAssertNil(service.reading)
        XCTAssertEqual(service.errorMessage, "Your ring isn't connected. Reconnect it and try again.")
    }

    func testNeverPairedRunsTheDemoReading() async {
        connected = false
        paired = false
        let service = makeService()
        service.start(spec("heartRate"))
        await waitUntil { service.stage == .result }
        XCTAssertEqual(service.reading?.value, 64)
    }

    func testBloodPressureWithoutItsDiastolicHalfIsAnError() async {
        let service = makeService()
        let halfBP = MeasurementSpec(id: "bloodPressure", kind: .bloodPressure, seconds: 50, flags: [],
                                     capability: .manualBloodPressure, ringSupport: \.bloodPressure) { _ in
            MeasurementReading(value: 120)
        }
        service.start(halfBP)
        await waitUntil { service.stage == .error }
    }

    func testAcknowledgeClearsAFinishedOutcomeButNotARunningTest() async {
        device.holdHR = true
        let service = makeService()
        service.start(spec("heartRate"))
        await waitUntil { self.device.hrStarted == 1 }
        service.acknowledge()
        XCTAssertTrue(service.isRunning, "a running test survives the sheet closing")
        device.releaseHR()
        await waitUntil { service.stage == .result }
        service.acknowledge()
        XCTAssertFalse(service.isActive)
    }

    func testTryAgainReplacesAFailedOutcome() async {
        device.hr = nil
        let service = makeService()
        service.start(spec("heartRate"))
        await waitUntil { service.stage == .error }
        device.hr = 80
        XCTAssertTrue(service.start(spec("heartRate")))
        await waitUntil { service.stage == .result }
        XCTAssertEqual(service.reading?.value, 80)
    }

    func testGlucoseResultFollowsTheUnit() async {
        let service = makeService()
        service.start(spec("glucose"), glucoseUnit: .mmol)
        await waitUntil { service.stage == .result }
        XCTAssertEqual(service.resultText, "5.5 mmol/L")
    }
}

@MainActor
final class MeasurementRegistryTests: XCTestCase {
    func testSixTestsInTheSharedOrder() {
        XCTAssertEqual(MeasurementRegistry.all.map(\.id),
                       ["heartRate", "spo2", "bloodPressure", "stress", "glucose", "bloodComponents"])
        XCTAssertEqual(MeasurementRegistry.spec(id: "stress")?.kind, .stress)
        XCTAssertNil(MeasurementRegistry.spec(id: "nope"))
    }

    func testUsableReadingRules() {
        let bp = MeasurementRegistry.spec(id: "bloodPressure")!
        XCTAssertFalse(bp.isUsable(MeasurementReading(value: 120)))
        XCTAssertTrue(bp.isUsable(MeasurementReading(value: 120, secondary: 80)))
        XCTAssertEqual(bp.resultText(MeasurementReading(value: 120, secondary: 80), glucoseUnit: .mgdl), "120/80 mmHg")
        XCTAssertFalse(MeasurementRegistry.spec(id: "heartRate")!.isUsable(nil))
    }
}

@MainActor
final class AgaraNotificationsTests: XCTestCase {
    func testProgressNewsOnlyInTheBackgroundAndThrottled() {
        let recorder = NotificationRecorder()
        var clock = Date(timeIntervalSince1970: 1_000)
        recorder.center.now = { clock }
        let progress = AgaraNotification.syncing("Day 1 of 8")
        XCTAssertFalse(recorder.center.shouldPost(progress), "foreground: the header shows it")
        recorder.center.isAppInBackground = true
        XCTAssertTrue(recorder.center.shouldPost(progress))
        let exp = expectation(description: "posted")
        Task { _ = await recorder.center.post(progress); exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(recorder.center.shouldPost(progress), "throttled within 10 s")
        clock = clock.addingTimeInterval(11)
        XCTAssertTrue(recorder.center.shouldPost(progress))
    }

    func testForegroundAlertsStillPost() {
        let recorder = NotificationRecorder()
        let alert = AgaraNotification(id: "ring.battery.alert", category: .battery, title: "Ring battery low",
                                      body: "…", deepLink: .wearable, onlyInBackground: false)
        XCTAssertTrue(recorder.center.shouldPost(alert))
    }

    func testRequestCarriesCategoryThreadAndDeepLink() {
        let request = AgaraNotifications.request(for: .measured("Heart Rate", result: "72 bpm"))
        XCTAssertEqual(request.identifier, AgaraNotification.measurementId)
        XCTAssertEqual(request.content.categoryIdentifier, "agara.measurement")
        XCTAssertEqual(request.content.threadIdentifier, "agara.measurement")
        XCTAssertEqual(request.content.title, AgaraCopy.notificationMeasuredTitle)
        XCTAssertEqual(AgaraNotifications.deepLink(from: request.content.userInfo), .measure)
        XCTAssertEqual(Set(AgaraNotificationCategory.allCases.map(\.rawValue)),
                       ["measurement", "sync", "firmware", "battery", "coach"])
    }
}

@MainActor
final class SyncProgressTests: XCTestCase {
    private var recorder: NotificationRecorder!
    private var progress: SyncProgress!

    override func setUp() {
        super.setUp()
        recorder = NotificationRecorder()
        progress = SyncProgress(notifications: recorder.center)
        progress.now = { Date(timeIntervalSince1970: 1_758_880_000) }
    }

    private func counts(steps: Int = 0, hr: Int = 0, nights: Int = 0) -> SyncDayCounts {
        SyncDayCounts(steps: steps, heartRate: hr, spo2: 0, hrv: 0, stress: 0, sleepNights: nights)
    }

    func testDayRowsFillInAsTheLoopRuns() {
        progress.apply(SyncDayProgress(day: 0, totalDays: 3))
        XCTAssertTrue(progress.isSyncing)
        XCTAssertEqual(progress.rows.map(\.status), [.syncing, .pending, .pending])
        XCTAssertEqual(progress.currentDay, 0)
        progress.apply(SyncDayProgress(day: 0, totalDays: 3, counts: counts(steps: 4_000, hr: 300, nights: 1)))
        progress.apply(SyncDayProgress(day: 1, totalDays: 3))
        XCTAssertEqual(progress.rows.map(\.status), [.done, .syncing, .pending])
        XCTAssertEqual(progress.daysDone, 1)
        XCTAssertEqual(progress.fraction, 1.0 / 3.0, accuracy: 0.001)
        progress.apply(SyncDayProgress(day: 1, totalDays: 3, counts: counts(steps: 6_000, hr: 280)))
        XCTAssertEqual(progress.totals.steps, 10_000)
        XCTAssertEqual(progress.totals.sleepNights, 1)
        XCTAssertEqual(progress.label(for: progress.rows[0]), "Today")
        XCTAssertEqual(progress.label(for: progress.rows[1]), "Yesterday")
        progress.handle(.syncProgress(stage: "done"))
        XCTAssertFalse(progress.isSyncing)
        XCTAssertEqual(progress.daysDone, 3)
        XCTAssertTrue(recorder.posted.isEmpty, "a foreground pass stays quiet")
    }

    func testDecodedPacketFeedAndDisconnect() {
        progress.handle(.decodedPacket(.historyDayProgress(SyncDayProgress(day: 0, totalDays: 2))))
        XCTAssertTrue(progress.isSyncing)
        progress.handle(.deviceStateChanged(state: .disconnected, address: nil))
        XCTAssertFalse(progress.isSyncing)
        XCTAssertEqual(progress.rows.first?.status, .pending, "an interrupted day isn't claimed as done")
    }

    func testANewPassResetsTheRows() {
        progress.apply(SyncDayProgress(day: 0, totalDays: 2))
        progress.apply(SyncDayProgress(day: 0, totalDays: 2, counts: counts(steps: 10)))
        progress.handle(.syncProgress(stage: "done"))
        let first = progress.passID
        progress.apply(SyncDayProgress(day: 0, totalDays: 2))
        XCTAssertEqual(progress.passID, first + 1)
        XCTAssertEqual(progress.totals.steps, 0)
    }

    func testBackgroundPassNotifiesProgressThenDone() async {
        recorder.center.isAppInBackground = true
        progress.apply(SyncDayProgress(day: 0, totalDays: 2))
        progress.apply(SyncDayProgress(day: 0, totalDays: 2, counts: counts(steps: 1_234)))
        progress.handle(.syncProgress(stage: "done"))
        let deadline = Date().addingTimeInterval(1)
        while recorder.posted.count < 2, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(recorder.posted.map(\.content.title),
                       [AgaraCopy.notificationSyncTitle, AgaraCopy.notificationSyncDoneTitle])
        XCTAssertTrue(recorder.posted[0].content.body.contains("\(1_234.formatted()) steps"))
        XCTAssertEqual(AgaraNotifications.deepLink(from: recorder.posted[1].content.userInfo), .sync)
    }

    func testSummaryCopy() {
        XCTAssertEqual(SyncProgress.summary(counts(steps: 5_000, nights: 2), days: 8),
                       "8 days of history: \(5_000.formatted()) steps · 2 nights of sleep.")
        XCTAssertEqual(SyncProgress.summary(SyncDayCounts(), days: 1), "1 day of history are up to date.")
    }
}

final class ConsistencyBuildingBlockTests: XCTestCase {
    func testIconTileShrinksSymbolsThatDrawTheirOwnEnclosure() {
        // Blood pressure's glyph is a full square; at the same fitted size it looked taller than its neighbours.
        XCTAssertLessThan(IconTileOptics.scale(for: "heart.text.square"), 1)
        XCTAssertLessThan(IconTileOptics.scale(for: "exclamationmark.circle.fill"), 1)
        XCTAssertEqual(IconTileOptics.scale(for: "heart.fill"), 1)
        XCTAssertEqual(IconTileOptics.scale(for: "arrow.triangle.2.circlepath"), 1)
        XCTAssertEqual(IconTile.Size.large.glyph, 22)
    }

    func testChartSummaryAndAudioGraphSampling() {
        XCTAssertEqual(AgaraChartSummary.text([], valueLabel: { "\($0)" }), "No data")
        XCTAssertEqual(AgaraChartSummary.text([80, 55, 60], valueLabel: { "\(Int($0))%" }),
                       "3 readings, 55% to 80%, latest 60%")
        let picked = AgaraChartSummary.strideIndices(count: 1_440, limit: 60)
        XCTAssertEqual(picked.count, 60)
        XCTAssertEqual(picked.first, 0)
        XCTAssertEqual(picked.last, 1_439)
        XCTAssertEqual(AgaraChartSummary.strideIndices(count: 5), [0, 1, 2, 3, 4])
    }

    @MainActor
    func testConfirmActionsCarryTheirSeverityAndCopy() {
        var ran = false
        let forget = ConfirmAction.forgetRing { ran = true }
        XCTAssertEqual(forget.severity, .destructive)
        XCTAssertEqual(forget.confirmLabel, "Forget")
        XCTAssertEqual(forget.title, AgaraCopy.confirmForgetTitle)
        XCTAssertEqual(forget.message, AgaraCopy.confirmForgetBody)
        let disconnect = ConfirmAction.disconnectRing {}
        XCTAssertEqual(disconnect.title, AgaraCopy.confirmDisconnectTitle)
        XCTAssertEqual(disconnect.message, AgaraCopy.confirmDisconnectBody)
        XCTAssertEqual(disconnect.severity, .normal)
        XCTAssertEqual(disconnect.confirmLabel, "Disconnect")
        XCTAssertEqual(ConfirmAction.resetCalibration(.glucose) {}.title, AgaraCopy.confirmResetCalibrationTitle)
        forget.perform()
        XCTAssertTrue(ran)
    }

    func testSyncingStepFollowsPairing() {
        let steps = OnboardingStep.allCases
        XCTAssertEqual(steps.firstIndex(of: .syncing), steps.firstIndex(of: .ring).map { $0 + 1 })
        XCTAssertEqual(steps.last, .baseline)
    }
}
