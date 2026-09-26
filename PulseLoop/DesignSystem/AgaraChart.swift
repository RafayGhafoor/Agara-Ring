import SwiftUI
import Charts

// The one chart component (consistency framework, block A — AGENTS.md Rule 10). Every Swift Charts graph in
// the app is an `AgaraChart`: the caller supplies only its marks (and, for zone lines, a drawing overlay);
// the wrapper owns what used to be re-done — or forgotten — per chart:
//
//   * scrub + tooltip value: hover (pointer), tap to pin, press-and-drag to scrub; a dot, a hairline and a
//     capsule with the value and its time snap to the nearest plotted point;
//   * the empty state (too few points) and a loading state;
//   * accessibility: one element with a summary value and an audio-graph chart descriptor;
//   * the frame height.
//
// Scales and axes stay ordinary Swift Charts modifiers the caller applies to the `AgaraChart` (they travel
// down to the chart), with `vitalsAxes` as the shared time-axis style. Mirrors Android's `AgaraChart`.
//
// This file is also compiled into the widgets extension (for `ZoneLineChart`), so it uses only design-system
// types that target has.

/// One value the scrub layer can land on. `x` is whatever the chart plots along its x axis (a `Date`, a
/// category `String`, a minute `Double`, an index `Int`); `y` is where the marker sits.
struct AgaraChartPoint<X: Plottable> {
    let x: X
    let y: Double
    /// The tooltip's value line; nil uses the chart's `valueLabel(y)` (blood pressure passes "120/80").
    var valueText: String? = nil
    /// The tooltip's second line; nil uses the chart's `xLabel(x)`.
    var detailText: String? = nil
}

/// What an `AgaraChart` shows instead of the plot when there is nothing (or not enough) to draw.
struct AgaraChartEmpty {
    var text: String = "Not enough data for this period."
    /// Fewer points than this shows `text` (a line needs two; a bar or a dot is readable alone).
    var minimumPoints: Int = 1
    var minHeight: CGFloat = 120
}

struct AgaraChart<X: Plottable, Content: ChartContent, Overlay: View>: View {
    let points: [AgaraChartPoint<X>]
    var height: CGFloat?
    /// Scrub/tap/hover value marker. Off for charts inside a tappable card (the tap opens the detail).
    var interactive: Bool
    var isLoading: Bool
    var empty: AgaraChartEmpty
    /// VoiceOver label ("Heart rate chart", "Battery history").
    var accessibilityTitle: String
    let valueLabel: (Double) -> String
    let xLabel: (X) -> String
    /// A tap that lands on a point also reports its x (the Sleep histogram opens that night).
    var onSelect: ((X) -> Void)?
    @ChartContentBuilder let content: () -> Content
    /// Drawn in plot coordinates above the marks and below the marker (the zone-coloured line lives here).
    let overlay: (ChartProxy, GeometryProxy) -> Overlay

    init(points: [AgaraChartPoint<X>],
         height: CGFloat? = nil,
         interactive: Bool = true,
         isLoading: Bool = false,
         empty: AgaraChartEmpty = AgaraChartEmpty(),
         accessibilityTitle: String = "Chart",
         valueLabel: @escaping (Double) -> String = { String(format: "%.0f", $0) },
         xLabel: @escaping (X) -> String,
         onSelect: ((X) -> Void)? = nil,
         @ChartContentBuilder content: @escaping () -> Content,
         @ViewBuilder overlay: @escaping (ChartProxy, GeometryProxy) -> Overlay) {
        self.points = points
        self.height = height
        self.interactive = interactive
        self.isLoading = isLoading
        self.empty = empty
        self.accessibilityTitle = accessibilityTitle
        self.valueLabel = valueLabel
        self.xLabel = xLabel
        self.onSelect = onSelect
        self.content = content
        self.overlay = overlay
    }

