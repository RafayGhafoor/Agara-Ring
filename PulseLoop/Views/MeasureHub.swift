import SwiftUI

/// One on-demand test the measure hub can offer. The hub is driven entirely by `MeasureKind.all`, so
/// adding a test is one entry here (plus its `MeasurementSheet.Kind` presentation). Same ids and order
/// as Android's `MeasureKind` (measure-hub spec §3).
struct MeasureKind: Identifiable, Equatable {
    /// Shared id: `heartRate`, `spo2`, `bloodPressure`, `stress`, `glucose`, `bloodComponents`.
    let id: String
    /// The measurement-ring sheet this tile opens (its title, icon and tint come from there).
    let sheetKind: MeasurementSheet.Kind
    /// Approximate duration shown on the tile.
    let seconds: Int
    /// Feature flags that must all be on (none = always offered).
    let flags: [AgaraFeature]
    /// Static fallback: the family capability, used when the ring's own packets haven't been seen.
    let capability: WearableCapability
    /// What the ring's capability packets must say (used when `capability_probe` is on and seen).
    let ringSupport: KeyPath<RingCapabilities, Bool>

    var title: String { sheetKind.title }
    var symbolName: String { sheetKind.symbolName }
    var tint: Color { sheetKind.tint }
    var durationText: String { "~\(seconds) s" }

    static let all: [MeasureKind] = [
        MeasureKind(id: "heartRate", sheetKind: .hr, seconds: AgaraConfig.Ring.measureTypicalSecondsHeartRate, flags: [],
                    capability: .manualHeartRate, ringSupport: \.heartRate),
        MeasureKind(id: "spo2", sheetKind: .spo2, seconds: AgaraConfig.Ring.measureTypicalSecondsSpo2, flags: [],
                    capability: .manualSpo2, ringSupport: \.spo2),
        MeasureKind(id: "bloodPressure", sheetKind: .bloodPressure, seconds: AgaraConfig.Ring.measureTypicalSecondsBloodPressure, flags: [],
                    capability: .manualBloodPressure, ringSupport: \.bloodPressure),
        MeasureKind(id: "stress", sheetKind: .stress, seconds: AgaraConfig.Ring.measureTypicalSecondsStress, flags: [.measureStress],
                    capability: .manualStress, ringSupport: \.stress),
        MeasureKind(id: "glucose", sheetKind: .glucose, seconds: AgaraConfig.Ring.measureTypicalSecondsGlucose, flags: [.measureGlucose],
                    capability: .manualBloodSugar, ringSupport: \.bloodGlucose),
        MeasureKind(id: "bloodComponents", sheetKind: .bloodComponents, seconds: AgaraConfig.Ring.measureTypicalSecondsBloodComponents,
                    flags: [.measureLipids, .bloodComponents],
                    capability: .manualBloodComponents, ringSupport: \.bloodComponents),
    ]

    /// The tiles to offer, in order: every flag on, and supported — by the ring's own capability packets
    /// when the probe is on and has run, otherwise by the family's static capability list.
    static func available(capabilities: Set<WearableCapability>,
                          ring: RingCapabilities?,
                          isOn: (AgaraFeature) -> Bool) -> [MeasureKind] {
        let probe = isOn(.capabilityProbe) ? ring : nil
        return all.filter { kind in
            guard kind.flags.allSatisfy(isOn) else { return false }
            if let probe { return probe[keyPath: kind.ringSupport] }
            return capabilities.contains(kind.capability)
        }
    }

    static func == (lhs: MeasureKind, rhs: MeasureKind) -> Bool { lhs.id == rhs.id }
}

/// The measure hub: a sheet titled "Measure" with a three-column grid of test tiles. Tapping a tile hands
/// the kind back (the caller swaps this sheet for the measurement ring). While the ring charges the tiles
/// are disabled under a banner.
struct MeasureHubSheet: View {
    let kinds: [MeasureKind]
    let isCharging: Bool
    let onSelect: (MeasureKind) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Measure")
                    .font(PulseFont.title3)
                    .foregroundStyle(PulseColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { dismiss() }
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColors.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .pulseGlass(Capsule(), interactive: true)
            }

            if isCharging {
                ChargingBanner()
                    .accessibilityIdentifier("measure.chargingBanner")
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(kinds) { kind in
                    MeasureTile(kind: kind, enabled: !isCharging) { onSelect(kind) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PulseColors.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// "The ring is charging — measure when it's on your finger." Shared by the hub and the measurement sheet.
struct ChargingBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(PulseColors.success)
                .accessibilityHidden(true)
            Text(MeasurementRefusal.chargingMessage)
                .font(PulseFont.footnote)
                .foregroundStyle(PulseColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PulseColors.success.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct MeasureTile: View {
    let kind: MeasureKind
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: kind.symbolName)
                    .font(PulseFont.title3)
                    .foregroundStyle(kind.tint)
                    .frame(width: 44, height: 44)
                    .background(kind.tint.opacity(0.14), in: Circle())
                Text(kind.title)
                    .font(PulseFont.footnote.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(kind.durationText)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 118)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
            .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous), interactive: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel("\(kind.title), about \(kind.seconds) seconds")
        .accessibilityHint(enabled ? "Starts the measurement." : MeasurementRefusal.chargingMessage)
        .accessibilityIdentifier("measure.tile.\(kind.id)")
    }
}
