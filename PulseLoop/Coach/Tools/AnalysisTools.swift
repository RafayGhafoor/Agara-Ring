import Foundation
import SwiftData

/// Deterministic analysis tools backed by `AnalysisEngine` — the iOS stand-in
/// for the web app's Python sandbox. No arbitrary code execution.
@MainActor
enum AnalysisTools {
    static var all: [AnyCoachTool] {
        [analyzeTrend, comparePeriods, computeCorrelation, detectOutliers, summarizeDistribution]
    }

    private static var metricEnum: [String] { CoachChartMetric.toolEnum }

    private struct MetricRangeArg: Decodable { let metric: String, start: String, end: String }

    private static var analyzeTrend: AnyCoachTool {
        .make(
            name: "analyze_trend",
            label: "Analyzing the trend",
            description: "Compute the trend (direction, slope, change) of a metric over a date range.",
            parameters: JSONSchema.object([
                "metric": JSONSchema.enumString(metricEnum),
                "start": JSONSchema.string, "end": JSONSchema.string,
            ], required: ["metric", "start", "end"]),
            argsType: MetricRangeArg.self
        ) { args, ctx in
            guard let metric = CoachChartMetric.from(args.metric) else { return .error("unknown metric '\(args.metric)'") }
            let series = CoachDataAccess.dailySeries(metric: metric, start: args.start, end: args.end, context: ctx.modelContext)
            return .encoding(Covered(result: AnalysisEngine.trend(series), coverage: [
                "coverage": CoachDataAccess.coverage(metric: metric, start: args.start, end: args.end, context: ctx.modelContext)]))
        }
    }

    private struct ComparePeriodsArg: Decodable {
        let metric: String
        let periodAStart: String, periodAEnd: String
        let periodBStart: String, periodBEnd: String
        enum CodingKeys: String, CodingKey {
            case metric
            case periodAStart = "period_a_start", periodAEnd = "period_a_end"
            case periodBStart = "period_b_start", periodBEnd = "period_b_end"
        }
    }

    private static var comparePeriods: AnyCoachTool {
        .make(
            name: "compare_periods",
            label: "Comparing two periods",
            description: "Compare the average of a metric between two date ranges (period A vs period B).",
            parameters: JSONSchema.object([
                "metric": JSONSchema.enumString(metricEnum),
                "period_a_start": JSONSchema.string, "period_a_end": JSONSchema.string,
                "period_b_start": JSONSchema.string, "period_b_end": JSONSchema.string,
            ], required: ["metric", "period_a_start", "period_a_end", "period_b_start", "period_b_end"]),
            argsType: ComparePeriodsArg.self
        ) { args, ctx in
            guard let metric = CoachChartMetric.from(args.metric) else { return .error("unknown metric '\(args.metric)'") }
            let a = CoachDataAccess.dailySeries(metric: metric, start: args.periodAStart, end: args.periodAEnd, context: ctx.modelContext).map(\.value)
            let b = CoachDataAccess.dailySeries(metric: metric, start: args.periodBStart, end: args.periodBEnd, context: ctx.modelContext).map(\.value)
            return .encoding(Covered(result: AnalysisEngine.comparePeriods(a: a, b: b), coverage: [
                "coverage_a": CoachDataAccess.coverage(metric: metric, start: args.periodAStart, end: args.periodAEnd, context: ctx.modelContext),
                "coverage_b": CoachDataAccess.coverage(metric: metric, start: args.periodBStart, end: args.periodBEnd, context: ctx.modelContext)]))
        }
    }

    private struct CorrelationArg: Decodable {
        let metricA: String, metricB: String, start: String, end: String
        enum CodingKeys: String, CodingKey {
            case metricA = "metric_a", metricB = "metric_b", start, end
        }
    }

