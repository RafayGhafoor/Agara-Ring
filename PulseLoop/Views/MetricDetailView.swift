import SwiftUI
import SwiftData
import Charts

/// Tap-through detail for one vitals metric: period selector, a full-axis zone chart, stat tiles,
/// a threshold legend, an explainer, and a disclaimer for estimated metrics. Re-fetches through the
/// existing `MetricsService.metricRange` (the same fetch path the dashboard uses) when the period
/// changes — no new data plumbing.
struct MetricDetailView: View {
    let metric: MetricKind
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var period: DetailPeriod = .today
    @State private var primary: [MetricSample] = []
    @State private var secondary: [MetricSample] = []   // diastolic, for BP
    /// Observed so the detail chart/tiles re-fetch when a background sync lands while this is open.
    @State private var dataChange = PulseDataChange.shared

    private var profile: UserPhysiologyProfile { UserPhysiologyProfile(profiles.first) }
    private var units: UnitsPreference { profiles.first?.units ?? .metric }
    private var glucoseUnit: GlucoseUnit { profile.preferredGlucoseUnit }

    /// Canonical stored value (°C, mg/dL) → user's display unit. Identity for every
    /// other metric. `toRaw` is the inverse, needed to color the line (thresholds are
    /// evaluated in canonical units) after the samples are converted for display.
    private func toDisplay(_ raw: Double) -> Double {
        switch metric {
        case .temperature: return UnitsFormatter.temperatureValue(celsius: raw, units: units)
        case .glucose: return UnitsFormatter.glucoseValue(mgdl: raw, unit: glucoseUnit)
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid:
            return BloodComponents.displayValue(raw, metric: metric, unit: glucoseUnit)
        default: return raw
        }
    }
    private func toRaw(_ disp: Double) -> Double {
        switch metric {
        case .temperature: return units == .imperial ? (disp - 32) * 5 / 9 : disp
        case .glucose: return glucoseUnit == .mmol ? disp * 18.0182 : disp
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid:
            return BloodComponents.canonicalValue(disp, metric: metric, unit: glucoseUnit)
        default: return disp
        }
    }
    private var unitLabel: String {
        switch metric {
        case .temperature: return UnitsFormatter.temperatureUnit(units)
        case .glucose: return UnitsFormatter.glucoseUnit(glucoseUnit)
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid:
            return BloodComponents.displayUnit(metric: metric, unit: glucoseUnit)
        default: return metric.unit
        }
    }

