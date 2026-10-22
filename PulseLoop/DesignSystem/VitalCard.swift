import SwiftUI

/// The shared dashboard card chrome for every vital. Renders the header (accent dot + title +
/// optional Estimated chip), the big value, a color-coded status + trend, the metric body (chart or
/// gauge), and an optional "last updated" footer. Tapping opens the metric detail.
///
/// All numbers/labels come pre-computed in `VitalCardViewModel` — the card runs no threshold math.
struct VitalCard<Content: View>: View {
    let model: VitalCardViewModel
    var compact: Bool = false
    /// Whether to show the big top-left value + status row. Gauge cards set this false because the
    /// gauge already shows the value/status in its center (avoids the duplicated number).
    var showsValueRow: Bool = true
    /// Replaces the default "Updated …" footer (used by gauge cards for a context + trend line).
    var footerOverride: String?
    var onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    private var valueFontSize: CGFloat { compact ? 30 : 36 }
    private var footerText: String? { footerOverride ?? model.lastUpdatedText }

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                header
                if showsValueRow && !compact { valueRow }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 16 : 22)
            .padding(.vertical, compact ? 16 : 20)
            .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        // The header ⓘ is merged into this element, so VoiceOver gets its sentence as the hint.
        .accessibilityHint(model.metric.helpText ?? "")
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.accentColor)
                .frame(width: 8, height: 8)
                .shadow(color: model.accentColor.opacity(0.7), radius: 5)
            Text(model.title.uppercased())
                .font(AgaraFont.caption2).tracking(1.0)
                .foregroundStyle(AgaraColors.textMuted)
            if let help = model.metric.helpText, !compact {
                HelpTip(help, size: 11)
            }
            Spacer(minLength: 4)
            // "Updated …" lives top-right so it doesn't add a footer row and grow the card height.
            // Suppressed when the ESTIMATED chip is present so the two don't crowd the header.
            if let footer = footerText, !compact, !model.isEstimated, !SampleDataStore.shared.isActive {
                Text(footer)
                    .font(AgaraFont.caption2.weight(.regular))
                    .foregroundStyle(AgaraColors.textMuted)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if model.isEstimated {
                estimatedChip
            }
            SampleChipInline()
        }
    }

    private var estimatedChip: some View {
        Text("ESTIMATED")
            .font(AgaraFont.nano).tracking(0.8)
            .foregroundStyle(AgaraColors.warning)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(AgaraColors.warning.opacity(0.14), in: Capsule())
    }

    // MARK: - Value + status + trend

    private var valueRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.valueText)
                    .font(AgaraFont.face(valueFontSize, .semibold).monospacedDigit())
                    .monospacedDigit()
                    .foregroundStyle(AgaraColors.textPrimary)
                    .contentTransition(.numericText())
                if let unit = model.unitText {
                    Text(unit)
                        .font(AgaraFont.footnote)
                        .foregroundStyle(AgaraColors.textMuted)
                }
            }
            HStack(spacing: 10) {
                Text(model.statusText.uppercased())
                    .font(AgaraFont.caption2.weight(.semibold)).tracking(0.8)
                    .foregroundStyle(model.statusColor)
                if let delta = model.trend.deltaText {
                    HStack(spacing: 3) {
                        Image(systemName: model.trend.symbol).font(AgaraFont.micro.weight(.semibold))
                        Text(delta).font(AgaraFont.caption2)
                    }
                    .foregroundStyle(AgaraColors.textMuted)
                }
            }
            if let range = model.rangeText {
                Text(range).font(AgaraFont.caption.weight(.regular)).monospacedDigit().foregroundStyle(AgaraColors.textMuted)
            }
            if let subtitle = model.subtitleText {
                Text(subtitle).font(AgaraFont.caption.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
            }
        }
        .sensoryFeedback(.success, trigger: model.valueText)
    }

    private var accessibilityText: String {
        var parts = [model.title, model.valueText]
        if let unit = model.unitText { parts.append(unit) }
        parts.append(model.statusText)
        if let delta = model.trend.deltaText { parts.append(delta) }
        if model.isEstimated { parts.append("estimated") }
        return parts.joined(separator: ", ")
    }
}
