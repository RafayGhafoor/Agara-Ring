import SwiftUI
import Charts

/// Tap / hover value marker for any Swift Charts chart plotting dated or indexed numeric samples.
///
/// Attaches one `chartOverlay` that (a) tracks the pointer (hover, macOS-only surface) and taps to
/// **pin** a value (tap again to unpin), snapping to the nearest plotted sample by pixel distance,
/// and (b) renders a dot + capsule tooltip at that sample. The x type is generic (`Date` or `Int`
/// index), so the same marker serves every chart in `Charts.swift`.
///
/// `xLabel`/`yLabel` turn the raw values into display text ("Sep 11, 04:20", "68 bpm" …).
struct ChartValueMarker<X: Plottable>: ViewModifier {
    let samples: [(x: X, y: Double)]
    let xLabel: (X) -> String
    let yLabel: (Double) -> String

    @State private var hovered: Int?
    @State private var pinned: Int?

    func body(content: Content) -> some View {
        content
            .chartOverlay { proxy in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): hovered = nearest(to: location, geo: geo, proxy: proxy)
                                case .ended: hovered = nil
                                }
                            }
                            .onTapGesture { location in
                                let hit = nearest(to: location, geo: geo, proxy: proxy)
                                pinned = (hit != nil && hit == pinned) ? nil : hit
                            }

                        if let index = hovered ?? pinned, index < samples.count {
                            let sample = samples[index]
                            if let point = plotPoint(for: sample, proxy: proxy) {
                                Circle()
                                    .fill(PulseColors.textPrimary)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                    .position(point)
                                TooltipLabel(sample: sample, xLabel: xLabel, yLabel: yLabel)
                                    .position(CGPoint(
                                        x: min(max(point.x, 56), max(56, geo.size.width - 56)),
                                        y: max(26, point.y - 24)
                                    ))
                            }
                        }
                    }
                }
            }
    }

    /// Nearest sample index by plot-space pixel distance; nil when nothing maps (e.g. empty scale).
    private func nearest(to location: CGPoint, geo: GeometryProxy, proxy: ChartProxy) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, sample) in samples.enumerated() {
            guard let point = plotPoint(for: sample, proxy: proxy) else { continue }
            let dx = point.x - location.x
            let dy = point.y - location.y
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func plotPoint<X: Plottable>(for sample: (x: X, y: Double), proxy: ChartProxy) -> CGPoint? {
        guard let px = proxy.position(forX: sample.x),
              let py = proxy.position(forY: sample.y)
        else { return nil }
        return CGPoint(x: px, y: py)
    }
}

private struct TooltipLabel<X: Plottable>: View {
    let sample: (x: X, y: Double)
    let xLabel: (X) -> String
    let yLabel: (Double) -> String

    var body: some View {
        VStack(spacing: 2) {
            Text(yLabel(sample.y))
                .font(PulseFont.subheadline.weight(.semibold))
                .foregroundStyle(PulseColors.textPrimary)
            Text(xLabel(sample.x))
                .font(PulseFont.caption2)
                .foregroundStyle(PulseColors.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}

extension View {
    /// Add a tap/hover value tooltip to a dated-numeric plot.
    func chartValueMarker<S: Identifiable>(
        _ data: [S],
        x: KeyPath<S, Date>,
        y: KeyPath<S, Double>,
        xLabel: @escaping (Date) -> String = {
            $0.formatted(date: .abbreviated, time: .shortened)
        },
        yLabel: @escaping (Double) -> String = { String(format: "%.1f", $0) }
    ) -> some View {
        modifier(ChartValueMarker(
            samples: data.map { (x: $0[keyPath: x], y: $0[keyPath: y]) },
            xLabel: xLabel, yLabel: yLabel
        ))
    }

    /// Add a tap/hover value tooltip to an indexed numeric plot.
    func chartValueMarker(_ values: [Double], xLabel: @escaping (Int) -> String, yLabel: @escaping (Double) -> String) -> some View {
        modifier(ChartValueMarker(
            samples: values.enumerated().map { (x: Int($0.offset), y: $0.element) },
            xLabel: xLabel, yLabel: yLabel
        ))
    }

    /// Add a tap/hover value tooltip to a category plot (String x axis, e.g. day-label step bars).
    /// The x label doubles as the category key, so `xLabel` is the identity.
    func chartValueMarker(_ pairs: [(String, Double)], yLabel: @escaping (Double) -> String) -> some View {
        modifier(ChartValueMarker(
            samples: pairs.map { (x: $0.0, y: $0.1) },
            xLabel: { "\($0)" }, yLabel: yLabel
        ))
    }
}