import SwiftUI
import SwiftData
import UserNotifications

/// Settings › Notifications (spec §3). Replaces the old "Coach Check-Ins" detail screen: the nudges are the app's
/// notification story now, and this is where the user paces them.
///
/// Every control here writes `NudgePreferencesStore` / `NudgeLedgerStore` / `DailyGoalOverrideStore` and nothing else —
/// the engine reads those stores, so a switch flipped here explains itself on the next pass without a restart. The
/// daily coach check-ins that used to own this screen keep their group at the bottom (they are still shipped) and are
/// renamed so nothing is lost with the new title.
struct NotificationsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator

    @State private var prefs = NudgePreferencesStore.shared
    @State private var ledger = NudgeLedgerStore.shared
    @State private var overrides = DailyGoalOverrideStore.shared
    @State private var delivery = NudgeDeliveryService.shared
    @State private var coachStore = CoachSettingsStore.shared
    @State private var features = AgaraFeatureStore.shared
    @State private var testStatus: String?
    @State private var notifPermissionDenied = false
    @State private var feed = NudgeFeed()

    private var nudgesOn: Bool { features.isOn(.coachNudges) && prefs.masterOn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if features.isOn(.coachNudges) {
                    nudgeControls
                    tools
                }
                coachCheckins
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Notifications")
        .task { feed.refresh(context: modelContext) }
    }

    // MARK: - Nudges

    @ViewBuilder private var nudgeControls: some View {
        SettingsGroup(
            header: "Nudges",
            footer: "\(AgaraCopy.appName) works these out on your iPhone from your ring's data. No account, no model, no network."
        ) {
            FormToggleRow(title: "Nudges", isOn: Binding(
                get: { prefs.masterOn },
                set: { setMaster($0) }
            ))
        }

        if prefs.masterOn {
            SettingsGroup(
                header: "How many",
                footer: "Celebrations (a goal reached, a streak, a real improvement) get their own slot."
            ) {
                FormValueRow(title: "Nudges a day") {
                    Picker("Nudges a day", selection: Binding(get: { prefs.dailyLimit }, set: { prefs.dailyLimit = $0 })) {
                        ForEach(AgaraConfig.Nudges.policyDailyLimitMin...AgaraConfig.Nudges.policyDailyLimitMax, id: \.self) {
                            Text("\($0)").tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                    .accessibilityIdentifier("nudges.dailyLimit")
                }
                FormToggleRow(title: "Celebrations can come on top", isOn: Binding(
                    get: { prefs.celebrationsExtra },
                    set: { prefs.celebrationsExtra = $0 }
                ))
            }

            SettingsGroup(header: "Topics") {
                ForEach(NudgeTopic.allCases.filter { $0 != .celebrations }) { topic in
                    FormToggleRow(title: topic.title, isOn: Binding(
                        get: { prefs.isOn(topic) },
                        set: { prefs.set(topic, on: $0) }
                    ))
                    if topic == .weeklyReview, prefs.isOn(topic) {
                        FormValueRow(title: "Week starts") {
                            Picker("Day", selection: Binding(get: { prefs.weeklyWeekday }, set: { prefs.weeklyWeekday = $0 })) {
                                ForEach(1...7, id: \.self) { Text(NudgePreferencesStore.weekdayName($0)).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(AgaraColors.accent)
                        }
                        FormValueRow(title: "Time") {
                            Picker("Time", selection: Binding(get: { prefs.weeklyHour }, set: { prefs.weeklyHour = $0 })) {
                                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(AgaraColors.accent)
                        }
                    }
                }
            }

            SettingsGroup(
                header: "Quiet hours",
                footer: "A nudge that would land in quiet hours is dropped, not saved for later."
            ) {
                FormToggleRow(title: "Follow my sleep", isOn: Binding(
                    get: { prefs.quietHoursFollowSleep },
                    set: { prefs.quietHoursFollowSleep = $0 }
                ))
                if !prefs.quietHoursFollowSleep {
                    FormValueRow(title: "From") {
                        Picker("From", selection: Binding(get: { prefs.quietStartMinutes }, set: { prefs.quietStartMinutes = $0 })) {
                            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) {
                                Text(NudgePreferencesStore.hhmm($0)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(AgaraColors.accent)
                    }
                    FormValueRow(title: "To") {
                        Picker("To", selection: Binding(get: { prefs.quietEndMinutes }, set: { prefs.quietEndMinutes = $0 })) {
                            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) {
                                Text(NudgePreferencesStore.hhmm($0)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(AgaraColors.accent)
                    }
                }
            }

            SettingsGroup(header: "Movement") {
                FormValueRow(title: "Step reminders") {
                    Picker("Step reminders", selection: Binding(
                        get: { prefs.stepReminderHours ?? 0 },
                        set: { prefs.stepReminderHours = $0 == 0 ? nil : $0 }
                    )) {
                        Text("Off").tag(0)
                        Text("Every 2 h").tag(2)
                        Text("Every 3 h").tag(3)
                    }
                    .pickerStyle(.menu)
                    .tint(AgaraColors.accent)
                }
            }

            if let override = overrides.active() {
                SettingsGroup(header: "Today", footer: "Your normal goal comes back tomorrow.") {
                    FormValueRow(title: "Today's goal") {
                        Text("\(override.percent)% lighter")
                            .font(AgaraFont.footnote)
                            .foregroundStyle(AgaraColors.textSecondary)
                    }
                    FormValueRow(title: "Back to normal") {
                        Button("Reset") { overrides.clear() }
                            .font(AgaraFont.footnote.weight(.semibold))
                            .foregroundStyle(AgaraColors.accent)
                            .accessibilityIdentifier("nudges.goalReset")
                    }
                }
            }
        }
    }

    // MARK: - Tools

    @ViewBuilder private var tools: some View {
        SettingsGroup(
            header: "Tools",
            // The dismissal-learning rule, in one plain sentence (policy rule 9).
            footer: "If you dismiss three nudges in a topic within a week, that topic will speak up less often — a tap on any nudge resets it."
        ) {
            FormValueRow(title: "Send a test nudge") {
                Button("Send") { sendTest() }
                    .font(AgaraFont.footnote.weight(.semibold))
                    .foregroundStyle(AgaraColors.accent)
                    .accessibilityIdentifier("nudges.sendTest")
            }
            FormValueRow(title: "Clear snoozes") {
                Button("Clear") { ledger.clearSnoozes() }
                    .font(AgaraFont.footnote.weight(.semibold))
                    .foregroundStyle(AgaraColors.accent)
                    .accessibilityIdentifier("nudges.clearSnoozes")
            }
            if let testStatus {
                Text(testStatus)
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textMuted)
                    .padding(12)
            }
        }

        SettingsGroup(header: "Last 7 days") {
            if ledger.recent(days: 7).isEmpty {
                Text("No nudges yet.")
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textMuted)
                    .padding(12)
                    .accessibilityIdentifier("nudges.ledger.empty")
            } else {
                ForEach(ledger.recent(days: 7)) { entry in
                    FormValueRow(title: entry.title) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(entry.outcome.label)
                                .font(AgaraFont.caption.weight(.semibold))
                                .foregroundStyle(entry.isDismissal ? AgaraColors.textMuted : AgaraColors.accent)
                            Text(entry.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                .font(AgaraFont.caption2)
                                .foregroundStyle(AgaraColors.textMuted)
                        }
                    }
                    .accessibilityIdentifier("nudges.ledger.\(entry.rule).\(entry.outcome.rawValue)")
                }
            }
        }
    }

    // MARK: - Coach check-ins (kept from the old screen)

    @ViewBuilder private var coachCheckins: some View {
        SettingsGroup(header: "Coach check-ins") {
            FormToggleRow(title: "Daily check-in notifications", isOn: Binding(
                get: { coachStore.settings.notificationsEnabled },
                set: { setNotifications($0) }
            ))
            if coachStore.settings.notificationsEnabled {
                FormValueRow(title: "Morning") { hourPicker(hourBinding(\.morningHour)) }
                FormValueRow(title: "Evening") { hourPicker(hourBinding(\.eveningHour)) }
            }
        }
        if notifPermissionDenied {
            Text(AgaraCopy.notificationsDisabled)
                .font(AgaraFont.caption).foregroundStyle(AgaraColors.danger)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func setMaster(_ on: Bool) {
        guard on else {
            prefs.masterOn = false
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            prefs.masterOn = granted
            notifPermissionDenied = !granted
        }
    }

    /// "Send a test nudge" goes through the real push path (`AgaraNotifications.shared.post`), so it proves the category,
    /// the buttons and the permission — not just that a banner can appear.
    private func sendTest() {
        guard let nudge = feed.nudges.first ?? NudgeFixtureProvider.nudge("a1", now: Date()) else { return }
        Task {
            let posted = await AgaraNotifications.shared.post(.nudge(nudge))
            testStatus = posted
                ? "Sent \"\(nudge.title)\"."
                : "Nothing sent — allow notifications for \(AgaraCopy.appName) in iOS Settings."
        }
    }

    private func hourPicker(_ binding: Binding<Int>) -> some View {
        Picker("Hour", selection: binding) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
        .pickerStyle(.menu)
        .tint(AgaraColors.accent)
    }

    private func hourBinding(_ keyPath: WritableKeyPath<CoachSettings, Int>) -> Binding<Int> {
        Binding(
            get: { coachStore.settings[keyPath: keyPath] },
            set: { coachStore.settings[keyPath: keyPath] = $0; CoachNotificationScheduler.shared.scheduleNext() }
        )
    }

    private func setNotifications(_ on: Bool) {
        guard on else {
            coachStore.settings.notificationsEnabled = false
            CoachNotificationScheduler.shared.cancel()
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            coachStore.settings.notificationsEnabled = granted
            notifPermissionDenied = !granted
            if granted { CoachNotificationScheduler.shared.scheduleNext() }
        }
    }
}
