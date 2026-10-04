import SwiftUI
import UIKit

/// The words the install flow shows, per state. Pure, so it is unit-tested. Agara copy only; identical to
/// Android `FirmwareInstallText`.
enum FirmwareInstallText {
    static let confirmTitle = "Install firmware?"

    static func confirmBody(version: String, minBattery: Int) -> String {
        "Firmware \(version) will be written to your AGARA Health ring. This takes several minutes.\n\n"
            + "• Keep the ring on its charger, right next to the phone (battery at least \(minBattery) %).\n"
            + "• Keep the app open — the screen stays on until it finishes.\n"
            + "• The ring restarts when it's done.\n\n"
            + "If the update is interrupted the ring may stop working, and there's no way to recover it from "
            + "the app. Only continue if you accept that risk."
    }

    static func headline(_ state: InstallState) -> String {
        switch state {
        case .idle: return ""
        case let .preparing(resuming): return resuming ? "Reconnected — resuming…" : "Preparing the ring…"
        case .transferring: return "Installing · \(state.percent) %"
        case .paused: return "Paused by the ring · \(state.percent) %"
        case let .reconnecting(attempt, maxAttempts, _, _):
            return "Connection lost — reconnecting (\(attempt) of \(maxAttempts))"
        case .verifying: return "Restarting the ring…"
        case let .succeeded(version): return "Updated to \(version)"
        case .failed: return "Update didn't finish"
        }
    }

    static func detail(_ state: InstallState) -> String {
        switch state {
        case .idle: return ""
        case .preparing: return "Don't close the app. Keep the phone near the ring."
        case let .transferring(_, _, block, blocks):
            return "Block \(block) of \(blocks) · Don't close the app. Keep the phone near the ring."
        case .paused: return "The ring asked to wait a moment; it continues by itself."
        case .reconnecting: return "Keep the ring next to the phone. It continues where it stopped."
        case let .verifying(target): return "Waiting for the ring to restart and report \(target)."
        case .succeeded: return "Your AGARA Health ring is running the new firmware."
        case .failed: return state.failureMessage ?? ""
        }
    }

    /// 0…1 for the bar, or nil for an indeterminate spinner.
    static func fraction(_ state: InstallState) -> Double? {
        switch state {
        case .transferring, .paused, .reconnecting: return Double(state.percent) / 100
        default: return nil
        }
    }
}

/// Inside the release sheet once the download is Ready (debug builds with `firmware_install` on): what still
/// blocks the install, and the Install button that opens the confirm dialog. Re-evaluated every second, like
/// Android's section.
struct FirmwareInstallSection: View {
    let version: String
    let onConfirmed: () -> Void
    @State private var controller = FirmwareInstallController.shared
    @State private var confirm: ConfirmAction?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let gates = controller.gates()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(gates.enumerated()), id: \.offset) { _, gate in
                    Text("• \(gate.text(minBattery: controller.minBattery))")
                        .font(AgaraFont.footnote)
                        .foregroundStyle(AgaraColors.textSecondary)
                }
                PrimaryButton(title: "Install on ring", systemImage: "arrow.up.circle") {
                    confirm = .installFirmware(version: version, minBattery: controller.minBattery) { onConfirmed() }
                }
                .disabled(!gates.isEmpty)
                .opacity(gates.isEmpty ? 1 : 0.45)
            }
        }
        .confirmAction($confirm)
    }
}

/// Full-screen install progress, presented over the whole app while an install is anywhere but idle. While the
/// ring may be mid-flash (`InstallState.busy`) there is no way out except Cancel before the first block, and
/// the screen stays on (idle timer off) for as long as this is up. Finished states offer Done / Try again.
struct FirmwareInstallScreen: View {
    @State private var controller = FirmwareInstallController.shared

    var body: some View {
        let state = controller.state
        ZStack {
            AgaraColors.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Firmware update")
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textSecondary)
                Text(FirmwareInstallText.headline(state))
                    .font(AgaraFont.title2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(headlineColor(state))
                    .accessibilityIdentifier("firmwareInstallHeadline")
                if state.busy {
                    if let fraction = FirmwareInstallText.fraction(state) {
                        ProgressView(value: fraction)
                            .tint(AgaraColors.accent)
                    } else {
                        ProgressView().tint(AgaraColors.accent)
                    }
                }
                Text(FirmwareInstallText.detail(state))
                    .font(AgaraFont.body)
                    .foregroundStyle(AgaraColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 8)
                buttons(state)
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
        .interactiveDismissDisabled(state.busy)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func headlineColor(_ state: InstallState) -> Color {
        switch state {
        case .succeeded: return AgaraColors.success
        case .failed: return AgaraColors.danger
        default: return AgaraColors.textPrimary
        }
    }

    @ViewBuilder
    private func buttons(_ state: InstallState) -> some View {
        switch state {
        case .succeeded:
            PrimaryButton(title: "Done", systemImage: "checkmark") { controller.dismiss() }
        case let .failed(failure, _):
            VStack(spacing: 12) {
                if failure.retryable {
                    PrimaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                        controller.dismiss()
                        controller.start()
                    }
                }
                SecondaryButton(title: "Close", systemImage: "xmark") { controller.dismiss() }
            }
        default:
            if controller.cancellable {
                SecondaryButton(title: "Cancel", systemImage: "xmark") { controller.cancel() }
            }
        }
    }
}

extension View {
    /// Presents `FirmwareInstallScreen` over everything while an install is running or has a result to show.
    func firmwareInstallCover() -> some View {
        modifier(FirmwareInstallCover())
    }
}

private struct FirmwareInstallCover: ViewModifier {
    @State private var controller = FirmwareInstallController.shared

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(
            get: { controller.state != .idle },
            set: { presented in if !presented { controller.dismiss() } }
        )) {
            FirmwareInstallScreen()
                .agaraRingEnvironment()
        }
    }
}