    var body: some View {
        if isLoading {
            ProgressView()
                .tint(AgaraColors.accent)
                .frame(maxWidth: .infinity, minHeight: height ?? empty.minHeight)
                .accessibilityLabel("\(accessibilityTitle), loading")
        } else if points.count < empty.minimumPoints {
            Text(empty.text)
                .font(AgaraFont.footnote.weight(.regular))
                .foregroundStyle(AgaraColors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: max(height ?? 0, empty.minHeight), alignment: .center)
                .accessibilityIdentifier("chart.empty")
        } else {
            Chart { content() }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            overlay(proxy, geo)
                            if interactive {
                                AgaraChartScrubLayer(points: points, proxy: proxy, geo: geo,
                                                     valueLabel: valueLabel, xLabel: xLabel, onSelect: onSelect)
                            }
                        }
                    }
                }
                .frame(height: height)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(AgaraChartSummary.text(points.map(\.y), valueLabel: valueLabel))
                .accessibilityChartDescriptor(AgaraChartDescriptor(title: accessibilityTitle, points: points,
                                                                   valueLabel: valueLabel, xLabel: xLabel))
                .accessibilityIdentifier("chart")
        }
    }
}

extension AgaraChart where Overlay == EmptyView {
    init(points: [AgaraChartPoint<X>],
         height: CGFloat? = nil,
         interactive: Bool = true,
         isLoading: Bool = false,
         empty: AgaraChartEmpty = AgaraChartEmpty(),
         accessibilityTitle: String = "Chart",
         valueLabel: @escaping (Double) -> String = { String(format: "%.0f", $0) },
         xLabel: @escaping (X) -> String,
         onSelect: ((X) -> Void)? = nil,
         @ChartContentBuilder content: @escaping () -> Content) {
        self.init(points: points, height: height, interactive: interactive, isLoading: isLoading, empty: empty,
                  accessibilityTitle: accessibilityTitle, valueLabel: valueLabel, xLabel: xLabel, onSelect: onSelect,
                  content: content, overlay: { _, _ in EmptyView() })
    }
}

enum AgaraChartLabels {
    /// Time on the x axis: the tooltip's second line is the reading's time (a day) or date and time.
    static func time(for range: MetricRange?) -> (Date) -> String {
        { date in
            switch range {
            case .twentyFourHours?: return date.formatted(date: .omitted, time: .shortened)
            case .twelveMonths?: return date.formatted(.dateTime.month(.abbreviated).year())
            default: return date.formatted(date: .abbreviated, time: .shortened)
            }
        }
    }
}

// MARK: - Scrub layer

/// The value marker: hover tracks the pointer, a tap pins the nearest point (tap it again to unpin), and a
/// press-and-drag scrubs along the line. Press-then-drag rather than a bare drag so a vertical swipe over the
/// chart still scrolls the page.
private struct AgaraChartScrubLayer<X: Plottable>: View {
    let points: [AgaraChartPoint<X>]
    let proxy: ChartProxy
    let geo: GeometryProxy
    let valueLabel: (Double) -> String
    let xLabel: (X) -> String
    let onSelect: ((X) -> Void)?

    @State private var hovered: Int?
    @State private var pinned: Int?
    @State private var scrubbing: Int?

    private var selected: Int? { scrubbing ?? hovered ?? pinned }

    var body: some View {
        let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = nearest(to: location, plot: plot)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { location in
                    let hit = nearest(to: location, plot: plot)
                    pinned = (hit != nil && hit == pinned) ? nil : hit
                    if let hit, let onSelect { onSelect(points[hit].x) }
                }
                .gesture(
                    LongPressGesture(minimumDuration: 0.25)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard case .second(true, let drag?) = value else { return }
                            scrubbing = nearest(to: drag.location, plot: plot)
                        }
                        .onEnded { _ in
                            // Keep the last scrubbed value on screen, like a tap would.
                            if let scrubbing { pinned = scrubbing }
                            scrubbing = nil
                        }
                )

