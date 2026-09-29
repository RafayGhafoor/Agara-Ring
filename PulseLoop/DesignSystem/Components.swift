import SwiftUI

/// Reusable cards and controls ported from `frontend/src/components`. Visuals
/// (spacing, type, color) mirror the web Tailwind markup.

// MARK: - Hero insight card (Today)

enum ChipTone {
    case neutral, up, down, warn

    var foreground: Color {
        switch self {
        case .neutral: return AgaraColors.textSecondary
        case .up: return AgaraColors.success
        case .down: return AgaraColors.danger
        case .warn: return AgaraColors.warning
        }
    }

    var background: Color {
        switch self {
        case .neutral: return AgaraColors.textPrimary.opacity(0.10)
        case .up: return AgaraColors.success.opacity(0.15)
        case .down: return AgaraColors.danger.opacity(0.15)
        case .warn: return AgaraColors.warning.opacity(0.15)
        }
    }

    var border: Color {
        switch self {
        case .neutral: return AgaraColors.borderSubtle
        case .up: return AgaraColors.success.opacity(0.30)
        case .down: return AgaraColors.danger.opacity(0.30)
        case .warn: return AgaraColors.warning.opacity(0.30)
        }
    }
}

struct ToneChip: Identifiable {
    let id = UUID()
    let label: String
    let tone: ChipTone
}

