import SwiftUI

// Per-metric card bodies: each wraps the shared `VitalCard` chrome around the right visualization
// (zone line chart, ring gauge, or dual gauge) and falls back to a metric-specific empty state.
// The threshold engine drives all coloring via the card view-model.

// MARK: - Chart-style cards (HR / SpO₂ / HRV / Temperature)

/// A full-width card with a zone-colored line chart. The `colorForValue` closure is built once here
/// from the engine so the line and points pick up zone colors.
struct VitalChartCard: View {
    let model: VitalCardViewModel
    let profile: UserPhysiologyProfile
    let baseline: BaselineStats?
    var showPoints: Bool = false
    let onTap: () -> Void

    var body: some View {
        VitalCard(model: model, onTap: onTap) {
            if model.isEmpty {
                VitalEmptyState(metric: model.metric)
            } else {
                ZoneLineChart(
                    samples: model.samples,
                    metric: model.metric,
                    yDomain: model.yDomain,
                    referenceBands: model.referenceBands,
                    range: .twentyFourHours,
                    // A dot per reading reads as a band of noise once the ring has logged SpO₂ all day
                    // (every 5 min): dots only for sparse spot readings, the line alone otherwise.
                    showPoints: showPoints && model.samples.count <= ChartAxes.denseDayReadings,
                    showAxes: true,
                    dashedRules: model.dashedRules,
                    thresholds: VitalsThresholdEngine.zoneThresholds(
                        for: model.metric, profile: profile, baseline: baseline
                    ),
                    colorForValue: { value in
                        VitalsThresholdEngine.colorToken(
                            forValue: value, metric: model.metric, profile: profile, baseline: baseline
                        ).color
                    }
                )
            }
        }
    }
}

// MARK: - Compact gauge cards (Stress / Fatigue)

struct VitalGaugeCard: View {
    let model: VitalCardViewModel
    var size: CGFloat = 190
    let onTap: () -> Void

