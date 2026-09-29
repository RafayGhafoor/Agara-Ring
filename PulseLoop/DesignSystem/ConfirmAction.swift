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
    /// Forget unbinds the ring and removes it from the app; history stays. Copy from `brand.yaml` (both apps).
    static func forgetRing(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "forgetRing",
            title: AgaraCopy.confirmForgetTitle,
            message: AgaraCopy.confirmForgetBody,
            confirmLabel: "Forget",
            perform: perform
        )
    }

    /// Disconnect drops the link but keeps the pairing; nothing is deleted, so it is `normal` severity.
    static func disconnectRing(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "disconnectRing",
            title: AgaraCopy.confirmDisconnectTitle,
            message: AgaraCopy.confirmDisconnectBody,
            confirmLabel: "Disconnect",
            severity: .normal,
            perform: perform
        )
    }

    static func deleteMeal(name: String?, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "deleteMeal",
            title: AgaraCopy.confirmDeleteMealTitle,
            message: name.map { "\($0): " + AgaraCopy.confirmDeleteMealBody } ?? AgaraCopy.confirmDeleteMealBody,
            confirmLabel: "Delete",
            perform: perform
        )
    }

    static func resetCalibration(_ target: CalibrationResetTarget, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "resetCalibration.\(target)",
            title: AgaraCopy.confirmResetCalibrationTitle,
            message: "\(target.label): " + AgaraCopy.confirmResetCalibrationBody,
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
            title: AgaraCopy.confirmDisconnectStravaTitle,
            message: AgaraCopy.confirmDisconnectStravaBody,
            confirmLabel: "Disconnect",
            perform: perform
        )
    }

    static func signOutCloud(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "signOutCloud",
            title: AgaraCopy.confirmSignOutTitle,
            message: AgaraCopy.confirmSignOutBody,
            confirmLabel: "Sign out",
            perform: perform
        )
    }

    /// Settings › Agara Cloud › Delete account: erases the cloud copy for good; the data on this phone stays.
    static func deleteCloudAccount(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(key: "deleteCloudAccount", title: AgaraCloudCopy.deleteAccountTitle, message: AgaraCloudCopy.deleteAccountBody,
                      confirmLabel: AgaraCloudCopy.deleteAccountConfirm, perform: perform)
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

    /// Delete one vital reading (Android's copy, issue #60). A history reading gets the "stays deleted" line.
    static func deleteReading(value: String, time: String, fromHistory: Bool, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "deleteReading",
            title: AgaraCopy.confirmDeleteReadingTitle,
            message: "\(value) at \(time).\n\n" + AgaraCopy.confirmDeleteReadingBody,
            confirmLabel: "Delete",
            perform: perform
        )
    }

    /// Delete an hour of steps (Android's copy, issue #70).
    static func deleteSteps(steps: Int, hours: String, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "deleteSteps",
            title: AgaraCopy.confirmDeleteStepsHourTitle,
            message: "\(steps.formatted()) steps between \(hours).\n\n" + AgaraCopy.confirmDeleteStepsHourBody,
            confirmLabel: "Delete",
            perform: perform
        )
    }

    static func resetAppData(confirmLabel: String = "Reset app data", _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(key: "resetAppData", title: AgaraCopy.confirmResetAppDataTitle, message: AgaraCopy.confirmResetAppDataBody,
                      confirmLabel: confirmLabel, perform: perform)
    }

    static func reseedDemo(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(key: "reseedDemo", title: AgaraCopy.confirmReseedDemoTitle, message: AgaraCopy.confirmReseedDemoBody,
                      confirmLabel: "Load", perform: perform)
    }

    /// Settings › Data & Export › Storage › Diagnostics › Clear raw data. Copy from `brand.yaml` (both apps): it says the raw
    /// trace feeds the sleep repair, so clearing it removes the ability to re-derive past nights from it.
    static func clearRawData(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(key: "clearRawData", title: AgaraCopy.confirmClearRawDataTitle, message: AgaraCopy.confirmClearRawDataBody,
                      confirmLabel: "Clear", perform: perform)
    }

    static func clearDemo(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(key: "clearDemo", title: AgaraCopy.confirmClearDemoTitle, message: AgaraCopy.confirmClearDemoBody,
                      confirmLabel: "Clear", perform: perform)
    }

    /// Settings › Privacy › Delete all my data: a full local wipe including sign-ins and API keys. Copy from `brand.yaml`.
    /// Signed in to Agara Cloud, the wipe also signs out and clears the tokens, and the message says the cloud copy is a
    /// separate action (Settings › Agara Cloud › Delete account).
    static func deleteAllData(cloudSignedIn: Bool = false, _ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(key: "deleteAllData", title: AgaraCopy.deleteAllDataTitle,
                      message: AgaraCopy.deleteAllDataBody + (cloudSignedIn ? "\n\n" + AgaraCloudCopy.deleteAllDataCloudNote : ""),
                      confirmLabel: "Delete everything", perform: perform)
    }

    static func replaceAllData(_ perform: @escaping () -> Void) -> ConfirmAction {
        ConfirmAction(
            key: "replaceAllData",
            title: AgaraCopy.confirmReplaceDataTitle,
            message: AgaraCopy.confirmReplaceDataBody,
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
