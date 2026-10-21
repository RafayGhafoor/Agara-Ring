import SwiftUI
import SwiftData

/// The Coach tab. One decision up front — `CoachTabState` — and then the screen that state deserves: the chat when the
/// coach can answer, one explanatory card when it cannot, and the disclosure sheet when the third-party consent is the
/// only thing missing.
///
/// Why a tab and not a sheet (the 1.0 arrangement): the coach is one of the app's five main things, and a sheet hid it
/// behind a floating button that also shadowed the tab bar. The tab bar holds Today, Vitals, Activity, Sleep and Coach;
/// Settings moved to the gear at the top of the screen.
struct CoachTabView: View {
    /// Push a Settings screen (the Agara Cloud account, the coach's own settings) from inside the tab.
    var onOpenRoute: (AppRoute) -> Void = { _ in }
    /// Called when a workout card in the chat is tapped.
    var onOpenWorkout: ((UUID) -> Void)?
    /// Called when a meal card in the chat is tapped.
    var onOpenMeal: ((UUID) -> Void)?

    @State private var settingsStore = CoachSettingsStore.shared
    @State private var quotaStore = CoachQuotaStore.shared
    @State private var showConsent = false

    var body: some View {
        VStack(spacing: 0) {
            // Proactive nudges at the top of the Coach tab (policy rule 10: notifications off still means the nudges
            // appear here). Same card view as Today, compact, and only while the nudge feature is on.
            if AgaraFeatureStore.isOn(.coachNudges) {
                // No wrapper ScrollView: it reserved up to 250 pt of empty space whenever the list had nothing to show
                // (which is most of the time — the list is empty until a rule fires).
                NudgeForYouList()
            }
            Group {
                if state == .ready {
                    CoachView(onOpenWorkout: onOpenWorkout, onOpenMeal: onOpenMeal)
                } else {
                    CoachStateCard(
                        state: state,
                        quotaBody: quotaStore.quotaBody,
                        primary: primaryAction(for: state),
                        secondary: secondaryAction(for: state)
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state)
        }
        .sheet(isPresented: $showConsent) {
            CoachConsentSheet()
                // The sheet's agree button records the consent and closes the sheet; the body then re-resolves to
                // `.ready` on its own, because it reads the store.
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - State

    /// The tab's state: forced in a debug build when the UI test asks for one (`-coachState`), otherwise resolved from
    /// the switches, the account, the consent record and the quota the cloud client last reported.
    private var state: CoachTabState { CoachTabStateInput.currentState() }

    // MARK: - The card's two actions

    private func primaryAction(for state: CoachTabState) -> (title: String, action: () -> Void)? {
        switch state {
        case .coachOff:
            return (CoachCopy.offEnable, { settingsStore.settings.coachMasterEnabled = true })
        case .signedOut:
            return (CoachCopy.signIn, { onOpenRoute(.settingsCloud) })
        case .emailUnverified:
            return (CoachCopy.openAccount, { onOpenRoute(.settingsCloud) })
        case .consentRequired:
            return (CoachCopy.consentReview, { showConsent = true })
        case .busy:
            // Without a cloud client the only retry that exists is dropping our own lock; the next turn then asks the
            // server again and gets either an answer or another `409 coach_busy`.
            return (CoachCopy.busyRetry, { quotaStore.setTurnInFlight(false) })
        case .outOfQuota:
            return (CoachCopy.useOnDevice, { useOnDeviceCoach() })
        case .ready:
            return nil
        }
    }

    private func secondaryAction(for state: CoachTabState) -> (title: String, action: () -> Void)? {
        switch state {
        case .coachOff:
            return (CoachCopy.openSettings, { onOpenRoute(.settingsCoach) })
        case .signedOut, .emailUnverified, .consentRequired:
            return (CoachCopy.useOnDevice, { useOnDeviceCoach() })
        case .outOfQuota:
            return (CoachCopy.openSettings, { onOpenRoute(.settingsCoach) })
        case .busy, .ready:
            return nil
        }
    }

    /// The free way out of every blocked cloud state: the on-device model needs no account, no consent and no quota,
    /// and it is the same switch as Settings › AI Coach › Provider.
    private func useOnDeviceCoach() {
        settingsStore.settings.providerMode = .appleOnDevice
        if !settingsStore.settings.coachMasterEnabled { settingsStore.settings.coachMasterEnabled = true }
    }
}