    var body: some View {
        // No top value row — the gauge center IS the value. The footer carries context + trend.
        VitalCard(model: model, showsValueRow: false, footerOverride: gaugeFooter(model), onTap: onTap) {
            if model.isEmpty {
                VitalEmptyState(metric: model.metric)
            } else {
                VitalRingGauge(
                    value: gaugeValue,
                    domain: model.yDomain,
                    zones: model.zones,
                    valueColor: model.statusColor,
                    centerValue: model.valueText,
                    centerUnit: model.unitText,
                    centerStatus: model.statusText,
                    size: size,
                    lineWidth: 16
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var gaugeValue: Double { Double(model.valueText) ?? 0 }
}

// MARK: - Glucose gauge card

struct VitalGlucoseCard: View {
    let model: VitalCardViewModel
    let onTap: () -> Void

    var body: some View {
        VitalCard(model: model, showsValueRow: false, footerOverride: gaugeFooter(model), onTap: onTap) {
            if model.isEmpty {
                VitalEmptyState(metric: .glucose)
            } else {
                VitalRingGauge(
                    value: Double(model.valueText) ?? 0,
                    domain: model.yDomain,
                    zones: model.zones,
                    valueColor: model.statusColor,
                    centerValue: model.valueText,
                    centerUnit: model.unitText,
                    centerStatus: model.statusText,
                    size: 190,
                    lineWidth: 16
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }
}

/// A one-line context footer for gauge cards: subtitle + trend delta (e.g. "Lower is calmer · ↓ 8 vs earlier").
private func gaugeFooter(_ model: VitalCardViewModel) -> String? {
    let parts = [model.subtitleText, model.trend.deltaText].compactMap { $0 }
    return parts.isEmpty ? model.lastUpdatedText : parts.joined(separator: " · ")
}

// MARK: - Blood pressure dual-ring card

struct VitalBloodPressureCard: View {
    let model: VitalCardViewModel
    let systolic: Double?
    let diastolic: Double?
    let systolicZones: [MetricZone]
    let diastolicZones: [MetricZone]
    let onTap: () -> Void

    var body: some View {
        VitalCard(model: model, onTap: onTap) {
            if model.isEmpty || systolic == nil || diastolic == nil {
                VitalEmptyState(metric: .bloodPressure)
            } else {
                // Two separate compact gauges — systolic on the left, diastolic on the right — instead
                // of the cluttered concentric dual ring.
                HStack(spacing: 16) {
                    ringColumn(
                        title: "Systolic",
                        value: systolic!,
                        domain: 80...190,
                        zones: systolicZones,
                        fallback: AgaraColors.bloodPressure
                    )
                    ringColumn(
                        title: "Diastolic",
                        value: diastolic!,
                        domain: 50...130,
                        zones: diastolicZones,
                        fallback: AgaraColors.bloodPressure.opacity(0.7)
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func ringColumn(title: String, value: Double, domain: ClosedRange<Double>,
                            zones: [MetricZone], fallback: Color) -> some View {
        // Color the value arc by the zone the reading falls in (so a normal reading is green, not the
        // metric's pink accent). Falls back to the metric color if no zone matches.
        let valueColor = zones.first(where: { $0.contains(value) })?.color ?? fallback
        return VStack(spacing: 8) {
            VitalRingGauge(
                value: value,
                domain: domain,
                zones: zones,
                valueColor: valueColor,
                centerValue: "\(Int(value))",
                centerUnit: "mmHg",
                size: 130,
                lineWidth: 11
            )
            Text(title.uppercased())
                .font(AgaraFont.caption2.weight(.semibold)).tracking(0.8)
                .foregroundStyle(AgaraColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Metric-specific empty states

/// An empty card body tuned per metric, with an action hint. Holds a minimum height so the grid
/// doesn't jump when data arrives.
struct VitalEmptyState: View {
    let metric: MetricKind
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: compact ? 20 : 26))
                .foregroundStyle(metric.accentColor.opacity(0.7))
            Text(title)
                .font(AgaraFont.face(compact ? 12 : 14, .medium))
                .foregroundStyle(AgaraColors.textPrimary)
                .multilineTextAlignment(.center)
            if !compact {
                Text(action)
                    .font(AgaraFont.caption.weight(.regular))
                    .foregroundStyle(AgaraColors.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 110 : 150)
    }

    private var icon: String {
        switch metric {
        case .heartRate: return "heart"
        case .spo2: return "lungs"
        case .hrv: return "waveform.path.ecg"
        case .bloodPressure: return "gauge.with.dots.needle.bottom.50percent"
        case .stress: return "brain.head.profile"
        case .fatigue: return "bed.double"
        case .glucose: return "drop"
        case .temperature: return "thermometer.medium"
        case .respiration: return "wind"
        case .met: return "flame"
        case .cardiacLoad: return "heart.circle"
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid: return "drop.triangle"
        }
    }

    private var title: String {
        switch metric {
        case .heartRate: return "No heart rate yet"
        case .spo2: return "No oxygen readings yet"
        case .hrv: return "Building baseline"
        case .bloodPressure: return "No BP estimate yet"
        case .stress: return "No stress data yet"
        case .fatigue: return "No fatigue score yet"
        case .glucose: return "No glucose estimate yet"
        case .temperature: return "No temperature yet"
        case .respiration: return "No respiration data yet"
        case .met: return "No MET data yet"
        case .cardiacLoad: return "No cardiac load yet"
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid: return "No estimate yet"
        }
    }

    private var action: String {
        switch metric {
        case .heartRate: return "Take a reading to start your trend."
        case .spo2: return "Measure SpO₂ to start your trend."
        case .hrv: return "Wear your ring overnight to learn your baseline."
        case .bloodPressure: return "Take a combined measurement and sync."
        case .stress: return "Wear the ring through the day and sync."
        case .fatigue: return "Sync your ring to see today's score."
        case .glucose: return "Estimated from your profile — set it in Settings → Profile."
        case .temperature: return "Trends appear after overnight wear."
        case .respiration, .met, .cardiacLoad: return "Wear the ring and sync — it logs this every 5 minutes."
        case .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid:
            return "The ring estimates these every 30 minutes — sync to see them."
        }
    }
}
