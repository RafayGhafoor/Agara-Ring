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
    @State private var nav = CoachNavigation.shared
    @State private var cloud = AgaraCloud.shared
    /// One-time (per install) in-app notice for users whose coach runs on this phone: the cloud is the advanced coach.
    @AppStorage("coach.cloudUpsell.dismissed") private var cloudUpsellDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if CoachCloudUpsell.shouldShow(state: state, usesCloud: usesCloud, dismissed: cloudUpsellDismissed) {
                cloudUpsell
            }
            // Nudges are behind the bell in the header now; the Coach tab is the chat.
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
        // The page colour behind everything the tab draws, the "For you" nudge included (it sat on the system's white).
        .background(AgaraColors.background)
        // The header's "tap to agree" line (CoachHeaderTitle) asks for the same sheet as the card's button.
        .onChange(of: nav.consentRequests) { _, _ in showConsent = true }
        .sheet(isPresented: $showConsent) {
            CoachConsentSheet()
                // The sheet's agree button records the consent and closes the sheet; the body then re-resolves to
                // `.ready` on its own, because it reads the store.
                .presentationDragIndicator(.visible)
                .agaraRingEnvironment()   // every presentation root (AgaraRingEnvironment, the 1.0.0 (1) crash)
        }
    }

    /// The in-app notice for an on-device user: the cloud coach has the baselines, trends and readiness the on-device
    /// model cannot see. Sign in (or switch the provider, if already signed in) from the one button; dismiss is permanent
    /// for this install so it never nags.
    private var cloudUpsell: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Get deeper answers with Agara Cloud")
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                Text("28-day baselines, trends and readiness. Sign in to use the advanced coach.")
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(cloud.isSignedIn ? "Switch" : "Sign in") {
                onOpenRoute(cloud.isSignedIn ? .settingsCoach : .settingsCloud)
            }
            .font(AgaraFont.caption.weight(.semibold))
            .foregroundStyle(AgaraColors.onAccent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(AgaraColors.accent))
            .accessibilityIdentifier("coach.cloudUpsell.signIn")
            Button {
                cloudUpsellDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(AgaraFont.caption2.weight(.bold))
                    .foregroundStyle(AgaraColors.textMuted)
                    .padding(6)
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("coach.cloudUpsell.dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AgaraColors.card)
        .overlay(alignment: .bottom) { Rectangle().fill(AgaraColors.borderSubtle).frame(height: 1) }
        .accessibilityIdentifier("coach.cloudUpsell")
    }

    // MARK: - State

    /// The tab's state: forced in a debug build when the UI test asks for one (`-coachState`), otherwise resolved from
    /// the switches, the account, the consent record and the quota the cloud client last reported.
    private var state: CoachTabState { CoachTabStateInput.currentState() }

    /// The provider that actually answers (a stored cloud choice that is not ready answers on the phone).
    private var usesCloud: Bool {
        _ = cloud.phase
        return CoachClientResolver.effectiveMode(for: settingsStore.settings.providerMode,
                                                cloudReady: CoachGate.cloudReady) == .agaraCloud
    }

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
        settingsStore.settings.providerChosen = true
        if !settingsStore.settings.coachMasterEnabled { settingsStore.settings.coachMasterEnabled = true }
    }
}

// MARK: - The Coach tab's header content

