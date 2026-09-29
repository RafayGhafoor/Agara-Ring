import SwiftUI
import SwiftData
import UIKit

/// Settings › Privacy (consistency framework phase 5: privacy only — export/import, diagnostics and demo data
/// moved to `DataExportSettingsView`). Says where the data lives and offers the destructive resets, each asked
/// first through `ConfirmAction`: unpair the ring, factory-reset app data, or both.
struct PrivacySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @State private var sampleData = SampleDataStore.shared
    @State private var cloud = AgaraCloud.shared
    /// The destructive action awaiting confirmation — `ConfirmAction`.
    @State private var confirm: ConfirmAction?

    /// Copy from brand.yaml (both apps): unpair = Forget; both resets use the reset-app-data copy.
    private func ask(_ action: ResetAction) {
        switch action {
        case .deleteAll: confirm = .deleteAllData(cloudSignedIn: cloud.isSignedIn) { perform(action) }
        case .unpairRing: confirm = .forgetRing { perform(action) }
        case .resetAppData, .unpairAndReset: confirm = .resetAppData(confirmLabel: action.confirmLabel) { perform(action) }
        }
    }

    private enum ResetAction: Identifiable {
        case unpairRing
        case resetAppData
        case unpairAndReset
        /// Delete all my data: unpair, then a complete local wipe (`AppDataWipe`).
        case deleteAll

        var id: Int { hashValue }

        var title: String {
            switch self {
            case .unpairRing:     return "Unpair ring?"
            case .resetAppData:   return "Reset app data?"
            case .unpairAndReset: return "Unpair ring & reset app data?"
            case .deleteAll:      return AgaraCopy.deleteAllDataTitle
            }
        }

        var message: String {
            switch self {
            case .unpairRing:
                return "Unpair your ring? The ring will forget this phone; your data stays."
            case .resetAppData:
                return "This permanently erases all your data — metrics, sleep, activity, coach history, settings, and saved API keys — and can't be undone."
            case .unpairAndReset:
                return "This unpairs your ring, then permanently erases all your data — metrics, sleep, activity, coach history, settings, and saved API keys — and can't be undone."
            case .deleteAll:
                return AgaraCopy.deleteAllDataBody
            }
        }

        /// Destructive-button label inside the confirmation dialog.
        var confirmLabel: String {
            switch self {
            case .unpairRing:     return "Unpair ring"
            case .resetAppData:   return "Reset app data"
            case .unpairAndReset: return "Unpair & reset"
            case .deleteAll:      return "Delete everything"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    header: "Your data",
                    footer: "Health data syncs from your ring straight to this phone and is stored only here. "
                        + "Nothing is uploaded unless you turn on a connection yourself (Apple Health, cloud backup). "
                        + "Export or import a copy in Data & Export."
                        + (cloud.isSignedIn ? "\n\n" + AgaraCloudCopy.privacyFooterSignedIn : "")
                ) {
                    FormValueRow(title: "Stored") {
                        Text(cloud.isSignedIn ? AgaraCloudCopy.privacyStoredSignedIn : "On this phone").foregroundStyle(AgaraColors.textMuted)
                    }
                }
                if sampleData.isActive {
                    SettingsGroup(
                        header: "Sample data",
                        footer: "You're exploring with sample data. Pairing your ring removes it automatically; you can also clear it now."
                    ) {
                        actionRow("Clear sample data", systemImage: "trash", tint: AgaraColors.danger) {
                            confirm = .clearDemo { sampleData.clear(context: modelContext) }
                        }
                        .accessibilityIdentifier("privacy.clearSample")
                    }
                }
                SettingsGroup(
                    header: "App data",
                    footer: "Unpair releases the ring for other apps and keeps your health data. Resetting erases everything on this device and returns the app to onboarding."
                ) {
                    actionRow("Unpair ring", systemImage: "wave.3.right.circle", tint: AgaraColors.danger) {
                        ask(ResetAction.unpairRing)
                    }
                    actionRow("Reset app data", systemImage: "trash", tint: AgaraColors.danger) {
                        ask(ResetAction.resetAppData)
                    }
                    actionRow("Unpair ring & reset app data", systemImage: "trash.slash", tint: AgaraColors.danger) {
                        ask(ResetAction.unpairAndReset)
                    }
                }
                SettingsGroup(
                    header: "Delete my data",
                    footer: "Removes everything Agara Ring stores on this phone, including sign-ins and keys, and unpairs your ring. Data already in Apple Health stays there."
                ) {
                    actionRow("Delete all my data", systemImage: "trash.fill", tint: AgaraColors.danger) {
                        ask(ResetAction.deleteAll)
                    }
                    .accessibilityIdentifier("privacy.deleteAll")
                }
                LegalSettingsGroup()

            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Privacy")
        .confirmAction($confirm)
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        tint: Color = AgaraColors.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(AgaraFont.body)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(AgaraFont.body)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reset actions

    private func perform(_ action: ResetAction) {
        switch action {
        case .unpairRing:
            ble.forget()
        case .resetAppData:
            resetAppData()
        case .unpairAndReset:
            // Unbind the ring FIRST so the UNBOND write goes out before the store is wiped.
            ble.forget()
            resetAppData()
        case .deleteAll:
            ble.forget()   // same order: the ring is told before the store goes
            AppDataWipe.eraseEverything(context: modelContext)
        }
    }

    /// Factory reset: wipe SwiftData, the coach API keys in Keychain, and all UserDefaults, then reset the
    /// in-memory shared settings singletons so the wipe reflects without a relaunch. Clearing every
    /// `UserProfile` makes RootViews' `profiles` @Query empty, so it switches back to onboarding on its own.
    private func resetAppData() {
        // 1. All SwiftData model types (this removes UserProfile → RootViews returns to onboarding).
        SeedData.clearAll(modelContext)

        // 2. Coach API keys and Strava OAuth tokens from the Keychain (survive UserDefaults wipe,
        //    so delete explicitly).
        try? OpenAIKeychainStore().deleteKey()
        try? GeminiKeychainStore().deleteKey()
        try? OpenRouterKeychainStore().deleteKey()
        try? MiniMaxKeychainStore().deleteKey()
        try? StravaKeychainTokenStore().delete()

        // 3. Wipe UserDefaults (metric prefs, coach settings, calibration, remembered ring, flags, …).
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // 4. Reset the in-memory shared settings singletons so the cleared state shows immediately
        //    (they cache their `settings` in memory; reassigning to `.default` re-persists the fresh
        //    defaults into the now-empty UserDefaults too).
        MetricPrefsStore.shared.settings = .default
        CoachSettingsStore.shared.settings = .default
        CalibrationStore.shared.settings = .default
        StravaPrefsStore.shared.resetAll()

        // 5. RootViews reacts to the emptied `profiles` @Query and swaps MainTabView → OnboardingFlowView,
        //    tearing down this pushed page automatically — no manual navigation needed. In DEBUG the
        //    `forceOnboarding` flag also gates onboarding, so re-arm it after the domain wipe cleared it.
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "forceOnboarding")
        #endif
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Minimal UIKit share-sheet wrapper for exporting the diagnostics file.
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
