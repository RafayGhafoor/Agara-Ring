import XCTest
import SwiftData
@testable import PulseLoop

/// Pure-logic coverage for the measurement-frequency feature: the per-device config ↔ settings mapping,
/// capability gating, vital-visibility, the graph downsampler, and the user-profile value mapping. None
/// of these need hardware.
@MainActor
final class MeasurementSettingsTests: XCTestCase {

    // MARK: - Config ↔ settings mapping

    func testConfigProjectsToSettings() {
        let config = DeviceMeasurementConfig(deviceId: UUID())
        config.hrIntervalMinutes = 15
        config.spo2Enabled = false
        let settings = config.asSettings
        XCTAssertEqual(settings.hrIntervalMinutes, 15)
        XCTAssertFalse(settings.spo2Enabled)
        XCTAssertTrue(settings.hrvEnabled)
    }

    func testConfigRepositoryUpsertsOnce() throws {
        let context = try TestSupport.makeContext()
        let deviceId = UUID()
        let first = MeasurementConfigRepository.configOrDefault(deviceId: deviceId, context: context)
        first.hrIntervalMinutes = 30
        MeasurementConfigRepository.save(first, context: context)
        // Second fetch returns the same row (no duplicate insert).
        let second = MeasurementConfigRepository.configOrDefault(deviceId: deviceId, context: context)
        XCTAssertEqual(second.hrIntervalMinutes, 30)
        let all = (try? context.fetch(FetchDescriptor<DeviceMeasurementConfig>())) ?? []
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Capability gating

    /// No measurement-interval knob: this ring's all-day logging is armed by the connect handshake, so it
    /// does not declare the capability and the Measurement settings screen hides that control.
    func testTheAgaraRingHasNoMeasurementIntervalKnob() {
        XCTAssertFalse(VeepooCoordinator().capabilities.contains(.measurementInterval))
    }

    /// The on-demand BP commands (`90 01 00` / `90 00 00`) are verified against the ring, and DF `B8`
    /// carries the systolic/diastolic pair in history — so the measure button and the metric card are
    /// both earned rather than promised.
    func testManualBloodPressureIsADeclaredCapability() {
        let coordinator = VeepooCoordinator()
        XCTAssertTrue(coordinator.capabilities.contains(.manualBloodPressure))
        XCTAssertTrue(coordinator.capabilities.contains(.bloodPressure))
        XCTAssertTrue(coordinator.bitmapGatedCapabilities.isEmpty, "nothing here is bitmap-gated")
    }

    /// This ring measures one vital at a time, so the Vitals screen keeps a button per metric instead of
    /// collapsing them into a single "Measure Vitals" action.
    func testCombinedVitalsMeasurementIsNotDeclared() {
        XCTAssertFalse(VeepooCoordinator().capabilities.contains(.combinedVitalsMeasurement))
    }

    // MARK: - Vital visibility (capability first, then user opt-out)

    func testHiddenVitalIsNotVisibleButUnsupportedStillFalse() throws {
        let context = try TestSupport.makeContext()
        context.insert(Device(
            deviceType: .veepoo,
            capabilities: [.heartRate, .spo2, .steps, .sleep, .battery, .stress, .hrv, .temperature]
        ))
        try context.save()

        let store = MetricPrefsStore(defaults: makeEphemeralDefaults())
        // Supported + not hidden → visible.
        XCTAssertTrue(MetricsService.supports(.hrv, context: context))
        XCTAssertFalse(store.isHidden(.hrv))
        // Hiding a supported metric makes it not visible (but supports() is unchanged).
        store.setHidden(.hrv, true)
        XCTAssertTrue(store.isHidden(.hrv))
        XCTAssertTrue(MetricsService.supports(.hrv, context: context))
    }

    func testGraphResolutionFullIsIdentity() {
        XCTAssertEqual(GraphResolution.full.targetBuckets(for: .twentyFourHours), 0)
        XCTAssertGreaterThan(GraphResolution.smooth.targetBuckets(for: .twentyFourHours), 0)
    }

    // MARK: - Downsampler

    func testDownsamplerIdentityWhenTargetIsZeroOrFewerPoints() {
        let samples = (0..<10).map { MetricSample(timestamp: Date().addingTimeInterval(Double($0) * 60), value: Double($0)) }
        XCTAssertEqual(MetricDownsampler.bucketAverage(samples, targetBuckets: 0).count, 10)
        XCTAssertEqual(MetricDownsampler.bucketAverage(samples, targetBuckets: 20).count, 10)
    }

    func testDownsamplerBucketAveragesAndReducesCount() {
        let start = Date()
        // 100 points over ~100 minutes, value == index.
        let samples = (0..<100).map { MetricSample(timestamp: start.addingTimeInterval(Double($0) * 60), value: Double($0)) }
        let reduced = MetricDownsampler.bucketAverage(samples, targetBuckets: 10)
        XCTAssertLessThanOrEqual(reduced.count, 10)
        XCTAssertGreaterThan(reduced.count, 1)
        // Averaging the ascending series keeps the overall mean roughly centered.
        let mean = reduced.map(\.value).reduce(0, +) / Double(reduced.count)
        XCTAssertEqual(mean, 49.5, accuracy: 5)
        // Buckets are ordered by time.
        let timestamps = reduced.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted())
    }

    func testDownsamplerCollapsesSameTimestampToMean() {
        let t = Date()
        let samples = [10.0, 20.0, 30.0].map { MetricSample(timestamp: t, value: $0) }
        let reduced = MetricDownsampler.bucketAverage(samples, targetBuckets: 2)
        XCTAssertEqual(reduced.count, 1)
        XCTAssertEqual(reduced.first?.value, 20.0)
    }

    // MARK: - User profile mapping

    func testUserProfileValuesMapSexAndClamps() {
        let female = UserProfileValues(metric: true, sex: "Female", age: 40, heightCm: 165, weightKg: 60)
        XCTAssertEqual(female.gender, 0x00)
        let male = UserProfileValues(metric: false, sex: "male", age: 30, heightCm: 180, weightKg: 80)
        XCTAssertEqual(male.gender, 0x01)
        XCTAssertFalse(male.metric)
        let other = UserProfileValues(metric: true, sex: nil, age: nil, heightCm: nil, weightKg: nil)
        XCTAssertEqual(other.gender, 0x02)
        XCTAssertEqual(other.age, 25)   // neutral fallback
    }

    func testUnitsFormatterTemperature() {
        XCTAssertEqual(UnitsFormatter.temperature(celsius: 36.5, units: .metric).unit, "°C")
        let imperial = UnitsFormatter.temperature(celsius: 36.5, units: .imperial)
        XCTAssertEqual(imperial.unit, "°F")
        XCTAssertEqual(Double(imperial.value) ?? 0, 97.7, accuracy: 0.1)
    }

    private func makeEphemeralDefaults() -> UserDefaults {
        // A bare UUID suite name (matching the Coach tests) — a dotted/prefixed suite name can abort
        // `UserDefaults(suiteName:)` on stricter CI runners.
        UserDefaults(suiteName: UUID().uuidString)!
    }
}
