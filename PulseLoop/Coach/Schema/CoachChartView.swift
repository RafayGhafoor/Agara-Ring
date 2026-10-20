import SwiftUI
import Charts

/// Renders a `CoachChart` whose data is already embedded (computed by the `prepare_chart` tool).
///
/// Built on the app's **one chart component** (`AgaraChart`, AGENTS Rule 10), like every other graph in the app: the
/// wrapper owns the scrub/tap tooltip, the empty state, the accessibility summary and the frame height, and this view
/// only supplies the marks, the scales and the coach's per-metric value labels. Before 1.1 it drew its own `Chart`
/// with no tooltip, so a coach chart could not be scrubbed and its values were unreadable to VoiceOver — the audit in
/// the 1.1 coach plan flagged it (`CoachChartView` vs `AgaraChart`).
///
/// Two things stay coach-specific and belong here, not in the shared component: the *data* (`CoachChartPoint` carries
/// x as the server's own label string) and the metric colours/labels. `sleep_stage` keeps the Sleep page's
/// hypnogram (`SleepStageBar`), which is the shared component for that shape.
struct CoachChartView: View {
    let chart: CoachChart
    var height: CGFloat = 170

    private var color: Color {
        switch chart.metric {
        case .steps: return AgaraColors.steps
        case .hr: return AgaraColors.heartRate
        case .spo2: return AgaraColors.spo2
        case .sleep: return AgaraColors.sleep
        case .activeMinutes: return AgaraColors.accent
        case .calories: return AgaraColors.calories
        case .distance: return AgaraColors.distance
        }
    }

    /// The shared component's empty state: the coach's own sentence, at the chart's height.
    private var emptyState: AgaraChartEmpty {
        AgaraChartEmpty(text: "No data to plot for this range.", minimumPoints: 1, minHeight: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chart.title)
                .font(AgaraFont.caption)
                .foregroundStyle(AgaraColors.textSecondary)

            if chart.chartType == .sleepStage {
                sleepHypnogram
            } else {
                plot
            }

            if !chart.annotations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chart.annotations) { a in
                        Text("• \(a.label)")
                            .font(AgaraFont.caption2.weight(.regular))
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Solid card fill, not glass: this chart card renders inside the assistant bubble's
        // glass, and glass can't sample glass (renders flat). A card fill + hairline keeps it
        // reading as a distinct raised surface.
        .background(AgaraColors.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AgaraColors.textPrimary.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Standard plot (line / dot / bar / sparkline)

    /// Line, dot and sparkline plot against the point's index: heterogeneous x labels (days, minutes) stay evenly
    /// spaced instead of collapsing onto one another. The label still reaches the tooltip through `detailText`.
    @ViewBuilder private var plot: some View {
        switch chart.chartType {
        case .line, .dot, .sparkline:
            let points = chart.data.enumerated().map { index, point in
                AgaraChartPoint(x: index, y: point.y, detailText: point.x)
            }
            AgaraChart(points: points,
                       height: height,
                       empty: emptyState,
                       accessibilityTitle: chart.title,
                       valueLabel: { Self.valueLabel($0, metric: chart.metric) },
                       xLabel: { index in chart.data.indices.contains(index) ? chart.data[index].x : "" }) {
                ForEach(Array(chart.data.enumerated()), id: \.offset) { index, point in
                    switch chart.chartType {
                    case .line:
                        LineMark(x: .value("i", index), y: .value("y", point.y))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .foregroundStyle(color)
                        if chart.data.count <= 8 {
                            PointMark(x: .value("i", index), y: .value("y", point.y))
                                .symbolSize(20)
                                .foregroundStyle(color)
                        }
                    case .sparkline:
                        LineMark(x: .value("i", index), y: .value("y", point.y))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .foregroundStyle(color)
                    default:
                        PointMark(x: .value("i", index), y: .value("y", point.y))
                            .symbolSize(34)
                            .foregroundStyle(color)
                    }
                }
            }
            // The y-axis autoscales to the data (trend charts never get forced through 0), and spo2 is clamped to
            // ≤100 — see `yDomain`, which is pure so it stays unit-tested.
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                if chart.chartType != .sparkline { axisMarks }
            }

        case .bar:
            let points = chart.data.map { AgaraChartPoint(x: $0.x, y: $0.y) }
            AgaraChart(points: points,
                       height: height,
                       empty: emptyState,
                       accessibilityTitle: chart.title,
                       valueLabel: { Self.valueLabel($0, metric: chart.metric) },
                       xLabel: { $0 }) {
                ForEach(chart.data, id: \.id) { point in
                    BarMark(x: .value("x", point.x), y: .value("y", point.y))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                        .foregroundStyle(color.opacity(0.85))
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(6, chart.data.count))) { _ in
                    AxisValueLabel().font(AgaraFont.nano.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                }
            }
            .chartYAxis { axisMarks }

        case .sleepStage:
            EmptyView()  // handled by `sleepHypnogram`
        }
    }

    private var axisMarks: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(AgaraColors.borderSubtle)
            AxisValueLabel().font(AgaraFont.nano.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
        }
    }

