import SwiftUI

/// The Vitals "Blood components" card (flag `blood_components`): the five latest estimates in a compact
/// grid, how many are out of range, and the shared estimate disclaimer. Tapping a value opens its
/// detail screen. Same content as Android's card.
struct VitalBloodComponentsCard: View {
    let summary: BloodComponentsSummary
    let unit: GlucoseUnit
    let sex: BiologicalSex
    let onSelect: (MetricKind) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(PulseColors.bloodSugar)
                    .frame(width: 8, height: 8)
                    .shadow(color: PulseColors.bloodSugar.opacity(0.7), radius: 5)
                Text("BLOOD COMPONENTS")
                    .font(PulseFont.caption2).tracking(1.0)
                    .foregroundStyle(PulseColors.textMuted)
                HelpTip(AgaraHelp.bloodComponents, size: 11)
                Spacer(minLength: 4)
                Text("ESTIMATED")
                    .font(PulseFont.nano).tracking(0.8)
                    .foregroundStyle(PulseColors.warning)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(PulseColors.warning.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 6) {
                Image(systemName: summary.abnormalCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(summary.abnormalCount == 0 ? PulseColors.success : PulseColors.warning)
                    .accessibilityHidden(true)
                Text(summary.abnormalText)
                    .font(PulseFont.subheadline.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                HelpTip(AgaraHelp.abnormalCount)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(MetricKind.bloodComponents) { metric in
                    if let value = summary.values[metric] {
                        BloodComponentCell(metric: metric, value: value, unit: unit, sex: sex) { onSelect(metric) }
                    }
                }
            }

            Text(AgaraCopy.estimateDisclaimer)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }
}

/// One value in the grid: short name, value + unit, tinted when out of range.
private struct BloodComponentCell: View {
    let metric: MetricKind
    let value: Double
    let unit: GlucoseUnit
    let sex: BiologicalSex
    let action: () -> Void

    private var abnormal: Bool { BloodComponents.isAbnormal(value, metric: metric, sex: sex) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(BloodComponentsResultView.shortName(metric))
                    .font(PulseFont.caption2)
                    .foregroundStyle(PulseColors.textMuted)
                    .lineLimit(1)
                Text(BloodComponents.format(value, metric: metric, unit: unit))
                    .font(PulseFont.numberL).monospacedDigit()
                    .foregroundStyle(abnormal ? PulseColors.warning : PulseColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(BloodComponents.displayUnit(metric: metric, unit: unit))
                    .font(PulseFont.caption2)
                    .foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(PulseColors.cardSoft, in: RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metric.title), \(BloodComponents.format(value, metric: metric, unit: unit)) "
            + "\(BloodComponents.displayUnit(metric: metric, unit: unit))\(abnormal ? ", out of range" : "")")
        .accessibilityHint("Opens the detail")
    }
}

/// The measurement sheet's result for the blood-components test: the five values and the abnormal count.
struct BloodComponentsResultView: View {
    let reading: BloodComponentsReading
    let unit: GlucoseUnit
    let sex: BiologicalSex

    static func shortName(_ metric: MetricKind) -> String {
        switch metric {
        case .totalCholesterol: return "Cholesterol"
        case .triglycerides: return "Triglycerides"
        case .hdl: return "HDL"
        case .ldl: return "LDL"
        case .uricAcid: return "Uric acid"
        default: return metric.title
        }
    }

    var body: some View {
        let values = Dictionary(uniqueKeysWithValues: reading.measurements.compactMap { kind, value in
            MetricKind.bloodComponents.first { $0.measurementKind == kind }.map { ($0, value) }
        })
        let abnormal = BloodComponents.abnormalCount(reading, sex: sex)
        VStack(alignment: .leading, spacing: 12) {
            Text(abnormal == 0 ? "No values out of range"
                 : abnormal == 1 ? "1 value out of range" : "\(abnormal) values out of range")
                .font(PulseFont.subheadline.weight(.semibold))
                .foregroundStyle(abnormal == 0 ? PulseColors.success : PulseColors.warning)
            ForEach(MetricKind.bloodComponents) { metric in
                if let value = values[metric] {
                    HStack {
                        Text(metric.title)
                            .font(PulseFont.subheadline)
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer()
                        Text("\(BloodComponents.format(value, metric: metric, unit: unit)) "
                             + BloodComponents.displayUnit(metric: metric, unit: unit))
                            .font(PulseFont.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(BloodComponents.isAbnormal(value, metric: metric, sex: sex)
                                             ? PulseColors.warning : PulseColors.textPrimary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            Text(AgaraCopy.estimateDisclaimer)
                .font(PulseFont.caption)
                .foregroundStyle(PulseColors.textMuted)
                .padding(.top, 4)
        }
        .padding(18)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }
}
