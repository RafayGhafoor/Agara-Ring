import SwiftUI

// The tiles come from `MeasurementRegistry` (Services/MeasurementRegistry.swift) — one `MeasurementSpec` per
// test, so a new test gets its tile, running UI, background run and notifications by being registered there.

/// The measure hub: a sheet titled "Measure" with a three-column grid of test tiles. Tapping a tile hands
/// the kind back (the caller swaps this sheet for the measurement ring). While the ring charges the tiles
/// are disabled under a banner.
struct MeasureHubSheet: View {
    let kinds: [MeasurementSpec]
    let isCharging: Bool
    /// The test already running (one optical test at a time): its tile reopens it, the others wait.
    var runningID: String? = nil
    let onSelect: (MeasurementSpec) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Measure")
                    .font(AgaraFont.title3)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { dismiss() }
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .agaraGlass(Capsule(), interactive: true)
            }

            if isCharging {
                ChargingBanner()
                    .accessibilityIdentifier("measure.chargingBanner")
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(kinds) { kind in
                    MeasureTile(kind: kind, enabled: !isCharging && (runningID == nil || runningID == kind.id),
                                running: runningID == kind.id) { onSelect(kind) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AgaraColors.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// "The ring is charging — measure when it's on your finger." Shared by the hub and the measurement sheet.
struct ChargingBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(AgaraColors.success)
                .accessibilityHidden(true)
            Text(MeasurementRefusal.chargingMessage)
                .font(AgaraFont.footnote)
                .foregroundStyle(AgaraColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AgaraColors.success.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct MeasureTile: View {
    let kind: MeasurementSpec
    let enabled: Bool
    var running = false
    let action: () -> Void

    /// Disabled because the ring charges, or because another test is running.
    private var isChargingHint: String { "Unavailable while the ring charges or another measurement runs." }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous)
        Button(action: action) {
            // Same recipe as Android's `MeasureTile`: glyph box pinned to the top, two lines reserved for the title
            // (so "Blood components" wrapping never moves its icon), the duration on the last line.
            VStack(spacing: 6) {
                IconTile(systemName: kind.symbolName, style: .tinted(kind.tint, backgroundOpacity: 0.18),
                         size: .large, shape: .circle)
                Text(kind.title)
                    .font(AgaraFont.footnote.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(running ? "Measuring…" : kind.durationText)
                    .font(AgaraFont.caption)
                    .foregroundStyle(running ? kind.tint : AgaraColors.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .top)
            // Tinted wash + hairline in the metric colour at Android's alphas (0.10 / 0.22).
            .background(kind.tint.opacity(0.10), in: shape)
            .overlay(shape.strokeBorder(kind.tint.opacity(0.22), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel("\(kind.title), about \(kind.seconds) seconds")
        .accessibilityHint(running ? "Shows the running measurement."
                           : enabled ? "Starts the measurement."
                           : isChargingHint)
        .accessibilityIdentifier("measure.tile.\(kind.id)")
    }
}
