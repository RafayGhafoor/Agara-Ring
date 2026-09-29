import Foundation
import SwiftData
import UserNotifications

/// "Delete all my data" (store launch, phase 1 item 4; Apple 5.1.1(v), Play data-deletion policy): a complete local
/// wipe. Unlike the older Privacy › Reset it also removes every sign-in and API key (cloud session, AI keys, Strava
/// tokens), the widget snapshot, scheduled notifications, the sample-data flag and the disclaimer acknowledgement —
/// the app returns to a first-launch state. Data already written to Apple Health stays there (the confirmation says so).
@MainActor
enum AppDataWipe {
    /// Wipe the store and every local secret / preference. The caller unpairs the ring first (`RingBLEClient.forget()`).
    static func eraseEverything(context: ModelContext) {
        // 1. Every SwiftData table, including the profile (RootViews' `profiles` @Query empties -> onboarding).
        SeedData.clearAll(context)

        // 2. Keychain: every AI key, the Strava tokens and the Agara Cloud session. They survive a UserDefaults wipe.
        try? OpenAIKeychainStore().deleteKey()
        try? GeminiKeychainStore().deleteKey()
        try? OpenRouterKeychainStore().deleteKey()
        try? MiniMaxKeychainStore().deleteKey()
        try? LocalLLMKeychainStore().deleteKey()
        try? StravaKeychainTokenStore().delete()
        AgaraCloud.shared.wipeLocalAccount()

        // 3. Widget snapshot (App Group container) and its shared defaults.
        if let url = AgaraWidgetStore.fileURL { try? FileManager.default.removeItem(at: url) }
        UserDefaults(suiteName: AgaraWidgetStore.suite)?.removePersistentDomain(forName: AgaraWidgetStore.suite)

        // 4. Scheduled and delivered notifications.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        // 5. All app preferences.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // 6. In-memory singletons cache their settings; reassigning re-persists fresh defaults into the emptied domain.
        SensorIdentity.shared.reset()
        MetricPrefsStore.shared.settings = .default
        CoachSettingsStore.shared.settings = .default
        CalibrationStore.shared.settings = .default
        StravaPrefsStore.shared.resetAll()
        SampleDataStore.shared.resetInMemory()

        // 7. In DEBUG the `forceOnboarding` flag also gates onboarding, so re-arm it after the domain wipe cleared it.
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "forceOnboarding")
        #endif
    }
}
