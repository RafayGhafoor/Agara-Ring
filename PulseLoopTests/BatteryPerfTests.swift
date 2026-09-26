import XCTest
import SwiftData
@testable import PulseLoop

/// Battery / performance items of the 2026-09-26 audit (batch B). Each test fails if the churn comes back.
@MainActor
final class BatteryPerfTests: XCTestCase {

    // MARK: The 30 s poll cascade

    /// An unchanged `D8` poll writes nothing: no row touch, no save, no data-change signal.
    func testUnchangedActivityPollIsANoOp() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let now = Date()
        subscriber.persist(.activityUpdate(timestamp: now, steps: 1200, distanceMeters: 800, calories: 50))
        subscriber.flush()
        let row = try XCTUnwrap(MetricsRepository.activity(on: now, context: context))
        let stamp = row.updatedAt
        let token = AgaraDataChange.shared.token

        subscriber.persist(.activityUpdate(timestamp: now, steps: 1200, distanceMeters: 800, calories: 50))
        subscriber.flush()
        XCTAssertEqual(row.updatedAt, stamp, "an unchanged poll must not touch the row")
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(AgaraDataChange.shared.token, token, "no data-change signal for an unchanged poll")

        subscriber.persist(.activityUpdate(timestamp: now, steps: 1300, distanceMeters: 860, calories: 55))
        subscriber.flush()
        XCTAssertEqual(row.steps, 1300)
        XCTAssertNotEqual(AgaraDataChange.shared.token, token)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DerivedUpdateRow>()), 0,
                       "no audit row per activity update any more")
    }

    /// No `DerivedUpdateRow` per measurement; a re-synced identical history slot writes nothing.
    func testMeasurementsWriteNoAuditRowAndIdenticalResyncIsANoOp() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_790_000_000)
        subscriber.persist(.historyMeasurement(kind: .spo2, value: 97, timestamp: ts))
        subscriber.persist(.syncProgress(stage: "done"))   // clears the in-process dedup set
        subscriber.flush()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DerivedUpdateRow>()), 0)
        let token = AgaraDataChange.shared.token
        subscriber.persist(.historyMeasurement(kind: .spo2, value: 97, timestamp: ts))
        subscriber.flush()
        XCTAssertEqual(AgaraDataChange.shared.token, token)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PulseLoop.Measurement>()), 1)
    }

    /// Non-data events (a measurement-complete marker, a charging flag) no longer schedule a save.
    func testNonDataEventsDoNotSignalAChange() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let token = AgaraDataChange.shared.token
        subscriber.persist(.heartRateComplete(timestamp: Date()))
        subscriber.persist(.chargingState(false))
        subscriber.flush()
        XCTAssertEqual(AgaraDataChange.shared.token, token)
    }

    // MARK: Rate limits

    func testHealthActivityExportIsSpacedFifteenMinutesForToday() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(HealthSyncService.shouldExportActivity(todayOnly: true, lastExportAt: nil, now: t0))
        XCTAssertFalse(HealthSyncService.shouldExportActivity(todayOnly: true, lastExportAt: t0, now: t0.addingTimeInterval(14 * 60)))
        XCTAssertTrue(HealthSyncService.shouldExportActivity(todayOnly: true, lastExportAt: t0, now: t0.addingTimeInterval(15 * 60)))
        XCTAssertTrue(HealthSyncService.shouldExportActivity(todayOnly: false, lastExportAt: t0, now: t0.addingTimeInterval(60)),
                      "a finished day always goes out")
    }

    func testWidgetDataChangeBuildsAreFiveMinutesApart() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(WidgetSnapshotPublisher.dataChangeDelay(lastBuildAt: nil, now: t0), 0)
        XCTAssertEqual(WidgetSnapshotPublisher.dataChangeDelay(lastBuildAt: t0, now: t0.addingTimeInterval(60)), 240, accuracy: 0.01)
        XCTAssertEqual(WidgetSnapshotPublisher.dataChangeDelay(lastBuildAt: t0, now: t0.addingTimeInterval(400)), 0)
    }

    // MARK: Retention

    func testAuditTablesKeepAWeek() throws {
        let context = try TestSupport.makeContext()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        context.insert(DerivedUpdateRow(timestamp: now.addingTimeInterval(-8 * 86_400), kind: "old", entityType: "x", entityId: "1"))
        context.insert(DerivedUpdateRow(timestamp: now.addingTimeInterval(-86_400), kind: "new", entityType: "x", entityId: "2"))
        context.insert(WearableLog(timestamp: now.addingTimeInterval(-30 * 86_400), category: .connection, level: .info, message: "old"))
        context.insert(WearableLog(timestamp: now, category: .connection, level: .info, message: "new"))
        try context.save()
        DebugRepository.pruneAuditTables(now: now, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DerivedUpdateRow>()).map(\.kind), ["new"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<WearableLog>()).map(\.message), ["new"])
    }

    // MARK: Charts

    /// Long ranges read the whole window: 20 days of per-minute history must show up across the 30-day
    /// chart, not just its newest ~3.5 days (the old newest-5000-rows read).
    func testThirtyDayRangeCoversTheWholeWindow() throws {
        let context = try TestSupport.makeContext()
        let now = Date()
        for day in 0..<20 {
            for minute in stride(from: 0, to: 1440, by: 3) {   // 480 rows a day, 9 600 in total
                let ts = now.addingTimeInterval(-Double(day) * 86_400 - Double(minute) * 60)
                context.insert(PulseLoop.Measurement(kind: .heartRate, value: Double(60 + day), unit: "bpm",
                                                     timestamp: ts, source: .history))
            }
        }
        try context.save()
        let plan = try XCTUnwrap(MetricsService.SampledRange.plan(for: .thirtyDays))
        let samples = MetricsService.sampledAverages(kind: .heartRate, start: now.addingTimeInterval(-30 * 86_400),
                                                     end: now, plan: plan, context: context)
        let oldest = try XCTUnwrap(samples.first?.timestamp)
        XCTAssertLessThan(oldest, now.addingTimeInterval(-18 * 86_400), "the oldest days are represented")
        XCTAssertLessThanOrEqual(samples.count, plan.buckets)
        XCTAssertEqual(samples.map(\.value).max() ?? 0, 79, accuracy: 1)
        XCTAssertEqual(samples.map(\.value).min() ?? 0, 60, accuracy: 1)
    }

    func testChartSamplesHaveStableIdsAndAreCapped() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(MetricSample(timestamp: t, value: 70).id, MetricSample(timestamp: t, value: 70).id)
        let many = (0..<5_000).map { MetricSample(timestamp: t.addingTimeInterval(Double($0) * 5), value: 70) }
        XCTAssertLessThanOrEqual(MetricsService.displaySamples(many, range: .twentyFourHours).count,
                                 MetricsService.maxChartPoints)
    }

    // MARK: BLE

    func testScanNarrowsAfterItsWindowAndReconnectBacksOff() {
        XCTAssertEqual(RingBLEClient.scanAfterTimeout(mode: .pairing), .filtered)
        XCTAssertEqual(RingBLEClient.scanAfterTimeout(mode: .reconnect), .stop)
        XCTAssertEqual(RingBLEClient.scanTimeoutSeconds, 30)
        XCTAssertEqual((0..<9).map { RingBLEClient.reconnectDelay(attempt: $0) }, [0, 2, 4, 8, 16, 32, 60, 60, 60])
    }
}