    enum DetailPeriod: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }
        var range: MetricRange {
            switch self {
            case .today: return .twentyFourHours
            case .week: return .sevenDays
            case .month: return .thirtyDays
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                periodSelector
                chartSection
                statTiles
                legend
                explainer
                if isEstimatedMetric { disclaimer }
            }
            .padding(16)
            .padding(.bottom, 40)
            // Stacked glass cards share one container so their glass renders/blends consistently.
            .pulseGlassContainer(spacing: 18)
        }
        .background(PulseColors.background)
        // Shared glass chrome: centered title + glass back button, no system nav
        // bar (so the zoom transition doesn't reflow the content).
        .pageChrome(metric.title)
        .task(id: period) { reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
    }

    // MARK: - Period selector

    private var periodSelector: some View {
        Picker("Period", selection: $period) {
            ForEach(DetailPeriod.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Chart

    /// The chart's x-range: the calendar day 12am–12am for Today (as the vendor app draws it — a "today"
    /// starting 2 PM yesterday couldn't be read against the clock), the data's own span otherwise.
    private var xDomain: ClosedRange<Date>? { period == .today ? ChartAxes.dayWindow(Date()) : nil }

    /// What the chart plots: 30-min averages (3 h over a week, daily over a month) for continuous signals —
    /// the raw 1 Hz live + 5-min history mix drew as a jagged wall — and individual readings for spot metrics
    /// on a day. Stats and the legend still read every raw reading.
    private func chartSeries(_ samples: [MetricSample]) -> [MetricSample] {
        let bucket: TimeInterval? = switch period {
        // Spot metrics stay individual on a day unless the ring logged them all day (5-min history), where
        // dots on stems merged into a solid wall; same rule as Android (`DENSE_DAY_READINGS`).
        case .today: ChartAxes.isContinuous(metric) || samples.count > ChartAxes.denseDayReadings ? ChartAxes.halfHour : nil
        case .week: 3 * ChartAxes.hour
        case .month: ChartAxes.day
        }
        guard let bucket else { return samples }
        return ChartAxes.bucketAverage(samples, bucket: bucket)
    }

    @ViewBuilder
    private var chartSection: some View {
        let dispPrimary = primary.map { MetricSample(timestamp: $0.timestamp, value: toDisplay($0.value)) }
        let chart = ChartSampleBuilder.from(chartSeries(dispPrimary))
        let axis = ChartAxes.fixedAxis(metric, data: chart.map(\.value)) ?? ChartAxes.niceAxis(chart.map(\.value))
        let baseline = baselineForChart
        VStack(alignment: .leading, spacing: 8) {
            if !unitLabel.isEmpty {
                Text(unitLabel)
                    .font(PulseFont.caption.weight(.semibold))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A line needs two points; a bar or a dot is readable on its own.
            if chart.count < (ChartAxes.style(for: metric) == .line || xDomain == nil ? 2 : 1) {
                Text("Not enough data for this period.")
                    .font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else if metric == .bloodPressure {
                bloodPressureChart
            } else {
                ZoneLineChart(
                    samples: chart,
                    metric: metric,
                    yDomain: axis.domain,
                    referenceBands: detailBands(baseline: baseline),
                    range: period.range,
                    showPoints: metric == .spo2,
                    showAxes: true,
                    dashedRules: dashedRules(baseline: baseline).map(toDisplay),
                    height: 240,
                    thresholds: VitalsThresholdEngine.zoneThresholds(for: metric, profile: profile, baseline: baseline).map(toDisplay),
                    xDomain: xDomain,
                    yTicks: axis.ticks,
                    drawsLine: ChartAxes.style(for: metric) != .dots,
                    colorForValue: { value in
                        // Samples are in display units; color lookup needs canonical units.
                        VitalsThresholdEngine.colorToken(forValue: toRaw(value), metric: metric, profile: profile, baseline: baseline).color
                    }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    /// The BP chart's bucket: an hour on a day, 3 h over a week, a day over a month.
    private var bpBucket: TimeInterval {
        switch period {
        case .today: ChartAxes.hour
        case .week: 3 * ChartAxes.hour
        case .month: ChartAxes.day
        }
    }

    /// BP: one bar per bucket from the lowest diastolic to the highest systolic, on a fixed 60–180 axis (the
    /// vendor app's shape). Two joined lines on an axis cropped to the data squashed diastolic against the floor.
    private var bloodPressureChart: some View {
        let bars = ChartAxes.rangeBuckets(systolic: primary, diastolic: secondary, bucket: bpBucket)
        let axis = ChartAxes.fixedAxis(.bloodPressure, data: bars.flatMap { [$0.low, $0.high] })!
        return Chart {
            ForEach(bars, id: \.time) { bar in
                let (time, sys, dia) = (bar.time, bar.high, bar.low)
                RuleMark(x: .value("Time", time), yStart: .value("Diastolic", dia), yEnd: .value("Systolic", sys))
                    .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                    .foregroundStyle(PulseColors.bloodPressure.opacity(0.28))
                PointMark(x: .value("Time", time), y: .value("Systolic", sys))
                    .symbolSize(28).foregroundStyle(PulseColors.bloodPressure)
                PointMark(x: .value("Time", time), y: .value("Diastolic", dia))
                    .symbolSize(28).foregroundStyle(PulseColors.bloodPressure.opacity(0.55))
            }
        }
        .chartYScale(domain: axis.domain)
        .modify { chart in
            if let xDomain { chart.chartXScale(domain: xDomain) } else { chart }
        }
        .vitalsAxes(showAxes: true, range: period.range, yTicks: axis.ticks)
        .frame(height: 220)
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        let values = primary.map(\.value).filter { $0 > 0 }
        let dia = secondary.map(\.value).filter { $0 > 0 }
        // BP as SYS/DIA pairs: one number over both series put a diastolic "min" next to a systolic "max".
        func pair(_ a: Double?, _ b: Double?) -> String {
            guard let a, let b else { return "--" }
            return "\(Int(a.rounded()))/\(Int(b.rounded()))"
        }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        let isBP = metric == .bloodPressure
        let latest = isBP ? pair(values.last, dia.last) : values.last.map { fmt(toDisplay($0)) } ?? "--"
        let avg = isBP ? pair(mean(values), mean(dia)) : mean(values).map { fmt(toDisplay($0)) } ?? "--"
        let lo = isBP ? pair(values.min(), dia.min()) : values.min().map { fmt(toDisplay($0)) } ?? "--"
        let hi = isBP ? pair(values.max(), dia.max()) : values.max().map { fmt(toDisplay($0)) } ?? "--"
        // One size for the whole row, set by its longest value (Android's DetailStat does the same).
        let longest = [latest, avg, lo, hi].map(\.count).max() ?? 0
        return HStack(spacing: 0) {
            stat("Latest", latest, longest: longest)
            statDivider
            stat("Average", avg, longest: longest)
            statDivider
            stat("Min", lo, longest: longest)
            statDivider
            stat("Max", hi, longest: longest)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func stat(_ title: String, _ value: String, longest: Int) -> some View {
        VStack(spacing: 8) {
            Text(title.uppercased())
                .font(PulseFont.caption2).tracking(0.6)
                .foregroundStyle(PulseColors.textMuted)
                .lineLimit(1)
            // Step down for long values (a BP pair like 127/80), row-wide so neighbours match.
            Text(value)
                .font(longest <= 4 ? PulseFont.numberXL : PulseFont.numberL).monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(PulseColors.borderSubtle).frame(width: 1, height: 34)
    }

    // MARK: - Legend

    private var legend: some View {
        let zones = VitalsThresholdEngine.zones(for: metric, profile: profile, baseline: baselineForChart)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REFERENCE ZONES").font(PulseFont.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                Spacer()
                // HR zones are user-configurable (Standard / Auto / Custom) — deep-link to the editor.
                if metric == .heartRate {
                    Button("Edit") { path.append(AppRoute.settingsHeartRateZones) }
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.accent)
                }
            }
            ForEach(zones) { zone in
                HStack(spacing: 10) {
                    Circle().fill(zone.color).frame(width: 8, height: 8)
                    Text(zone.label).font(PulseFont.footnote).foregroundStyle(PulseColors.textPrimary)
                    Spacer()
                    Text(rangeText(zone)).font(PulseFont.caption.weight(.regular)).monospacedDigit().foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT THIS MEANS").font(PulseFont.caption2.weight(.semibold)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            Text(explainerText).font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(PulseColors.warning)
            Text(disclaimerText).font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous).stroke(PulseColors.warning.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Data

    private func reload() {
        // Today is the calendar day: the 24 h fetch always covers midnight onwards, so trim to it.
        let dayStart = Calendar.current.startOfDay(for: Date())
        func window(_ s: [MetricSample]) -> [MetricSample] { period == .today ? s.filter { $0.timestamp >= dayStart } : s }
        if metric == .bloodPressure {
            primary = window(MetricsService.metricRange(metric: .bloodPressureSystolic, range: period.range, context: modelContext))
            secondary = window(MetricsService.metricRange(metric: .bloodPressureDiastolic, range: period.range, context: modelContext))
        } else {
            primary = window(MetricsService.metricRange(metric: metric.metricKey, range: period.range, context: modelContext))
            secondary = []
        }
    }

    /// HRV detail can compute a real baseline because Week/Month fetch enough history.
    private var baselineForChart: BaselineStats? {
        metric == .hrv ? BaselineStats.compute(primary) : nil
    }

    private func detailBands(baseline: BaselineStats?) -> [ReferenceBand] {
        switch metric {
        case .spo2: return [ReferenceBand(lower: 95, upper: 100, colorToken: .cyan)]
        case .hrv:
            guard let baseline, baseline.isEstablished else { return [] }
            let half = max(6, baseline.mean * 0.12)
            return [ReferenceBand(lower: baseline.mean - half, upper: baseline.mean + half, colorToken: .metricAccent(.hrv), opacity: 0.12)]
        default: return []
        }
    }

    private func dashedRules(baseline: BaselineStats?) -> [Double] {
        if metric == .spo2 { return [92] }
        if metric == .hrv, let baseline, baseline.isEstablished { return [baseline.mean] }
        return []
    }


    // MARK: - Formatting helpers

    /// Formats a value already in display units (temperature and mmol/L glucose want one decimal).
    private func fmt(_ value: Double) -> String {
        if metric == .temperature { return String(format: "%.1f", value) }
        if metric == .glucose, glucoseUnit == .mmol { return String(format: "%.1f", value) }
        if metric == .met { return String(format: "%.1f", value) }
        if metric.isBloodComponent {
            return BloodComponents.format(toRaw(value), metric: metric, unit: glucoseUnit)
        }
        return "\(Int(value.rounded()))"
    }

    private func rangeText(_ zone: MetricZone) -> String {
        // Zone bounds are canonical; convert to display units before formatting.
        switch (zone.lower.map(toDisplay), zone.upper.map(toDisplay)) {
        case let (lo?, hi?): return "\(fmt(lo))–\(fmt(hi))"
        case let (lo?, nil): return "≥ \(fmt(lo))"
        case let (nil, hi?): return "< \(fmt(hi))"
        default: return ""
        }
    }

    private var isEstimatedMetric: Bool {
        metric == .glucose || metric.isBloodComponent
    }

    private var explainerText: String {
        switch metric {
        case .heartRate:
            return "Resting heart rate reflects how hard your heart works at rest. Guidelines cite 60–100 bpm, "
                + "but most healthy adults rest between 50 and 90; fitness, medication, caffeine, and stress all shift it. "
                + "You can adjust your zones from the legend above."
        case .spo2:
            return "Blood oxygen (SpO₂) is the percentage of oxygen your blood carries. 95–100% is normal; "
                + "altitude and lung conditions can lower it."
        case .hrv:
            return "Heart-rate variability is the variation between beats. It's highly individual, so we track it "
                + "against your personal baseline rather than a universal cutoff."
        case .bloodPressure:
            return "Blood pressure is systolic over diastolic (mmHg). The category is the worse of the two. "
                + "A ring estimate is not a substitute for a cuff."
        case .stress:
            return "A device wellness score from 0–100 based on heart-rate patterns. Lower is calmer. "
                + "It's an estimate, not a medical stress measure."
        case .fatigue:
            return "A device wellness score from 0–100 estimating tiredness. Higher means more fatigue. "
                + "It's a ring estimate, not a clinical scale."
        case .glucose:
            return "An estimated glucose value. No smart ring is cleared to measure glucose, so treat this "
                + "as a wellness estimate only."
        case .temperature:
            return "Skin temperature from the ring runs cooler than core body temperature. "
                + "Trends over time matter more than any single reading."
        case .respiration:
            return "Breaths per minute, logged by the ring every 5 minutes. A resting adult typically breathes "
                + "12–20 times a minute; activity and stress raise it."
        case .met:
            return "Metabolic equivalent: how hard you're working compared with sitting still (1 MET). "
                + "Brisk walking is about 3–4; running 8 or more."
        case .cardiacLoad:
            return "A relative score the ring derives from your heart-rate pattern. It has no clinical reference "
                + "range — compare it with your own trend."
        case .totalCholesterol:
            return "Total cholesterol in the blood, estimated optically by the ring. Only a blood test measures it."
        case .triglycerides:
            return "Triglycerides — blood fats that rise after meals — estimated optically by the ring."
        case .hdl:
            return "HDL (\u{201C}good\u{201D}) cholesterol, estimated optically by the ring."
        case .ldl:
            return "LDL cholesterol, estimated optically by the ring. Only a blood test measures it."
        case .uricAcid:
            return "Uric acid, estimated optically by the ring. The reference range depends on sex, "
                + "set in Settings → Profile."
        }
    }

    private var disclaimerText: String {
        switch metric {
        case .glucose:
            return "Estimated wellness metric — not for dosing or diabetes decisions. No smart ring or watch is "
                + "FDA-authorized to measure or estimate glucose on its own."
        case .bloodPressure:
            return "Ring blood pressure is an estimate. Calibrate against a validated cuff in Settings → Calibration, "
                + "and talk to a clinician about persistent high or low readings."
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid:
            return AgaraCopy.estimateDisclaimer
        default: return ""
        }
    }
}
