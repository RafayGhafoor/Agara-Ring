import SwiftUI

/// Results for the combined vitals sweep — the one measurement that returns everything the ring
/// computes at once (the ring's `0x24` packet), rather than a single number.
///
/// Lives beside `MeasurementSheet` rather than inside it: the sheet's other four kinds all resolve to
/// one reading in the middle of the ring, and this is the only one that has to lay out a whole grid.
struct VitalsResultsView: View {
    let vitals: RingSyncCoordinator.VitalsReading

    struct VitalTile: Identifiable {
        let name: String
        let value: String
        let unit: String
        let icon: String
        let tint: Color
        var id: String { name }
    }

    /// One tile per metric the sweep actually produced — the ring leaves the rest at zero.
    static func tiles(for v: RingSyncCoordinator.VitalsReading) -> [VitalTile] {
        var tiles: [VitalTile] = []
        if let hr = v.heartRate {
            tiles.append(.init(name: "Heart Rate", value: "\(hr)", unit: "bpm",
                               icon: "heart.fill", tint: AgaraColors.heartRate))
        }
        if AgaraFeatureStore.isOn(.vitalsBp), let bp = v.bloodPressure {
            tiles.append(.init(name: "Blood Pressure", value: "\(bp.systolic)/\(bp.diastolic)", unit: "mmHg",
                               icon: "waveform.path.ecg.rectangle.fill", tint: AgaraColors.bloodPressure))
        }
        if let spo2 = v.spo2 {
            tiles.append(.init(name: "Blood Oxygen", value: "\(spo2)", unit: "%",
                               icon: "drop.fill", tint: AgaraColors.spo2))
        }
        // No fatigue tile: the Agara ring declares no fatigue capability (`a7` 1.7 = 0).
        if let stress = v.stress {
            tiles.append(.init(name: "Stress", value: "\(stress)", unit: "",
                               icon: "bolt.fill", tint: AgaraColors.stress))
        }
        if let hrv = v.hrv {
            tiles.append(.init(name: "HRV", value: "\(hrv)", unit: "ms",
                               icon: "waveform.path.ecg", tint: AgaraColors.hrv))
        }
        if AgaraFeatureStore.isOn(.vitalsGlucose), let sugar = v.bloodSugarMgdl {
            tiles.append(.init(name: "Blood Sugar", value: "\(Int(sugar.rounded()))", unit: "mg/dL",
                               icon: "drop.fill", tint: AgaraColors.bloodSugar))
        }
        return tiles
    }

    /// Sits at the top of the sheet — the confirmation is a compact inline row so the cards get the
    /// vertical space. Centring them pushed the first row off the top on small phones.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(AgaraFont.footnote.weight(.bold))
                    .foregroundStyle(AgaraColors.success)
                    .frame(width: 30, height: 30)
                    .background(AgaraColors.success.opacity(0.10), in: Circle())
                    .overlay(Circle().stroke(AgaraColors.success.opacity(0.3), lineWidth: 1))
                Text("Reading complete")
                    .font(AgaraFont.bodyEmphasis)
                    .foregroundStyle(AgaraColors.textPrimary)
                Spacer(minLength: 0)
            }

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(Self.tiles(for: vitals)) { tile in
                        card(tile)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 24)
    }

    private func card(_ tile: VitalTile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: tile.icon).font(AgaraFont.footnote).foregroundStyle(tile.tint)
                Text(tile.name)
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textMuted)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tile.value)
                    .font(AgaraFont.numberXL).monospacedDigit()
                    .foregroundStyle(AgaraColors.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if !tile.unit.isEmpty {
                    Text(tile.unit).font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(AgaraColors.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AgaraColors.borderSubtle, lineWidth: 1))
    }
}
