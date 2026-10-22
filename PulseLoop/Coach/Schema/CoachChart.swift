import Foundation

/// Chart spec with data embedded directly (no refetch on render). Built by the
/// `prepare_chart` tool in Swift and copied verbatim into `CoachResponse.chart`
/// by the model — ports `CoachChartSpec` from the web app.
struct CoachChart: Codable, Equatable {
    var chartType: CoachChartType
    var title: String
    var metric: CoachChartMetric
    var range: CoachChartRange
    var data: [CoachChartPoint]
    var annotations: [CoachChartAnnotation]

    enum CodingKeys: String, CodingKey {
        case chartType = "chart_type"
        case title, metric, range, data, annotations
    }

    init(
        chartType: CoachChartType,
        title: String,
        metric: CoachChartMetric,
        range: CoachChartRange,
        data: [CoachChartPoint] = [],
        annotations: [CoachChartAnnotation] = []
    ) {
        self.chartType = chartType
        self.title = title
        self.metric = metric
        self.range = range
        self.data = data
        self.annotations = annotations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartType = try c.decode(CoachChartType.self, forKey: .chartType)
        title = try c.decode(String.self, forKey: .title)
        metric = try c.decode(CoachChartMetric.self, forKey: .metric)
        range = try c.decode(CoachChartRange.self, forKey: .range)
        data = Self.plausible(try c.decodeIfPresent([CoachChartPoint].self, forKey: .data) ?? [])
        annotations = Array((try c.decodeIfPresent([CoachChartAnnotation].self, forKey: .annotations) ?? [])
            .prefix(Self.maxPoints))
    }

    /// The chart is model output (copied from `prepare_chart` by the model), and fresh answers and stored
    /// conversations both decode here. Rendering converts values with `Int(_:)`, which TRAPS beyond ±9.2e18 or on a
    /// non-finite value, so a single `1e308` would crash the app every time that conversation opened. No metric we
    /// chart comes near 10 million; 1,500 points is ~5× a raw heart-rate day. Pre-TestFlight audit, 2026-10-22.
    static let maxAbsValue = 10_000_000.0
    static let maxPoints = 1_500

    static func plausible(_ points: [CoachChartPoint]) -> [CoachChartPoint] {
        Array(points.lazy.filter { $0.y.isFinite && abs($0.y) <= maxAbsValue }.prefix(maxPoints))
    }
}

enum CoachChartType: String, Codable {
    case line, bar, dot, sleepStage = "sleep_stage", sparkline
}

/// Every metric the coach can fetch, analyse and chart — ONE list (the tools' enums, `from(_:)`, the server's
/// `tools.json` and `response_schema.json` all derive from it; `CoachToolCatalogTests` keeps the server in step).
/// Coach insights (2026-10-22) added the series the ring records but the coach could not see. Not here on purpose:
/// HRV (decoding unvalidated), blood pressure, glucose and blood components (optical estimates, owner decision D1).
enum CoachChartMetric: String, Codable, CaseIterable {
    case steps, hr, spo2, sleep, activeMinutes = "active_minutes", calories, distance
    /// Daily mean of the ring's stress readings (0–100).
    case stress
    /// Per night: the lowest heart rate during the main sleep (the nudge engine's rule).
    case restingHr = "resting_hr"
    /// Daily mean of the sampled respiration rate (breaths/min).
    case respRate = "resp_rate"
    /// Minutes at MET ≥ 3 (5-minute records).
    case intensityMinutes = "intensity_minutes"
    /// The day's sleep score (night + naps).
    case sleepScore = "sleep_score"
    /// Main sleep start, minutes from midnight (negative = the evening before).
    case bedtime
    /// Main sleep end, minutes after midnight.
    case wakeTime = "wake_time"
    /// Awake minutes inside the day's sleep (night + naps).
    case sleepAwake = "sleep_awake"

    /// Metrics whose value is a clock time (minutes from midnight).
    var isClockTime: Bool { self == .bedtime || self == .wakeTime }
}

struct CoachChartRange: Codable, Equatable {
    var start: String
    var end: String
}

/// One plotted point. `series` categorizes multi-series data (e.g. sleep-stage
/// name); nil for single-series charts.
struct CoachChartPoint: Codable, Equatable, Identifiable {
    var x: String
    var y: Double
    var series: String?
    var id: String { x + (series ?? "") }
}

struct CoachChartAnnotation: Codable, Equatable, Identifiable {
    var x: String
    var label: String
    var id: String { x + label }
}
