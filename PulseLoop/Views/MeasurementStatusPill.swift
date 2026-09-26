import SwiftUI

/// The in-app banner for a measurement that runs while its sheet is closed (swiped away, another tab): it
/// says what is being measured — or the result once it lands — and a tap reopens the Measure sheet on it.
/// Lives under the app header so it follows the user across tabs. The in-app half of the plan's decision 2
/// (notifications only in the background; in the foreground the app itself shows progress and results).
struct MeasurementStatusPill: View {
    @State private var service = MeasurementService.shared

    var body: some View {
        if let spec = service.spec {
            Button {
                AgaraDeepLinks.shared.pending = .measure
            } label: {
                HStack(spacing: 10) {
                    IconTile(systemName: spec.symbolName, style: .tinted(spec.tint), size: .small, shape: .circle)
                    Text(text(spec))
                        .font(AgaraFont.footnote.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    if service.isRunning {
                        ProgressView().controlSize(.small).tint(spec.tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(AgaraFont.caption.weight(.semibold))
                        .foregroundStyle(AgaraColors.textMuted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .agaraGlass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text(spec))
            .accessibilityHint("Opens the measurement.")
            .accessibilityIdentifier("measurement.pill")
        }
    }

    private func text(_ spec: MeasurementSpec) -> String {
        switch service.stage {
        case .result: return service.resultText.map { "\(spec.title): \($0) · Saved" } ?? "\(spec.title) saved"
        case .error: return "\(spec.title): couldn't get a reading"
        default: return "Measuring \(spec.title.lowercased())…"
        }
    }
}
