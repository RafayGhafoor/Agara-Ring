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
        case .stress: return AgaraColors.stress
        case .restingHr: return AgaraColors.heartRate
        case .respRate: return AgaraColors.respiration
        case .intensityMinutes: return AgaraColors.met
        case .sleepScore, .bedtime, .wakeTime, .sleepAwake: return AgaraColors.sleep
        }
    }

    /// The shared component's empty state: the coach's own sentence, at the chart's height.
    private var emptyState: AgaraChartEmpty {
        AgaraChartEmpty(text: "No data to plot for this range.", minimumPoints: 1, minHeight: height)
    }

    var body: some View { chartBody.accessibilityIdentifier("coach.chart") }

    private var chartBody: some View {
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
                       xLabel: { index in chart.data.indices.contains(index) ? Self.xDetailLabel(chart.data[index].x) : "" }) {
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
                       xLabel: { Self.xDetailLabel($0) }) {
                // When the answer annotates a point ("Friday: the shortest night"), that bar keeps the full colour and
                // the others step back, so the chart points at what the text is talking about.
                let marked = Set(chart.annotations.map(\.x))
                ForEach(chart.data, id: \.id) { point in
                    BarMark(x: .value("x", point.x), y: .value("y", point.y))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                        .foregroundStyle(color.opacity(marked.isEmpty || marked.contains(point.x) ? 0.9 : 0.38))
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(7, chart.data.count))) { value in
                    AxisValueLabel {
                        if let raw = value.as(String.self) {
                            Text(Self.xAxisLabel(raw, pointCount: chart.data.count))
                        }
                    }
                    .font(AgaraFont.nano.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                }
            }
            .chartYAxis { axisMarks }

        case .sleepStage:
            EmptyView()  // handled by `sleepHypnogram`
        }
    }

    private var axisMarks: some AxisContent {
        AxisMarks(position: .leading, values: Self.yAxisValues(domain: yDomain, metric: chart.metric)) { value in
            AxisGridLine().foregroundStyle(AgaraColors.borderSubtle)
            AxisValueLabel {
                if let v = value.as(Double.self) { Text(Self.yAxisLabel(v, metric: chart.metric)) }
            }
            .font(AgaraFont.nano.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
        }
    }

    // MARK: - Axis and tooltip labels (pure, unit-tested in CoachActionTests)

    /// Grid values. Sleep arrives in minutes, so its grid sits on whole hours (every 2 h over a wide range); everything
    /// else lets Charts choose about four.
    static func yAxisValues(domain: ClosedRange<Double>, metric: CoachChartMetric) -> AxisMarkValues {
        guard metric == .sleep else { return .automatic(desiredCount: 4) }
        return .stride(by: sleepGridStep(domain: domain))
    }

    /// Minutes between sleep grid lines: hourly over a narrow range, every two hours over a wide one (a bar chart from
    /// zero to nine hours would otherwise draw ten lines).
    static func sleepGridStep(domain: ClosedRange<Double>) -> Double {
        domain.upperBound - domain.lowerBound > 300 ? 120 : 60
    }

    /// An axis tick in the metric's unit, kept short: "6h", "12k", "72".
    static func yAxisLabel(_ value: Double, metric: CoachChartMetric) -> String {
        switch metric {
        case .sleep:
            let hours = value / 60
            return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
        case .steps:
            return value >= 1000 ? "\(Int((value / 1000).rounded()))k" : "\(Int(value.rounded()))"
        case .spo2:
            return "\(Int(value.rounded()))%"
        case .bedtime, .wakeTime:
            return clock(value)
        default:
            return "\(Int(value.rounded()))"
        }
    }

    /// Minutes from midnight (negative = the evening before) as a clock time: -75 → "22:45", 420 → "07:00".
    static func clock(_ minutes: Double) -> String {
        let m = ((Int(minutes.rounded()) % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private static func isoDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return raw.count == 10 ? f.date(from: raw) : nil
    }

    private static func format(_ date: Date, template: String, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// The x tick for a date label: a weekday when the range is a week or less, otherwise "13 Oct". Anything that is
    /// not an ISO date (a minute label, a stage name) passes through unchanged.
    static func xAxisLabel(_ raw: String, pointCount: Int, locale: Locale = .current) -> String {
        guard let date = isoDate(raw) else { return raw }
        return format(date, template: pointCount <= 7 ? "EEE" : "dMMM", locale: locale)
    }

    /// The tooltip's date line: "Fri 16 Oct".
    static func xDetailLabel(_ raw: String, locale: Locale = .current) -> String {
        guard let date = isoDate(raw) else { return raw }
        return format(date, template: "EEEdMMM", locale: locale)
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
        case .stress: return "stress \(Int(value.rounded()))"
        case .restingHr: return "\(Int(value.rounded())) bpm resting"
        case .respRate: return String(format: "%.1f /min", value)
        case .intensityMinutes: return "\(Int(value.rounded())) min"
        case .sleepScore: return "score \(Int(value.rounded()))"
        case .bedtime, .wakeTime: return clock(value)
        case .sleepAwake: return "\(Int(value.rounded())) min awake"
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
            && [.steps, .calories, .distance, .activeMinutes, .sleep, .intensityMinutes, .sleepAwake].contains(metric)

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
