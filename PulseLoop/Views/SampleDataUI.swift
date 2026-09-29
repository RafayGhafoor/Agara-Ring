import SwiftUI

/// The persistent "Sample data" banner (under the app header on every tab) and the "Sample" chip on every value and
/// chart. Both read `SampleDataStore.isActive`; copy is `brand.yaml` (`sample_data_banner`, `sample_data_chip`).
/// App-only views (not compiled into the widget extension).
struct SampleDataBanner: View {
    var onPair: () -> Void

    var body: some View {
        Button(action: onPair) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(AgaraFont.footnote.weight(.semibold))
                    .accessibilityHidden(true)
                Text(AgaraCopy.sampleDataBanner)
                    .font(AgaraFont.footnote.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(AgaraFont.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AgaraColors.warning)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgaraColors.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AgaraCopy.sampleDataBanner)
        .accessibilityHint("Opens ring pairing")
        .accessibilityIdentifier("sample.banner")
    }
}

/// The small "Sample" capsule.
struct SampleChip: View {
    var body: some View {
        Text(AgaraCopy.sampleDataChip.uppercased())
            .font(AgaraFont.nano).tracking(0.8)
            .foregroundStyle(AgaraColors.warning)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(AgaraColors.warning.opacity(0.14), in: Capsule())
            .accessibilityLabel(AgaraCopy.sampleDataChip)
            .accessibilityIdentifier("sample.chip")
    }
}

/// `.sampleChip()` overlays the chip on a card's top-trailing corner while sample data is loaded.
private struct SampleChipModifier: ViewModifier {
    @State private var store = SampleDataStore.shared
    var alignment: Alignment = .topTrailing

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if store.isActive {
                SampleChip().padding(10).allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Marks a card that shows a value or chart as sample data (only while `SampleDataStore.isActive`).
    func sampleChip(_ alignment: Alignment = .topTrailing) -> some View { modifier(SampleChipModifier(alignment: alignment)) }
}

/// Inline variant for card headers that already lay out chips (`VitalCard`, `TodayTile`).
struct SampleChipInline: View {
    @State private var store = SampleDataStore.shared
    var body: some View {
        if store.isActive { SampleChip() }
    }
}
