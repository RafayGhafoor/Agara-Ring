import Foundation

/// A fixed y-axis: the drawn range and its gridline values, bottom to top.
struct ChartAxis: Equatable {
    let min: Double
    let max: Double
    let ticks: [Double]
    var domain: ClosedRange<Double> { min...max }
}

/// The shared rules behind the detail and card charts, set after comparing against the vendor app on the
/// same ring (docs/process/plans/ui-charts-sleep.md). It draws the day 12am–12am on a **fixed** axis with
/// **30-minute averages**, so the line doesn't jump around, and so the axis doesn't rescale on every
/// reading. Mirrors Android `ChartAxes.kt` rule for rule; `ChartAxesTests` runs the same cases.
enum ChartAxes {
    static let halfHour: TimeInterval = 30 * 60
    /// More readings than this in a day (one per half hour) and a spot metric is averaged too.
    static let denseDayReadings = 48
    static let hour: TimeInterval = 60 * 60
    static let day: TimeInterval = 24 * 60 * 60

    /// How each metric's detail chart is drawn: continuous signals as a line of averages, spot readings as
    /// dots, blood pressure as a range bar per reading, counts as bars.
    enum Style { case line, dots, rangeBars, bars }

    static func style(for metric: MetricKind) -> Style {
        switch metric {
        case .spo2, .glucose, .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid: return .dots
        case .bloodPressure: return .rangeBars
        default: return .line
        }
    }

    /// Whether the chart averages this metric per bucket (a continuous signal) rather than plotting readings.
    static func isContinuous(_ metric: MetricKind) -> Bool {
        [.heartRate, .hrv, .stress, .respiration, .met, .cardiacLoad].contains(metric)
    }

    /// The local calendar day containing `anchor`: `[midnight, next midnight)`.
    static func dayWindow(_ anchor: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: anchor)
        return start...(calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(day))
    }

    /// Mean per bucket, buckets aligned to local midnight, each stamped at its midpoint. Empty buckets are
    /// skipped, so a gap in wear stays a gap.
    static func bucketAverage(_ samples: [MetricSample], bucket: TimeInterval,
                              calendar: Calendar = .current) -> [MetricSample] {
        var groups: [Date: [Double]] = [:]
        for s in samples {
            let midnight = calendar.startOfDay(for: s.timestamp)
            let index = floor(s.timestamp.timeIntervalSince(midnight) / bucket)
            groups[midnight.addingTimeInterval(index * bucket), default: []].append(s.value)
        }
        return groups.keys.sorted().map { start in
            let values = groups[start]!
            return MetricSample(timestamp: start.addingTimeInterval(bucket / 2),
                                value: values.reduce(0, +) / Double(values.count))
        }
    }

    /// One blood-pressure bar per bucket.
    struct RangeBucket: Equatable {
        let time: Date
        let low: Double
        let high: Double
    }

    /// Systolic/diastolic pairs (matched by timestamp) grouped per bucket: each bar spans the bucket's lowest
    /// diastolic to its highest systolic, stamped at the bucket's midpoint. One bar per reading merged into a
    /// solid block when readings came every 5 minutes; the reference app draws one bar per hour.
    static func rangeBuckets(systolic: [MetricSample], diastolic: [MetricSample], bucket: TimeInterval,
                             calendar: Calendar = .current) -> [RangeBucket] {
        let diaAt = Dictionary(diastolic.map { ($0.timestamp, $0.value) }, uniquingKeysWith: { a, _ in a })
        var groups: [Date: [(sys: Double, dia: Double)]] = [:]
        for s in systolic {
            guard let d = diaAt[s.timestamp] else { continue }
            let midnight = calendar.startOfDay(for: s.timestamp)
            let index = floor(s.timestamp.timeIntervalSince(midnight) / bucket)
            groups[midnight.addingTimeInterval(index * bucket), default: []].append((s.value, d))
        }
        return groups.keys.sorted().map { start in
            let v = groups[start]!
            return RangeBucket(time: start.addingTimeInterval(bucket / 2),
                               low: v.map(\.dia).min()!, high: v.map(\.sys).max()!)
        }
    }

    /// The fixed axis for a metric, widened (by whole ticks) only if the data falls outside it. Nil for metrics
    /// whose unit follows the user's settings (glucose, temperature); those use `niceAxis`.
    static func fixedAxis(_ metric: MetricKind, data: [Double]) -> ChartAxis? {
        let (lo, hi, step): (Double, Double, Double)
        switch metric {
        case .heartRate: (lo, hi, step) = (40, 120, 20)
        case .spo2: (lo, hi, step) = (70, 100, 10)
        case .bloodPressure: (lo, hi, step) = (60, 180, 40)
        case .hrv: (lo, hi, step) = (0, 150, 50)
        case .stress: (lo, hi, step) = (0, 100, 25)
        case .respiration: (lo, hi, step) = (0, 30, 10)
        case .met: (lo, hi, step) = (0, 6, 2)
        case .cardiacLoad: (lo, hi, step) = (0, 60, 20)
        default: return nil
        }
        let minV = Swift.min(lo, data.min().map { floor($0 / step) * step } ?? lo)
        let maxV = Swift.max(hi, data.max().map { ceil($0 / step) * step } ?? hi)
        return ChartAxis(min: minV, max: maxV, ticks: ticks(minV, maxV, step))
    }

    /// Round ticks around `data`: a 1/2/5 × 10ⁿ step giving about four intervals; counts start at 0.
    static func niceAxis(_ data: [Double], zeroBased: Bool = false) -> ChartAxis {
        let lo = zeroBased ? 0 : (data.min() ?? 0)
        let hi = data.max() ?? 1
        let span = hi - lo > 0 ? hi - lo : Swift.max(1, abs(hi) * 0.1)
        let raw = span / 4
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        let minV = floor(lo / step) * step
        var maxV = ceil(hi / step) * step
        if maxV <= minV { maxV = minV + step }
        return ChartAxis(min: minV, max: maxV, ticks: ticks(minV, maxV, step))
    }

    private static func ticks(_ min: Double, _ max: Double, _ step: Double) -> [Double] {
        stride(from: min, through: max + step / 1000, by: step).map { $0 }
    }
}