    /// The tooltip's value line, in the metric's unit ("7,912" steps, "62 bpm", "7h 12m").
    static func valueLabel(_ value: Double, metric: CoachChartMetric) -> String {
        switch metric {
        case .steps: return Int(value.rounded()).formatted()
        case .hr: return "\(Int(value.rounded())) bpm"
        case .spo2: return "\(Int(value.rounded()))%"
        case .sleep: return SleepFormat.duration(Int(value.rounded()))
        case .activeMinutes: return "\(Int(value.rounded())) min"
        case .calories: return "\(Int(value.rounded())) kcal"
        case .distance: return String(format: "%.1f km", value)
        }
    }

    private var yDomain: ClosedRange<Double> {
        CoachChartView.yDomain(values: chart.data.map(\.y), chartType: chart.chartType, metric: chart.metric)
    }

    /// Data-hugging y-domain. Magnitude bars stay 0-based; trends pad around the
    /// data; hr/spo2 always autoscale (a 0 baseline is meaningless for them) and
    /// spo2 is clamped to ≤100. Pure + static so it can be unit-tested.
    static func yDomain(values: [Double], chartType: CoachChartType, metric: CoachChartMetric) -> ClosedRange<Double> {
        // Model output is untrusted: drop NaN/∞ (they make any range invalid) and never build a
        // `ClosedRange` whose lower bound exceeds its upper — that traps. Negative magnitudes (a model
        // emitting "-200 kcal") used to produce `0...negative`.
        let finite = values.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return 0...1 }

        let magnitudeBar = chartType == .bar
            && [.steps, .calories, .distance, .activeMinutes, .sleep].contains(metric)

        var lower: Double
        var upper: Double
        if lo == hi {
            let pad = Swift.max(abs(lo) * 0.1, 1)
            lower = magnitudeBar ? Swift.min(0, lo - pad) : lo - pad
            upper = hi + pad
        } else if magnitudeBar {
            lower = Swift.min(0, lo * 1.15)
            upper = Swift.max(0, hi * 1.15)
        } else {
            let pad = Swift.max((hi - lo) * 0.15, abs(hi) * 0.02, 1)
            lower = lo - pad
            upper = hi + pad
        }
        if metric == .spo2 { upper = Swift.min(upper, 100) }
        if !(upper > lower) { upper = lower + 1 }
        return lower...upper
    }

    // MARK: - Sleep hypnogram (reuses the Sleep page component)

    private var sleepHypnogram: some View {
        let blocks = chart.data.compactMap { point -> SleepStageBlock? in
            guard let stage = SleepStage(rawValue: point.series ?? ""), let start = Int(point.x) else { return nil }
            return SleepStageBlock(
                sessionId: UUID(), startAt: AppClock.now,
                startMinute: start, durationMinutes: Int(point.y), stage: stage
            )
        }
        let total = blocks.map { $0.startMinute + $0.durationMinutes }.max() ?? 0
        return Group {
            if blocks.isEmpty || total == 0 {
                Text("No sleep stages to plot.")
                    .font(AgaraFont.caption.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                SleepHypnogramView(blocks: blocks, totalMin: total, startTs: nil, height: height + 30)
            }
        }
    }
}
