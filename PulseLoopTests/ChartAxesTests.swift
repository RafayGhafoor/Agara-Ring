import XCTest
@testable import PulseLoop

/// The detail/card chart rules (docs/process/plans/ui-charts-sleep.md). Same cases as Android `ChartAxesTest`.
final class ChartAxesTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Karachi")!
        return c
    }()
    private func at(_ h: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: h, minute: m))!
    }

    func testTheDayWindowIsTheCalendarDay() {
        let window = ChartAxes.dayWindow(at(14, 37), calendar: calendar)
        XCTAssertEqual(window.lowerBound, at(0, 0))
        XCTAssertEqual(window.upperBound, at(0, 0).addingTimeInterval(ChartAxes.day))
    }

    func testHalfHourAveragesSmoothAndKeepGaps() {
        let samples = [(at(0, 1), 60.0), (at(0, 20), 70), (at(0, 29), 80), (at(0, 31), 90), (at(3, 5), 50)]
            .map { MetricSample(timestamp: $0.0, value: $0.1) }
        let out = ChartAxes.bucketAverage(samples, bucket: ChartAxes.halfHour, calendar: calendar)
        XCTAssertEqual(out.map(\.timestamp), [at(0, 15), at(0, 45), at(3, 15)])
        XCTAssertEqual(out.map(\.value), [70, 90, 50])
    }

    func testBloodPressureGroupsIntoHourlyBarsFromLowestDiastolicToHighestSystolic() {
        let sys = [(at(8, 0), 120.0), (at(8, 5), 128), (at(8, 10), 200), (at(9, 0), 115)]
            .map { MetricSample(timestamp: $0.0, value: $0.1) }
        let dia = [(at(8, 0), 82.0), (at(8, 5), 78), (at(9, 0), 75)]     // 08:10 has no diastolic: skipped
            .map { MetricSample(timestamp: $0.0, value: $0.1) }
        let out = ChartAxes.rangeBuckets(systolic: sys, diastolic: dia, bucket: ChartAxes.hour, calendar: calendar)
        XCTAssertEqual(out, [ChartAxes.RangeBucket(time: at(8, 30), low: 78, high: 128),
                             ChartAxes.RangeBucket(time: at(9, 30), low: 75, high: 115)])
    }

    func testFixedAxesStayPutAndOnlyWidenByWholeTicks() {
        XCTAssertEqual(ChartAxes.fixedAxis(.heartRate, data: [50, 117]), ChartAxis(min: 40, max: 120, ticks: [40, 60, 80, 100, 120]))
        XCTAssertEqual(ChartAxes.fixedAxis(.heartRate, data: [50, 131]), ChartAxis(min: 40, max: 140, ticks: [40, 60, 80, 100, 120, 140]))
        XCTAssertEqual(ChartAxes.fixedAxis(.spo2, data: [96, 99])?.ticks, [70, 80, 90, 100])
        XCTAssertEqual(ChartAxes.fixedAxis(.bloodPressure, data: [83, 120])?.ticks, [60, 100, 140, 180])
        XCTAssertNil(ChartAxes.fixedAxis(.glucose, data: [5]))
    }

    func testNiceAxesUseRoundTicks() {
        XCTAssertEqual(ChartAxes.niceAxis([0, 53], zeroBased: true).ticks, [0, 20, 40, 60])
        XCTAssertEqual(ChartAxes.niceAxis([4.2, 6.9]).ticks, [4, 5, 6, 7])
    }
}
