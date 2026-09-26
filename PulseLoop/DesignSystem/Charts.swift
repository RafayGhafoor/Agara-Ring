import SwiftUI
import Charts

/// Native Swift Charts ports of the web app's Recharts components, plus the
/// custom sleep hypnogram. Colors/domains mirror `frontend/src/components/charts`.

// MARK: - Sleep stage palette (catalog roles stage_*, same as Android AgaraColors.stage*)

enum SleepStageColors {
    static var deep: Color { AgaraColors.stageDeep }
    static var light: Color { AgaraColors.stageLight }
    static var rem: Color { AgaraColors.stageRem }
    static var awake: Color { AgaraColors.stageAwake }

    static func color(for stage: SleepStage) -> Color {
        switch stage {
        case .deep: return deep
        case .light: return light
        case .rem: return rem
        case .awake: return awake
        case .unknown: return AgaraColors.textMuted
        }
    }
}

// MARK: - Elevation profile (workout summary)

/// Altitude over the course of a route. X is point index (route progression),
/// Y is metres above sea level. Gradient area + line in the distance colour, axes hidden —
/// matches `CaloriesAreaChart`'s styling.
struct ElevationAreaChart: View {
    let altitudes: [Double]
    var height: CGFloat = 120

    var body: some View {
        let lo = (altitudes.min() ?? 0) - 2
        let hi = (altitudes.max() ?? 0) + 2
        AgaraChart(
            points: altitudes.enumerated().map { AgaraChartPoint(x: $0.offset, y: $0.element) },
            height: height,
            empty: AgaraChartEmpty(text: "No elevation recorded.", minimumPoints: 2),
            accessibilityTitle: "Elevation profile",
            valueLabel: { "\(Int($0)) m" },
            xLabel: { "Point \($0 + 1)" }
        ) {
            ForEach(Array(altitudes.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("i", index), y: .value("m", value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AgaraColors.distance.opacity(0.40), AgaraColors.distance.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                LineMark(x: .value("i", index), y: .value("m", value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(AgaraColors.distance)
            }
        }
        .chartYScale(domain: lo...max(hi, lo + 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

// MARK: - Sleep duration histogram (Sleep aggregate)

struct SleepBar: Identifiable {
    let id = UUID()
    let label: String
    /// Sleep duration in minutes, or nil for an untracked slot.
    let durationMin: Int?
    let score: Int?
    let present: Bool
    /// The night (or month, in the year view) this bar stands for. The axis is built one bar per day
    /// including placeholders, so position alone would have worked — but a date makes the mapping
    /// explicit and survives any later change to the axis.
    var date: Date? = nil
}

struct SleepDurationHistogramChart: View {
    let bars: [SleepBar]
    var goalMin: Int?
    var slim: Bool = false
    /// Called with the tapped bar's index (through `AgaraChart`'s tap) — the Sleep screen opens that night.
    var onSelect: ((Int) -> Void)? = nil
    var barWidth: CGFloat? = nil
    var weekBars: Bool = false
    var height: CGFloat = 210

    private var yMax: Double {
        let maxDuration = bars.compactMap { $0.durationMin }.max() ?? 0
        let ceiling = max(maxDuration, goalMin ?? 0)
        return ceiling > 0 ? Double(ceiling) * 1.15 : 600
    }

    var body: some View {
        // Use a unique key per bar so Swift Charts treats each as its own category,
        // centering the bar and its label automatically (same pattern as StepBarsChart).
        let indexed: [(Int, SleepBar)] = Array(bars.enumerated())
        let interval = bars.count > 14 ? max(1, bars.count / 6) : 1
        let showKeys: [String] = stride(from: 0, to: bars.count, by: interval).map { "\($0):\(bars[$0].label)" }
        let w: MarkDimension = weekBars ? .ratio(0.7) : (barWidth.map { .fixed($0) } ?? (slim ? .fixed(7) : .automatic))
        let r: CGFloat = (slim || weekBars) ? 3 : 6
        // Scrub/tooltip points: the tracked bars only (a placeholder has no value to show).
        let points: [AgaraChartPoint<String>] = indexed.compactMap { index, bar in
            guard bar.present, let duration = bar.durationMin else { return nil }
            return AgaraChartPoint(x: "\(index):\(bar.label)", y: Double(duration),
                                   valueText: SleepFormat.duration(duration), detailText: bar.label)
        }
        AgaraChart(
            points: points,
            height: height,
            empty: AgaraChartEmpty(text: "No sleep recorded in this period.", minimumPoints: 0),
            accessibilityTitle: "Sleep duration chart",
            valueLabel: { SleepFormat.duration(Int($0)) },
            xLabel: { key in key.split(separator: ":").last.map(String.init) ?? key },
            onSelect: onSelect.map { select in
                { key in if let index = Int(key.split(separator: ":").first ?? "") { select(index) } }
            }
        ) {
            ForEach(indexed, id: \.0) { index, bar in
                let key = "\(index):\(bar.label)"
                if bar.present, let duration = bar.durationMin {
                    BarMark(
                        x: .value("day", key),
                        y: .value("min", duration),
                        width: w
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AgaraColors.sleep, AgaraColors.stageDeep],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                } else {
                    // Faint full-height placeholder so gaps read as "untracked".
                    BarMark(
                        x: .value("day", key),
                        y: .value("min", yMax),
                        width: w
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r))
                    .foregroundStyle(AgaraColors.accent.opacity(0.05))
                }
            }
            if let goalMin, goalMin > 0 {
                RuleMark(y: .value("goal", goalMin))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(AgaraColors.textMuted.opacity(0.5))
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: showKeys) { value in
                if let key = value.as(String.self),
                   let label = key.split(separator: ":").last.map(String.init) {
                    AxisValueLabel {
                        Text(label).font(AgaraFont.micro.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.padding(.horizontal, weekBars ? 0 : 4)
        }
        .padding(8)
        .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Sleep hypnogram (Sleep day view)
// Direct port of frontend/src/components/charts/SleepTimeline.tsx

struct SleepHypnogramView: View {
    let blocks: [SleepStageBlock]
    let totalMin: Int
    let startTs: Date?
    var height: CGFloat = 210
    /// Fired with `true` when a press-and-hold scrub begins and `false` when it ends. The host
    /// disables its enclosing scroll views for the duration — the scrub gesture is `simultaneous`
    /// so that quick swipes keep paging/scrolling, which means an active scrub would otherwise
    /// drag the carousel along with the finger.
    var onScrubActiveChanged: ((Bool) -> Void)? = nil

    private let lanes: [SleepStage] = [.awake, .rem, .light, .deep]

    /// A press-and-hold scrub selection: which block the finger is over, and the minute under it.
    private struct Scrub: Equatable {
        var blockIndex: Int
        var minute: Int
    }
    @State private var scrub: Scrub?
    /// Whether we've told the host to pause scrolling. Guarded so the callback fires once per
    /// transition, and so every unwind path (end, cancel, teardown) can safely call `endScrub()`.
    @State private var scrubLockActive = false
    /// Mirrors "a scrub touch is on the screen". `@GestureState` resets automatically when the
    /// gesture ends, fails, or is CANCELLED (incoming call, Home swipe) — paths where `.onEnded`
    /// never runs. `onChange` of this is what keeps the host's scroll lock from leaking.
    @GestureState private var scrubTouchActive = false
    /// Canvas (plot-rect) size, captured so the gesture can map touch x → minute.
    @State private var plotSize: CGSize = .zero
    /// Measured readout-pill width, used to clamp it inside the plot.
    @State private var tooltipWidth: CGFloat = 0

    /// Insets of the plot area inside the glass card. The Canvas is padded by exactly these, and the
    /// lane labels / scrub overlay derive their coordinates from the same values — a single source of
    /// truth so bars and labels cannot drift apart.
    static let plotInsets = EdgeInsets(top: 16, leading: 64, bottom: 16, trailing: 16)
    private static let labelLeading: CGFloat = 12

    /// Vertical center of a stage's lane, as a fraction of the plot height.
    /// awake=top lane, then REM, light, deep=bottom (standard hypnogram ordering).
    static func laneFraction(_ stage: SleepStage) -> CGFloat {
        switch stage {
        case .awake: return 0.15
        case .rem: return 0.38
        case .light: return 0.62
        case .deep: return 0.85
        case .unknown: return 0.62
        }
    }

    private func laneY(_ stage: SleepStage, in size: CGSize) -> CGFloat {
        size.height * Self.laneFraction(stage)
    }

    private func x(forMinute minute: Int, in width: CGFloat) -> CGFloat {
        guard totalMin > 0 else { return 0 }
        let pct = max(0, min(1, CGFloat(minute) / CGFloat(totalMin)))
        return pct * width
    }

    private var sortedBlocks: [SleepStageBlock] {
        blocks.filter { $0.durationMinutes > 0 && $0.stage != .unknown }.sorted { $0.startMinute < $1.startMinute }
    }

    private var ticks: [(offset: Int, label: String)] {
        let safe = totalMin > 0 ? totalMin : 1
        let offsets = [0, safe / 3, safe * 2 / 3, safe]
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return offsets.map { offset in
            if let start = startTs {
                let date = start.addingTimeInterval(Double(offset) * 60)
                return (offset, formatter.string(from: date))
            }
            return (offset, "\(offset / 60)h")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Plot area, inset to clear the label gutter.
                Canvas { context, size in
                    let blocks = sortedBlocks
                    guard !blocks.isEmpty else { return }

                    // Dashed vertical transition connectors between consecutive blocks.
                    for index in 1..<max(1, blocks.count) {
                        let prev = blocks[index - 1]
                        let cur = blocks[index]
                        let cx = x(forMinute: cur.startMinute, in: size.width)
                        var path = Path()
                        path.move(to: CGPoint(x: cx, y: laneY(prev.stage, in: size)))
                        path.addLine(to: CGPoint(x: cx, y: laneY(cur.stage, in: size)))
                        context.stroke(
                            path,
                            with: .color(AgaraColors.textPrimary.opacity(0.36)),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2.5, 3])
                        )
                    }

                    // Horizontal segment per block: soft halo underlay + solid line.
                    for block in blocks {
                        let y = laneY(block.stage, in: size)
                        let startX = x(forMinute: block.startMinute, in: size.width)
                        let endX = x(forMinute: block.startMinute + block.durationMinutes, in: size.width)
                        var path = Path()
                        path.move(to: CGPoint(x: startX, y: y))
                        path.addLine(to: CGPoint(x: max(startX, endX), y: y))
                        let color = SleepStageColors.color(for: block.stage)
                        context.stroke(path, with: .color(color.opacity(0.16)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(scrubGesture)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { plotSize = $0 }
                .padding(Self.plotInsets)

                // Lane labels + scrub readout, placed with the same `laneFraction`/`plotInsets`
                // math the Canvas uses, so label centers coincide with bar centers by construction.
                GeometryReader { geo in
                    let plotWidth = max(1, geo.size.width - Self.plotInsets.leading - Self.plotInsets.trailing)
                    let plotHeight = max(1, geo.size.height - Self.plotInsets.top - Self.plotInsets.bottom)
                    let gutterWidth = Self.plotInsets.leading - Self.labelLeading

                    ForEach(lanes, id: \.self) { stage in
                        Text(stage.rawValue.uppercased())
                            .font(AgaraFont.micro.weight(.semibold))
                            .tracking(1.4)
                            .foregroundStyle(SleepStageColors.color(for: stage))
                            .frame(width: gutterWidth, alignment: .leading)
                            .position(x: Self.labelLeading + gutterWidth / 2,
                                      y: Self.plotInsets.top + Self.laneFraction(stage) * plotHeight)
                    }

                    scrubOverlay(plotWidth: plotWidth, plotHeight: plotHeight, containerWidth: geo.size.width)
                }
                // Labels and readout are display-only; touches must reach the Canvas gesture below.
                .allowsHitTesting(false)
            }
            .frame(height: height - 22)
            .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Tick when the scrub latches a block or crosses into a new one — not on release
            // (nil), which would read as a false stage-change cue.
            .sensoryFeedback(.selection, trigger: scrub?.blockIndex) { _, new in new != nil }
            // The gesture's touch went away by ANY path (ended, failed, system-cancelled):
            // release the scroll lock. `.onEnded` alone misses cancellation.
            .onChange(of: scrubTouchActive) { _, active in if !active { endScrub() } }
            // Mid-scrub teardown (e.g. a sync flips single-session → carousel): the gesture dies
            // with the view, so unwind the host's scroll lock here.
            .onDisappear { endScrub() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stages")
            .accessibilityValue(Self.accessibilitySummary(
                stages: sortedBlocks.map { (stage: $0.stage, minutes: $0.durationMinutes) }))

            // Time ticks.
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                    Text(tick.label)
                        .font(AgaraFont.micro.weight(.regular).monospacedDigit())
                        .foregroundStyle(AgaraColors.textMuted)
                    if index != ticks.count - 1 { Spacer() }
                }
            }
            .padding(.leading, 64)
            .padding(.trailing, 16)
        }
        .frame(height: height)
    }

    // MARK: Press-and-hold scrubber

    /// Hold ~0.35s, then drag to scrub. Attached as a `simultaneousGesture`: an exclusive `.gesture`
    /// here starves the paging ScrollView of the touch stream, killing swipe-to-page over the chart.
    /// Simultaneous keeps swipes/scrolls working (a moving finger fails the long-press), and once a
    /// scrub actually starts, `onScrubActiveChanged` lets the host pause its scroll views so the
    /// carousel doesn't pan under the drag. Coordinates are Canvas-local (attached inside the insets).
    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($scrubTouchActive) { _, state, _ in state = true }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                // Lock the host's scrolling the moment the hold succeeds (drag == nil, finger
                // still stationary), and again on the first drag event as belt-and-braces —
                // with `minimumDistance: 0` the nil-drag transition isn't guaranteed to be
                // delivered. `setScrubLock` is transition-guarded, so this never re-fires.
                setScrubLock(true)
                guard let drag else { return }
                updateScrub(atX: drag.location.x)
            }
            .onEnded { _ in endScrub() }
    }

    private func updateScrub(atX x: CGFloat) {
        let blocks = sortedBlocks
        let minute = Self.minute(forX: x, plotWidth: plotSize.width, totalMin: totalMin)
        guard let index = Self.blockIndex(
            atMinute: minute,
            in: blocks.map { (start: $0.startMinute, duration: $0.durationMinutes) }
        ) else { return }
        scrub = Scrub(blockIndex: index, minute: minute)
    }

    /// Tell the host to pause/resume scrolling — once per transition.
    private func setScrubLock(_ on: Bool) {
        guard scrubLockActive != on else { return }
        scrubLockActive = on
        onScrubActiveChanged?(on)
    }

    /// Unwind a scrub from any path: clean gesture end, system cancellation (via the
    /// `scrubTouchActive` onChange), or view teardown (onDisappear). Idempotent.
    private func endScrub() {
        scrub = nil
        setScrubLock(false)
    }

    /// Vertical indicator line at the finger plus a readout pill above the touched lane
    /// ("DEEP · 3:05 – 3:51 AM"). Coordinates are container-local (insets applied here).
    @ViewBuilder
    private func scrubOverlay(plotWidth: CGFloat, plotHeight: CGFloat, containerWidth: CGFloat) -> some View {
        let blocks = sortedBlocks
        if let scrub, blocks.indices.contains(scrub.blockIndex) {
            let block = blocks[scrub.blockIndex]
            let fingerX = Self.plotInsets.leading + x(forMinute: scrub.minute, in: plotWidth)
            let laneCenterY = Self.plotInsets.top + Self.laneFraction(block.stage) * plotHeight

            Rectangle()
                .fill(AgaraColors.textMuted.opacity(0.5))
                .frame(width: 1, height: plotHeight)
                .position(x: fingerX, y: Self.plotInsets.top + plotHeight / 2)

            Text(Self.readoutText(stage: block.stage, startMinute: block.startMinute,
                                  durationMinutes: block.durationMinutes, startTs: startTs))
                .font(AgaraFont.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(SleepStageColors.color(for: block.stage))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.ultraThinMaterial))
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tooltipWidth = $0 }
                .position(
                    x: {
                        // Clamp the pill into the plot; if it's wider than the plot itself
                        // (large Dynamic Type), the bounds invert — center on the card instead
                        // of pinning it (or hanging it) off the leading edge.
                        let lo = Self.plotInsets.leading + tooltipWidth / 2
                        let hi = containerWidth - Self.plotInsets.trailing - tooltipWidth / 2
                        return lo <= hi ? min(max(fingerX, lo), hi) : containerWidth / 2
                    }(),
                    // The pill sits above the touched lane, clear of the 12pt bar halo; the top
                    // (awake) lane has no room above, so its pill flips below.
                    y: block.stage == .awake ? laneCenterY + 26 : laneCenterY - 26
                )
                .animation(.easeOut(duration: 0.12), value: scrub.blockIndex)
        }
    }

    // MARK: Pure helpers (static so they're unit-testable without a view)

    /// Inverse of `x(forMinute:)`: map a plot-local touch x to a minute offset, clamped to the night.
    static func minute(forX x: CGFloat, plotWidth: CGFloat, totalMin: Int) -> Int {
        guard plotWidth > 0, totalMin > 0 else { return 0 }
        let pct = max(0, min(1, x / plotWidth))
        return Int((pct * CGFloat(totalMin)).rounded())
    }

    /// Index of the block containing `minute`, else the nearest block by interval distance — blocks
    /// can have small data seams between them, and snapping beats a readout that flickers away.
    static func blockIndex(atMinute minute: Int, in blocks: [(start: Int, duration: Int)]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        if let hit = blocks.firstIndex(where: { minute >= $0.start && minute < $0.start + $0.duration }) {
            return hit
        }
        func distance(to block: (start: Int, duration: Int)) -> Int {
            minute < block.start ? block.start - minute : minute - (block.start + block.duration - 1)
        }
        return blocks.indices.min { distance(to: blocks[$0]) < distance(to: blocks[$1]) }
    }

    /// Readout for one block. With a session start the times are absolute ("DEEP · 3:05 – 3:51 AM",
    /// both sides fully qualified when they straddle noon/midnight); without one (Coach chart) they
    /// are offsets from sleep start ("DEEP · 0:58 – 1:44"), matching the relative tick labels.
    static func readoutText(stage: SleepStage, startMinute: Int, durationMinutes: Int, startTs: Date?,
                            locale: Locale = .current) -> String {
        let name = stage.rawValue.uppercased()
        let endMinute = startMinute + durationMinutes
        guard let startTs else {
            func rel(_ m: Int) -> String { "\(m / 60):" + String(format: "%02d", m % 60) }
            return "\(name) · \(rel(startMinute)) – \(rel(endMinute))"
        }
        let start = startTs.addingTimeInterval(Double(startMinute) * 60)
        let end = startTs.addingTimeInterval(Double(endMinute) * 60)
        let full = DateFormatter()
        full.locale = locale
        full.dateFormat = "h:mm a"
        let calendar = Calendar.current
        let sameMeridiem = calendar.isDate(start, inSameDayAs: end)
            && (calendar.component(.hour, from: start) < 12) == (calendar.component(.hour, from: end) < 12)
        if sameMeridiem {
            let short = DateFormatter()
            short.locale = locale
            short.dateFormat = "h:mm"
            return "\(name) · \(short.string(from: start)) – \(full.string(from: end))"
        }
        return "\(name) · \(full.string(from: start)) – \(full.string(from: end))"
    }

    /// VoiceOver summary: per-stage totals in lane order, e.g.
    /// "Deep 1 hour 15 minutes, Light 3 hours 15 minutes".
    static func accessibilitySummary(stages: [(stage: SleepStage, minutes: Int)]) -> String {
        var totals: [SleepStage: Int] = [:]
        for entry in stages { totals[entry.stage, default: 0] += entry.minutes }
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        let parts: [String] = [SleepStage.deep, .light, .rem, .awake].compactMap { stage in
            guard let minutes = totals[stage], minutes > 0 else { return nil }
            let name = stage == .rem ? "REM" : stage.rawValue.capitalized
            let h = minutes / 60, m = minutes % 60
            if h > 0 && m > 0 { return "\(name) \(plural(h, "hour")) \(plural(m, "minute"))" }
            if h > 0 { return "\(name) \(plural(h, "hour"))" }
            return "\(name) \(plural(m, "minute"))"
        }
        return parts.isEmpty ? "No stage data" : parts.joined(separator: ", ")
    }
}