            if let index = selected, index < points.count, let point = position(of: points[index], plot: plot) {
                let sample = points[index]
                Rectangle()
                    .fill(AgaraColors.textMuted.opacity(0.45))
                    .frame(width: 1, height: plot.height)
                    .position(x: point.x, y: plot.midY)
                    .allowsHitTesting(false)
                Circle()
                    .fill(AgaraColors.textPrimary)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(AgaraColors.background, lineWidth: 1.5))
                    .position(point)
                    .allowsHitTesting(false)
                AgaraChartTooltip(value: sample.valueText ?? valueLabel(sample.y),
                                  detail: sample.detailText ?? xLabel(sample.x))
                    .position(x: min(max(point.x, 60), max(60, geo.size.width - 60)), y: max(22, point.y - 26))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Nearest point by horizontal distance first (what a finger sliding along a line means), then vertical.
    private func nearest(to location: CGPoint, plot: CGRect) -> Int? {
        var best: (index: Int, dx: CGFloat, dy: CGFloat)?
        for (index, sample) in points.enumerated() {
            guard let p = position(of: sample, plot: plot) else { continue }
            let dx = abs(p.x - location.x), dy = abs(p.y - location.y)
            if best == nil || dx < best!.dx - 0.5 || (abs(dx - best!.dx) <= 0.5 && dy < best!.dy) {
                best = (index, dx, dy)
            }
        }
        return best?.index
    }

    private func position(of sample: AgaraChartPoint<X>, plot: CGRect) -> CGPoint? {
        guard let x = proxy.position(forX: sample.x), let y = proxy.position(forY: sample.y) else { return nil }
        return CGPoint(x: plot.minX + x, y: plot.minY + y)
    }
}

private struct AgaraChartTooltip: View {
    let value: String
    let detail: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textPrimary)
                .monospacedDigit()
            Text(detail)
                .font(AgaraFont.caption2)
                .foregroundStyle(AgaraColors.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chart.tooltip")
    }
}

// MARK: - Accessibility

enum AgaraChartSummary {
    /// "12 readings, 58 to 91, latest 72" — what VoiceOver reads for the chart as a whole.
    static func text(_ values: [Double], valueLabel: (Double) -> String) -> String {
        guard let last = values.last, let lo = values.min(), let hi = values.max() else { return "No data" }
        let count = values.count == 1 ? "1 reading" : "\(values.count) readings"
        if lo == hi { return "\(count), \(valueLabel(lo))" }
        return "\(count), \(valueLabel(lo)) to \(valueLabel(hi)), latest \(valueLabel(last))"
    }

    /// At most `limit` evenly spaced indices (always keeping the last) — the audio graph doesn't need 1,440 points.
    static func strideIndices(count: Int, limit: Int = 60) -> [Int] {
        guard count > limit, limit > 1 else { return Array(0..<count) }
        let step = Double(count - 1) / Double(limit - 1)
        return (0..<limit).map { Int((Double($0) * step).rounded()) }
    }
}

/// Audio graph for VoiceOver (rotor → Audio Graph): the plotted values in order, labelled like the tooltip.
private struct AgaraChartDescriptor<X: Plottable>: AXChartDescriptorRepresentable {
    let title: String
    let points: [AgaraChartPoint<X>]
    let valueLabel: (Double) -> String
    let xLabel: (X) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let picked = AgaraChartSummary.strideIndices(count: points.count).map { points[$0] }
        let labels = picked.enumerated().map { "\($0.offset + 1). \($0.element.detailText ?? xLabel($0.element.x))" }
        let values = picked.map(\.y)
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Time", categoryOrder: labels)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let yAxis = AXNumericDataAxisDescriptor(title: "Value", range: lo...max(hi, lo + 1), gridlinePositions: []) {
            valueLabel($0)
        }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: zip(labels, picked).map {
            AXDataPoint(x: $0.0, y: $0.1.y, label: $0.1.valueText)
        })
        return AXChartDescriptor(title: title, summary: AgaraChartSummary.text(points.map(\.y), valueLabel: valueLabel),
                                 xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}
