import SwiftUI
import SwiftData
import UserNotifications

/// Coach Check-Ins detail screen. Hosts the daily Coach check-in controls (enable, morning/evening
/// windows, test send). These depend on the AI Coach being enabled, so when it's off the controls are
/// shown disabled with a hint to turn the Coach on.
struct NotificationsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @State private var store = CoachSettingsStore.shared
    @State private var testStatus: String?
    @State private var notifPermissionDenied = false
    @State private var features = AgaraFeatureStore.shared

    private var coachEnabled: Bool { store.settings.coachMasterEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !coachEnabled {
                    StatusCopy(
                        title: "AI Coach is off",
                        body: "Enable the AI Coach to change these — daily check-ins are written by the coach from your recent trends."
                    )
                }

                notificationsControls
                    .disabled(!coachEnabled)
                    .opacity(coachEnabled ? 1 : 0.5)

                // Ring battery alerts moved to the Wearable screen (`RingBatteryAlertToggle`) so they stay
                // reachable with the coach off (parity audit 2026-09-26).
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Coach Check-Ins")
    }

    @ViewBuilder private var notificationsControls: some View {
        SettingsGroup(header: "Daily check-ins") {
            FormToggleRow(title: "Daily check-in notifications", isOn: Binding(
                get: { store.settings.notificationsEnabled },
                set: { setNotifications($0) }
            ))
            if store.settings.notificationsEnabled {
                FormValueRow(title: "Morning") { hourPicker(hourBinding(\.morningHour)) }
                if features.isOn(.coachCheckinExtras) {
                    FormValueRow(title: "Midday") { hourPicker(hourBinding(\.middayHour)) }
                }
                FormValueRow(title: "Evening") { hourPicker(hourBinding(\.eveningHour)) }
            }
        }

        if store.settings.notificationsEnabled {
            QuickActionButton(label: "Send a test check-in now") { sendTestCheckin() }
            if let testStatus {
                Text(testStatus).font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                    .padding(.horizontal, 4)
            }

            // Proactive anomaly alerts — on-device only; behind `coach_checkin_extras` (iOS only today) (free/private local
            // inference makes "watch the stream and speak up" practical).
            if features.isOn(.coachCheckinExtras) {
            SettingsGroup(
                header: "Proactive alerts",
                footer: store.settings.providerMode == .appleOnDevice
                    ? "When something looks off (low SpO₂, short sleep), I'll send a calm heads-up — generated privately on your iPhone."
                    : "Requires the On-device (Apple) provider. Switch to it in AI Coach settings to enable."
            ) {
                FormToggleRow(title: "Anomaly heads-ups (on-device)", isOn: Binding(
                    get: { store.settings.proactiveAlertsEnabled },
                    set: { store.settings.proactiveAlertsEnabled = $0 }
                ))
            }
            }
        }
        if notifPermissionDenied {
            Text(AgaraCopy.notificationsDisabled)
                .font(AgaraFont.caption).foregroundStyle(AgaraColors.danger)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Notification helpers (relocated from CoachSettingsSection)

    private func hourPicker(_ binding: Binding<Int>) -> some View {
        Picker("Hour", selection: binding) {
            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
        }
        .pickerStyle(.menu)
        .tint(AgaraColors.accent)
    }

    private func hourBinding(_ keyPath: WritableKeyPath<CoachSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0; CoachNotificationScheduler.shared.scheduleNext() }
        )
    }

    private func setNotifications(_ on: Bool) {
        guard on else {
            store.settings.notificationsEnabled = false
            CoachNotificationScheduler.shared.cancel()
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            store.settings.notificationsEnabled = granted
            notifPermissionDenied = !granted
            if granted { CoachNotificationScheduler.shared.scheduleNext() }
        }
    }

    private func sendTestCheckin() {
        testStatus = "Sending…"
        let service = CoachNotificationService(modelContext: modelContext, coordinator: coordinator)
        Task {
            let outcome = await service.runDueSlot(force: true)
            switch outcome {
            case .sent(let slot): testStatus = "Sent a \(slot.label.lowercased()) check-in."
            default: testStatus = "Couldn't send (\(outcome))."
            }
        }
    }

}