/// What the app header says on the Coach tab, in the space the other tabs give the greeting: a short status line —
/// where the answers come from, and the cloud quota — over the title. Same two lines as the greeting, so switching tabs
/// does not move anything; but on this tab both lines carry information.
///
/// It replaced a second header that the coach drew under the app's (orb, name, a two-line privacy sentence and a row
/// of buttons). The privacy promise is still one tap away: the status line opens Usage and privacy, and its VoiceOver
/// label is the full sentence.
struct CoachHeaderTitle: View {
    @State private var settingsStore = CoachSettingsStore.shared
    @State private var quota = CoachQuotaStore.shared
    @State private var cloud = AgaraCloud.shared
    @State private var nav = CoachNavigation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if CoachTabStateInput.currentState() == .consentRequired {
                // The consent was skipped (an update, a dismissed sheet): the line itself is the way to give it.
                Button { nav.requestConsent() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(AgaraColors.accent).frame(width: 6, height: 6)
                        Text(CoachCopy.headerStatusConsent)
                            .font(AgaraFont.footnote.weight(.semibold))
                            .foregroundStyle(AgaraColors.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("coach.consentLine")
                .accessibilityHint(CoachCopy.headerConsentHint)
            } else if CoachTabStateInput.currentState() == .ready {
                Button { nav.requestUsage() } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(usesCloud ? AgaraColors.accent : AgaraColors.success)
                            .frame(width: 6, height: 6)
                        Text(statusLine)
                            .font(AgaraFont.footnote)
                            .foregroundStyle(AgaraColors.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(quotaText == nil ? "coach.promise" : "coach.quota")
                .accessibilityLabel(spokenLine)
                .accessibilityHint(CoachCopy.headerStatusHint)
            }
            Text(CoachCopy.tabTitle)
                .font(AgaraFont.title2.weight(.semibold))
                .foregroundStyle(AgaraColors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
        // The row is full on this tab (history, new chat, bell, ring, gear): the title column wins the width and the
        // status line truncates — Jimmy's 1.1.0 (3) showed "● (" over a lone "C" (2026-10-22).
        .layoutPriority(1)
    }

    /// The effective provider, not the stored one: a stored cloud choice that is not ready yet answers on the phone,
    /// and the line must say so (the header once told a cloud user "nothing is sent").
    private var usesCloud: Bool {
        _ = cloud.phase
        return CoachClientResolver.effectiveMode(for: settingsStore.settings.providerMode,
                                                cloudReady: CoachGate.cloudReady) == .agaraCloud
    }

    /// The cloud's quota, shown only while the cloud is what answers: "On this phone · 24 left" mixed the on-device
    /// coach with a count that does not apply to it (seen when the cloud choice was stored but not ready).
    /// Owner 2026-10-23: the header no longer shows how many questions are left ("Agara Cloud · 13 left" while the cost cap
    /// had already stopped the next one read as a bug, and the number invites rationing). The count still drives the
    /// out-of-questions card (`CoachTabState`); only the header text is gone.
    private var quotaText: String? { nil }

    private var statusLine: String {
        let base = usesCloud ? CoachCopy.headerStatusCloud : CoachCopy.headerStatusOnDevice
        return quotaText.map { "\(base) · \($0)" } ?? base
    }

    private var spokenLine: String {
        let base = usesCloud ? CoachCopy.headerCloudSubtitle : CoachCopy.headerOnDeviceSubtitle
        guard let spoken = quota.pillSpokenText, quotaText != nil else { return base }
        return "\(base). \(spoken)"
    }
}

/// The coach's two thread actions, in the app header's control row beside the ring and the gear. Plain glyphs at the
/// gear's size and weight: they are peers of the gear, so they look like it. Glass circles here made five controls
/// compete in one row.
struct CoachHeaderActions: View {
    @State private var nav = CoachNavigation.shared

    var body: some View {
        if CoachTabStateInput.currentState() == .ready {
            HStack(spacing: 0) {
                if CoachGate.historyOn {
                    glyph("clock.arrow.circlepath") { nav.requestHistory() }
                        .accessibilityLabel(CoachCopy.historyButton)
                        .accessibilityIdentifier("coach.history")
                }
                glyph("square.and.pencil") { nav.requestNewChat() }
                    .accessibilityLabel("New conversation")
            }
        }
    }

    private func glyph(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(AgaraFont.body.weight(.regular))
                .foregroundStyle(AgaraColors.textSecondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The on-device → cloud notice shows only when the coach is answering, the provider is on-device, and the user has not
/// dismissed it. Pure so a unit test pins the rule.
enum CoachCloudUpsell {
    static func shouldShow(state: CoachTabState, usesCloud: Bool, dismissed: Bool) -> Bool {
        state == .ready && !usesCloud && !dismissed
    }
}