struct HeroInsightCardView: View {
    let title: String
    let summary: String
    var chips: [ToneChip] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AgaraFont.title)
                .foregroundStyle(AgaraColors.textPrimary)
            Text(summary)
                .font(AgaraFont.callout.weight(.regular))
                .lineSpacing(4)
                .foregroundStyle(AgaraColors.textSecondary)
                .padding(.top, 8)
            if !chips.isEmpty {
                FlowChips(chips: chips).padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(
                colors: [AgaraColors.accent.opacity(0.18), AgaraColors.spo2.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct FlowChips: View {
    let chips: [ToneChip]
    var body: some View {
        // Two-row wrap is plenty for the 3 hero chips; use an HStack that wraps.
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Text(chip.label)
                    .font(AgaraFont.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(chip.tone.foreground)
                    .background(chip.tone.background)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(chip.tone.border, lineWidth: 1))
            }
        }
    }
}

// MARK: - Coach message card (Today + Sleep)

struct CoachMessageCard: View {
    let headline: String
    let bodyText: String
    var chips: [String] = []

    init(headline: String, body: String, chips: [String] = []) {
        self.headline = headline
        self.bodyText = body
        self.chips = chips
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(AgaraColors.accent).frame(width: 6, height: 6)
                    .shadow(color: AgaraColors.accent.opacity(0.8), radius: 5)
                Text("COACH")
                    .font(AgaraFont.micro)
                    .tracking(1.8)
                    .foregroundStyle(AgaraColors.textMuted)
            }
            Text(headline)
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textPrimary)
                .padding(.top, 6)
            Text(bodyText)
                .font(AgaraFont.subheadline.weight(.regular))
                .lineSpacing(5)
                .foregroundStyle(AgaraColors.textSecondary)
                .padding(.top, 6)
            if !chips.isEmpty {
                // Both questions share one compact row (each wraps to ≤2 lines)
                // so the card stays short; chat bubbles use full-width rows instead.
                HStack(alignment: .top, spacing: 6) {
                    ForEach(chips.prefix(2), id: \.self) { chip in
                        CoachSummaryChip(text: chip)
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(AgaraColors.accent).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// One compact follow-up question on a Today/Sleep coach card. Extracted so the
/// modifier chain doesn't blow the parent view's type-check budget.
private struct CoachSummaryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AgaraFont.caption2.weight(.regular))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(AgaraColors.textSecondary)
            .agaraGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Tappable metric card with delta + sparkline (Today / Activity / Vitals)

struct MetricDelta {
    let value: Int
    let label: String
}

struct MetricCardButton: View {
    let metric: String
    let label: String
    let value: String
    var unit: String?
    var color: Color
    var delta: MetricDelta?
    var sparkline: [Double] = []
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.7), radius: 5)
                    Text(label.uppercased())
                        .font(AgaraFont.caption2)
                        .tracking(0.6)
                        .foregroundStyle(AgaraColors.textMuted)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(AgaraFont.greeting)
                        .monospacedDigit()
                        .foregroundStyle(AgaraColors.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if let unit {
                        Text(unit).font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                    }
                }
                if let delta {
                    let isUp = delta.value >= 0
                    HStack(spacing: 4) {
                        Image(systemName: isUp ? "arrow.up" : "arrow.down")
                        Text("\(isUp ? "+" : "")\(delta.value)").monospacedDigit()
                        Text(delta.label).foregroundStyle(AgaraColors.textMuted)
                    }
                    .font(AgaraFont.caption2)
                    .foregroundStyle(isUp ? AgaraColors.success : AgaraColors.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isUp ? AgaraColors.success : AgaraColors.danger).opacity(0.15))
                    .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                if sparkline.count > 1 {
                    MiniSparkline(values: sparkline, color: color).frame(height: 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .frame(height: 150)
            .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .sampleChip()
            // Non-tappable tiles should look identical to tappable ones — never dimmed.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(onTap != nil)
    }
}

// MARK: - Range toggles

struct RangeToggleView: View {
    @Binding var selection: MetricRange
    private let options: [(MetricRange, String)] = [(.sevenDays, "W"), (.thirtyDays, "M"), (.twelveMonths, "Y")]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let active = selection == option.0
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(AgaraFont.micro.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(active ? AgaraColors.textPrimary : AgaraColors.textMuted)
                        .frame(minWidth: 28)
                        .padding(.vertical, 3)
                        .background(active ? AgaraColors.card : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        // Glass track; the active segment stays a solid dark pill so the selection
        // reads clearly against the translucent container (no glass-on-glass).
        .agaraGlass(Capsule())
    }
}

struct SleepRangeSelectorView: View {
    @Binding var selection: SleepRangeKey
    private let options: [(SleepRangeKey, String)] = [(.day, "Day"), (.week, "Week"), (.month, "Month"), (.year, "Year")]

    var body: some View {
        // A standard segmented control — it adopts Liquid Glass automatically on
        // iOS 26, matching the metric-detail period bar (was a custom accent-tinted
        // capsule, which looked out of place next to the glass segmented bars).
        Picker("Range", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Progress ring (Activity weekly goal)

struct ProgressRingView<Center: View>: View {
    let value: Double
    let max: Double
    var size: CGFloat = 84
    var stroke: CGFloat = 9
    var color: Color = AgaraColors.steps
    @ViewBuilder var center: () -> Center

    private var progress: Double { max == 0 ? 0 : Swift.min(1, Swift.max(0, value / max)) }

    var body: some View {
        ZStack {
            Circle().stroke(AgaraColors.elevated, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Weekly pill calendar (Activity weekly goal)

struct WeeklyDay: Identifiable {
    let id = UUID()
    let label: String
    let completed: Bool
    let isToday: Bool
}

struct WeeklyPillCalendarView: View {
    let days: [WeeklyDay]

    var body: some View {
        HStack {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    ZStack {
                        Capsule().fill(fill(day)).overlay(Capsule().stroke(border(day), lineWidth: 1))
                        Text(day.completed ? "✓" : day.isToday ? "•" : "")
                            .font(AgaraFont.micro)
                            .foregroundStyle(textColor(day))
                    }
                    .frame(width: 24, height: 40)
                    Text(day.label)
                        .font(AgaraFont.micro)
                        .tracking(0.5)
                        .foregroundStyle(day.isToday ? AgaraColors.textPrimary : AgaraColors.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func fill(_ day: WeeklyDay) -> Color {
        if day.completed { return AgaraColors.success.opacity(0.20) }
        if day.isToday { return AgaraColors.accent.opacity(0.20) }
        return AgaraColors.cardSoft.opacity(0.4)
    }
    private func border(_ day: WeeklyDay) -> Color {
        if day.completed { return AgaraColors.success.opacity(0.4) }
        if day.isToday { return AgaraColors.accent }
        return AgaraColors.borderSubtle
    }
    private func textColor(_ day: WeeklyDay) -> Color {
        if day.completed { return AgaraColors.success }
        if day.isToday { return AgaraColors.textPrimary }
        return AgaraColors.textMuted
    }
}

// MARK: - Sleep hero + stage summary

struct SleepHeroCardView: View {
    let label: String
    let value: String
    var support: String?
    var score: Int?
    var scoreLabel: String?
    var noData: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased())
                    .font(AgaraFont.caption2)
                    .tracking(1.8)
                    .foregroundStyle(AgaraColors.textMuted)
                Text(value)
                    .font(AgaraFont.face(noData ? 24 : 40, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AgaraColors.textPrimary)
                    .padding(.top, 4)
                if let support {
                    Text(support)
                        .font(AgaraFont.subheadline.weight(.regular).monospacedDigit())
                        .foregroundStyle(AgaraColors.textSecondary)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .center, spacing: 2) {
                    HelpTip(AgaraHelp.sleepScore)
                    Text(score.map { "\($0)" } ?? "—")
                        .font(AgaraFont.largeTitle)
                        .monospacedDigit()
                        .foregroundStyle(AgaraColors.sleep)
                }
                if let scoreLabel, score != nil {
                    Text(scoreLabel)
                        .font(AgaraFont.subheadline)
                        .foregroundStyle(AgaraColors.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            AgaraColors.card.overlay(
                RadialGradient(colors: [AgaraColors.accent.opacity(0.16), .clear], center: .init(x: 0.82, y: 0), startRadius: 0, endRadius: 220)
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Stage duration cards in a 2×2 grid: deep, light, REM, awake, which add up to the time in bed. Two per
/// row keeps a value like "6h 19m" on one line (Android's SleepStageSummaryCards, same layout).
struct SleepStageSummaryCardsView: View {
    var prefix: String = ""
    let deep: String
    let light: String
    let rem: String
    let awake: String

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                stat("\(prefix)Deep", deep, SleepStageColors.deep)
                stat("\(prefix)Light", light, SleepStageColors.light)
            }
            HStack(spacing: 12) {
                stat("\(prefix)REM", rem, SleepStageColors.rem)
                stat("\(prefix)Awake", awake, SleepStageColors.awake)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.7), radius: 5)
                Text(label.uppercased())
                    .font(AgaraFont.micro)
                    .tracking(0.6)
                    .foregroundStyle(AgaraColors.textMuted)
                    .lineLimit(1)
            }
            Text(value)
                .font(AgaraFont.title2)
                .monospacedDigit()
                .foregroundStyle(AgaraColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .agaraGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sampleChip()
    }
}

// MARK: - Vitals detail card + small action button

struct DetailCard<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.7), radius: 5)
                Text(title.uppercased())
                    .font(AgaraFont.caption2)
                    .tracking(1.0)
                    .foregroundStyle(AgaraColors.textMuted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sampleChip()
    }
}

struct QuickActionButton: View {
    let label: String
    var tone: ChipTone = .neutral
    var accent: Bool = false
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var text: some View {
        Text(label)
            .font(AgaraFont.subheadline.weight(.semibold))
            // Several of these can share one row (the Vitals measure pills), so a longer label like
            // "Measure SpO₂" shrinks to fit rather than wrapping or truncating.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    var body: some View {
        if #available(iOS 26, *), !reduceTransparency {
            // Accent variant = tinted prominent glass; neutral = plain glass.
            Button(action: action) {
                text.foregroundStyle(accent ? AgaraColors.onAccent : AgaraColors.textPrimary)
            }
            .modifier(QuickActionGlass(accent: accent))
            .clipShape(Capsule())
        } else {
            Button(action: action) {
                text
                    .foregroundStyle(accent ? AgaraColors.onAccent : AgaraColors.textPrimary)
                    .background(accent ? AgaraColors.accent : AgaraColors.card)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(accent ? Color.clear : AgaraColors.borderSubtle, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Picks prominent (accent-tinted) vs plain glass for QuickActionButton.
@available(iOS 26, *)
private struct QuickActionGlass: ViewModifier {
    let accent: Bool
    func body(content: Content) -> some View {
        // Both variants use translucent glass; accent adds a tint (no flat prominent fill).
        if accent {
            content.buttonStyle(.glass).tint(AgaraColors.accent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

// MARK: - Activity section card (chart with range toggle)

struct ActivitySectionCard<Content: View>: View {
    let title: String
    @Binding var range: MetricRange
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(AgaraFont.caption2)
                    .tracking(1.0)
                    .foregroundStyle(AgaraColors.textMuted)
                Spacer()
                RangeToggleView(selection: $range)
            }
            content.padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sampleChip()
    }
}

// MARK: - Activity metadata (icon + label + helper by type)

/// Typed activity metadata, ported from `frontend/src/components/activity/activityMeta.ts`.
struct ActivityKind: Identifiable {
    let type: String
    let label: String
    let helper: String
    let symbol: String
    let gpsCapable: Bool
    var id: String { type }
}

enum ActivityMeta {
    /// Canonical types in display order (matches web `ACTIVITY_ORDER`).
    static let order = ["walk", "run", "cycle", "gym", "squash", "sport", "yoga", "dance", "hike", "other"]

    private static let table: [String: ActivityKind] = [
        "walk":   ActivityKind(type: "walk",   label: "Walk",   helper: "Outdoor or indoor walk",     symbol: "figure.walk",          gpsCapable: true),
        "run":    ActivityKind(type: "run",    label: "Run",    helper: "Road, treadmill, or intervals", symbol: "figure.run",        gpsCapable: true),
        "cycle":  ActivityKind(type: "cycle",  label: "Cycle",  helper: "Bike ride or stationary",    symbol: "figure.outdoor.cycle", gpsCapable: true),
        "gym":    ActivityKind(type: "gym",    label: "Gym",    helper: "Strength or machines",       symbol: "dumbbell.fill",        gpsCapable: false),
        "squash": ActivityKind(type: "squash", label: "Squash", helper: "Court session",              symbol: "figure.tennis",        gpsCapable: false),
        "sport":  ActivityKind(type: "sport",  label: "Sport",  helper: "General sport",              symbol: "figure.soccer",        gpsCapable: true),
        "yoga":   ActivityKind(type: "yoga",   label: "Yoga",   helper: "Mobility or stretching",     symbol: "figure.yoga",          gpsCapable: false),
        "dance":  ActivityKind(type: "dance",  label: "Dance",  helper: "Studio, cardio, or freestyle", symbol: "figure.dance",       gpsCapable: false),
        "hike":   ActivityKind(type: "hike",   label: "Hike",   helper: "Trail or long walk",         symbol: "figure.hiking",        gpsCapable: true),
        "other":  ActivityKind(type: "other",  label: "Other",  helper: "Custom activity",            symbol: "sparkles",             gpsCapable: false)
    ]

    /// Legacy seed/record names → canonical types.
    private static let aliases: [String: String] = [
        "outdoor_run": "run", "ride": "cycle", "cycling": "cycle", "strength": "gym"
    ]

    static func meta(_ type: String) -> ActivityKind {
        let canonical = aliases[type] ?? type
        return table[canonical] ?? ActivityKind(
            type: canonical,
            label: canonical.replacingOccurrences(of: "_", with: " ").capitalized,
            helper: "Custom activity",
            symbol: "sparkles",
            gpsCapable: false
        )
    }

    static var allKinds: [ActivityKind] { order.compactMap { table[$0] } }

    static func icon(_ type: String) -> String { meta(type).symbol }
    static func label(_ type: String) -> String { meta(type).label }

    /// H:MM:SS or M:SS.
    static func duration(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Pace from distance + duration; nil when not meaningful. In the user's units (min/km or min/mi),
    /// defaulting to metric so existing callers compile unchanged.
    static func pace(distanceMeters: Double?, durationSeconds: Int?, units: UnitsPreference = .metric) -> String? {
        guard let distanceMeters, let durationSeconds, distanceMeters >= 50 else { return nil }
        let paceSecPerKm = Double(durationSeconds) / (distanceMeters / 1000)
        let paceSec = UnitsFormatter.paceSeconds(perKmSeconds: paceSecPerKm, units: units)
        // Round to whole seconds first, then split — otherwise a value like 299.85 renders
        // "4:00" (minute truncated, seconds rounded up to 60) instead of "5:00".
        let total = Int(paceSec.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d %@", m, s, UnitsFormatter.paceUnit(units))
    }
}

// MARK: - Workout row (today list + history)

struct ActivityWorkoutRow: View {
    let session: ActivitySession
    var units: UnitsPreference = .metric
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 12) {
                IconTile(systemName: ActivityMeta.icon(session.type), style: .tinted(AgaraColors.accent), size: .large)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(ActivityMeta.label(session.type))
                            .font(AgaraFont.subheadline.weight(.semibold))
                            .foregroundStyle(AgaraColors.textPrimary)
                        Spacer()
                        Text(SleepFormat.clockTime(session.startedAt))
                            .font(AgaraFont.caption2.weight(.regular).monospacedDigit())
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                    HStack(spacing: 12) {
                        Text(durationLabel).font(AgaraFont.caption.weight(.regular).monospacedDigit())
                        if let distance = session.distanceMeters {
                            let d = UnitsFormatter.distance(meters: distance, units: units)
                            Text("\(d.value) \(d.unit)").font(AgaraFont.caption.weight(.regular).monospacedDigit())
                        }
                        if let hr = session.avgHeartRate {
                            Text("\(Int(hr)) bpm avg").font(AgaraFont.caption.weight(.regular).monospacedDigit())
                        }
                    }
                    .foregroundStyle(AgaraColors.textMuted)
                }
                if session.useGps {
                    Image(systemName: "map").font(AgaraFont.subheadline.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                }
            }
            .padding(16)
            .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .sampleChip(.bottomTrailing)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private var durationLabel: String {
        guard let ended = session.endedAt else { return "—" }
        let seconds = Int(ended.timeIntervalSince(session.startedAt) - session.totalPauseSeconds)
        let m = seconds / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

// MARK: - Sync progress bar

/// A thin, full-width indeterminate progress bar shown under the app header while the ring is
/// syncing. We only have stage labels (not a percentage), so this is indeterminate: an accent
/// segment sweeps left→right over a recessed track. Under Reduce Motion it degrades to a steady
/// pulsing full-width fill (no horizontal travel). Visuals use the existing `AgaraColors` tokens.
///
/// Driven by `TimelineView(.animation)` with the position a pure function of wall-clock time —
/// never a `@State` + `repeatForever` pair. The bar is mounted behind `if isSyncing`, so state-based
/// animation restarts from phase 0 on every sync (and can be committed against a pre-layout width
/// of 0, which reads as a frozen or jumping bar). Wall-clock math is phase-continuous across
/// remounts and self-corrects after dropped frames instead of accumulating jank.
struct SyncProgressBar: View {
    /// Bar thickness in points — deliberately thin so it reads as a status accent, not a control.
    var height: CGFloat = 3
    /// Fraction of the track width the moving segment occupies.
    private let segmentFraction: CGFloat = 0.4
    /// One edge-to-edge sweep; the out-and-back cycle is 2×. Matches the previous
    /// `.easeInOut(duration: 1.1).repeatForever(autoreverses: true)` look.
    private let sweepDuration: Double = 1.1
    /// Reduce Motion: half-period of the full-width opacity breathe (was easeInOut(0.8)).
    private let pulseHalfPeriod: Double = 0.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let trackWidth = geo.size.width
                let segmentWidth = trackWidth * segmentFraction

                ZStack(alignment: .leading) {
                    Rectangle().fill(AgaraColors.elevated)

                    if reduceMotion {
                        // No travel — a gentle opacity pulse on a full-width fill (1.0 ↔ 0.55).
                        Rectangle()
                            .fill(AgaraColors.accent)
                            .opacity(1.0 - 0.45 * Self.easedTriangle(t, halfPeriod: pulseHalfPeriod))
                    } else {
                        Capsule()
                            .fill(AgaraColors.accent)
                            .frame(width: segmentWidth)
                            // Sweep from the left edge to the right edge and back.
                            .offset(x: (trackWidth - segmentWidth) * Self.easedTriangle(t, halfPeriod: sweepDuration))
                    }
                }
                .clipped()
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Syncing")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// 0→1→0 triangle wave of wall-clock time with a sine ease applied per leg — the stateless
    /// equivalent of `.easeInOut(halfPeriod).repeatForever(autoreverses: true)`.
    private static func easedTriangle(_ t: TimeInterval, halfPeriod: Double) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: halfPeriod * 2) / halfPeriod   // 0..<2
        let tri = phase < 1 ? phase : 2 - phase
        return CGFloat(0.5 - cos(.pi * tri) / 2)
    }
}
