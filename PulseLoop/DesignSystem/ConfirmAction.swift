import SwiftUI

/// One confirmation for every important or destructive action (consistency framework, block A —
/// AGENTS.md Rule 10). A screen holds a `ConfirmAction?` and attaches `.confirmAction($pending)`; setting
/// the value asks, and the action runs only on the confirm button. Same name and shape as Android's
/// `ConfirmAction` (`ui/components/ConfirmAction.kt`), so both apps confirm the same things with the same
/// look: a centred alert, the confirm button on the right, destructive actions in red.
///
/// The standard actions (Disconnect, Forget, …) are the `static` factories below, so their copy is written
/// once. Anything new that deletes, unbinds, resets or signs out gets a factory here rather than an inline
/// `.alert`.
struct ConfirmAction: Identifiable {
    enum Severity: Equatable {
        /// A reversible but important step (enable check-ins, disconnect): a plain confirm button.
        case normal
        /// Deletes, unbinds or overwrites something: a red confirm button.
        case destructive
    }

    /// A stable name for the action (`forgetRing`, `disconnectRing`, …) — the identity, and what tests and
    /// traces refer to.
    let key: String
    let title: String
    let message: String
    let confirmLabel: String
    var cancelLabel: String = "Cancel"
    var severity: Severity = .destructive
    let perform: () -> Void

    var id: String { key }
}

// MARK: - The standard actions (copy mirrors Android's `ConfirmActions`)

extension ConfirmAction {
    /// Forget unbinds the ring and removes it from the app; history stays (audit batch A #24 copy).
    static func forgetRing(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "forgetRing",
            title: "Forget this ring?",
            message: "The ring is unbound and removed from the app. Your stored history stays. You can pair it again later.",
            confirmLabel: "Forget",
            perform: perform
        )
    }

    /// Disconnect drops the link but keeps the pairing; nothing is deleted, so it is `normal` severity.
    static func disconnectRing(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "disconnectRing",
            title: "Disconnect the ring?",
            message: "The ring stays paired but stops syncing until you reconnect it. Measurements and live heart rate pause.",
            confirmLabel: "Disconnect",
            severity: .normal,
            perform: perform
        )
    }

    static func deleteMeal(name: String?, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "deleteMeal",
            title: "Delete this meal?",
            message: name.map { "\($0) is removed from your food log." } ?? "The meal is removed from your food log.",
            confirmLabel: "Delete",
            perform: perform
        )
    }

    static func resetCalibration(_ target: CalibrationResetTarget, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "resetCalibration.\(target)",
            title: target.title,
            message: "Readings go back to the ring's uncalibrated values. You can calibrate again any time.",
            confirmLabel: "Reset",
            perform: perform
        )
    }

    /// Installing firmware is the riskiest thing the app does to the ring; the copy lives with the installer.
    static func installFirmware(version: String, minBattery: Int, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "installFirmware",
            title: FirmwareInstallText.confirmTitle,
            message: FirmwareInstallText.confirmBody(version: version, minBattery: minBattery),
            confirmLabel: "Install",
            cancelLabel: "Not now",
            perform: perform
        )
    }

    /// Daily coach check-ins need the notification permission, which the OS asks for only after "Enable".
    static func enableCoachCheckIns(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "enableCoachCheckIns",
            title: "Enable Coach Check-Ins?",
            message: "Get a daily check-in from your coach. You can change this anytime in Coach Check-Ins.",
            confirmLabel: "Enable",
            cancelLabel: "Not now",
            severity: .normal,
            perform: perform
        )
    }

    static func disconnectStrava(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "disconnectStrava",
            title: "Disconnect from Strava?",
            message: AgaraCopy.stravaDisconnectCopy + " Workouts already uploaded stay on Strava.",
            confirmLabel: "Disconnect",
            perform: perform
        )
    }

    static func signOutCloud(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "signOutCloud",
            title: "Sign out of Agara Cloud?",
            message: "Your data stays on this device.",
            confirmLabel: "Sign out",
            perform: perform
        )
    }

    static func removeAppleHealthData(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "removeAppleHealthData",
            title: "Remove \(AgaraCopy.appName) data from Apple Health?",
            message: "This deletes only the samples \(AgaraCopy.appName) wrote. Data from other apps is untouched.",
            confirmLabel: "Remove",
            perform: perform
        )
    }

    static func replaceAllData(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "replaceAllData",
            title: "Replace all data?",
            message: "This permanently deletes everything currently in the app and replaces it with the contents of this file. This can't be undone.",
            confirmLabel: "Delete old data & import",
            perform: perform
        )
    }
}

// MARK: - Presentation

private struct ConfirmActionModifier: ViewModifier {
    @Binding var pending: ConfirmAction?

    func body(content: Content) -> some View {
        content.alert(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(action.confirmLabel, role: action.severity == .destructive ? .destructive : nil) {
                action.perform()
            }
            Button(action.cancelLabel, role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }
}

extension View {
    /// Ask before running `pending` — see `ConfirmAction`. Set the binding to present; it clears itself on
    /// either button.
    func confirmAction(_ pending: Binding<ConfirmAction?>) -> some View {
        modifier(ConfirmActionModifier(pending: pending))
    }
}