    private static var computeCorrelation: AnyCoachTool {
        .make(
            name: "compute_correlation",
            label: "Checking for a relationship",
            description: "Compute the day-aligned correlation between two metrics over a date range (e.g. steps vs sleep).",
            parameters: JSONSchema.object([
                "metric_a": JSONSchema.enumString(metricEnum),
                "metric_b": JSONSchema.enumString(metricEnum),
                "start": JSONSchema.string, "end": JSONSchema.string,
            ], required: ["metric_a", "metric_b", "start", "end"]),
            argsType: CorrelationArg.self
        ) { args, ctx in
            guard let ma = CoachChartMetric.from(args.metricA), let mb = CoachChartMetric.from(args.metricB) else {
                return .error("unknown metric")
            }
            let seriesA = CoachDataAccess.dailySeries(metric: ma, start: args.start, end: args.end, context: ctx.modelContext)
            let seriesB = CoachDataAccess.dailySeries(metric: mb, start: args.start, end: args.end, context: ctx.modelContext)
            let cal = Calendar.current
            let mapB = Dictionary(seriesB.map { (cal.startOfDay(for: $0.date), $0.value) }, uniquingKeysWith: { a, _ in a })
            let pairs: [(Double, Double)] = seriesA.compactMap { item in
                guard let bv = mapB[cal.startOfDay(for: item.date)] else { return nil }
                return (item.value, bv)
            }
            return .encoding(Covered(result: AnalysisEngine.correlation(pairs), coverage: [
                "coverage_a": CoachDataAccess.coverage(metric: ma, start: args.start, end: args.end, context: ctx.modelContext),
                "coverage_b": CoachDataAccess.coverage(metric: mb, start: args.start, end: args.end, context: ctx.modelContext)]))
        }
    }

    private static var detectOutliers: AnyCoachTool {
        .make(
            name: "detect_outliers",
            label: "Looking for outliers",
            description: "Find statistical outliers (z-score ≥ 2) in a metric over a date range.",
            parameters: JSONSchema.object([
                "metric": JSONSchema.enumString(metricEnum),
                "start": JSONSchema.string, "end": JSONSchema.string,
            ], required: ["metric", "start", "end"]),
            argsType: MetricRangeArg.self
        ) { args, ctx in
            guard let metric = CoachChartMetric.from(args.metric) else { return .error("unknown metric '\(args.metric)'") }
            let series = CoachDataAccess.dailySeries(metric: metric, start: args.start, end: args.end, context: ctx.modelContext)
            let coverage = CoachDataAccess.coverage(metric: metric, start: args.start, end: args.end, context: ctx.modelContext)
            return .object(["metric": args.metric, "outliers": AnalysisEngine.outliers(series).map {
                ["date": $0.date, "value": $0.value, "z": $0.zScore]
            }, "coverage": ["days_in_range": coverage.daysInRange, "days_with_data": coverage.daysWithData,
                            "readings": coverage.readings, "sparse": coverage.sparse]])
        }
    }

    private static var summarizeDistribution: AnyCoachTool {
        .make(
            name: "summarize_distribution",
            label: "Summarizing the distribution",
            description: "Compute count, mean, median, min, max, stddev, and quartiles for a metric over a date range.",
            parameters: JSONSchema.object([
                "metric": JSONSchema.enumString(metricEnum),
                "start": JSONSchema.string, "end": JSONSchema.string,
            ], required: ["metric", "start", "end"]),
            argsType: MetricRangeArg.self
        ) { args, ctx in
            guard let metric = CoachChartMetric.from(args.metric) else { return .error("unknown metric '\(args.metric)'") }
            let values = CoachDataAccess.dailySeries(metric: metric, start: args.start, end: args.end, context: ctx.modelContext).map(\.value)
            return .encoding(Covered(result: AnalysisEngine.distribution(values), coverage: [
                "coverage": CoachDataAccess.coverage(metric: metric, start: args.start, end: args.end, context: ctx.modelContext)]))
        }
    }
}

/// An analysis result with its coverage beside it: the result's own fields stay where they were, plus `coverage`
/// (or `coverage_a` / `coverage_b`), so the coach always knows how much data stood behind the number (use case 12).
struct Covered<T: Encodable>: Encodable {
    let result: T
    let coverage: [String: CoachDataAccess.Coverage]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        try result.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        for (key, value) in coverage { try container.encode(value, forKey: Key(key)) }
    }
}
