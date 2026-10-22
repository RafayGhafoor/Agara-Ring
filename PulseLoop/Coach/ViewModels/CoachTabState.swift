import Foundation

/// The Coach tab's one state. Every surface of the tab (the composer, the cards, the header pill) renders from this
/// enum, so "can the coach answer right now, and if not why" is decided in one place instead of guessed in a view.
///
/// The cloud coach can only answer when all of these hold (`docs/ring/coach-proxy.md` §4, §9, §11): the account is
/// signed in, its email is verified, the user agreed to the third-party disclosure, no turn is already running, and
/// today's quota is not used up. The on-device coach needs none of it — the user's own phone is the provider — which
/// is why every blocked cloud state offers it.
enum CoachTabState: Equatable {
    /// The `coach` flag or the user's master switch is off: nothing to ask.
    case coachOff
    /// Cloud coach selected, no account: sign in.
    case signedOut
    /// Signed in, email unverified — no grace window for a paid turn.
    case emailUnverified
    /// Signed in and verified, but the third-party disclosure has not been agreed to.
    case consentRequired
    /// A turn is already running for this account.
    case busy
    /// Today's (or this month's) cloud questions are used up; `resetsAt` is when they come back, when known.
    case outOfQuota(resetsAt: Date?)
    /// The coach may answer.
    case ready

    /// The screen this state shows, for the UI test and the accessibility identifier (`coach.state.<id>`).
    var id: String {
        switch self {
        case .coachOff: return "off"
        case .signedOut: return "signedOut"
        case .emailUnverified: return "unverified"
        case .consentRequired: return "consent"
        case .busy: return "busy"
        case .outOfQuota: return "quota"
        case .ready: return "ready"
        }
    }

    /// The card's headline (`.ready` has no card).
    var title: String {
        switch self {
        case .coachOff: return CoachCopy.offTitle
        case .signedOut: return CoachCopy.signedOutTitle
        case .emailUnverified: return CoachCopy.unverifiedTitle
        case .consentRequired: return CoachCopy.consentTitle
        case .busy: return CoachCopy.busyTitle
        case .outOfQuota: return CoachCopy.quotaTitle
        case .ready: return ""
        }
    }

    /// The card's explaining sentence. `quotaBody` needs the formatted reset time, so the quota sentence is built by
    /// `CoachQuotaStore` and passed in.
    func body(quotaBody: String = CoachCopy.quotaUnknownReset) -> String {
        switch self {
        case .coachOff: return CoachCopy.offBody
        case .signedOut: return CoachCopy.signedOutBody
        case .emailUnverified: return CoachCopy.unverifiedBody
        case .consentRequired: return CoachCopy.consentBody
        case .busy: return CoachCopy.busyBody
        case .outOfQuota: return quotaBody
        case .ready: return ""
        }
    }

    /// Only the cloud states can offer "use the on-device coach": it is exactly the ones that block a cloud turn.
    var offersOnDevice: Bool {
        switch self {
        case .signedOut, .emailUnverified, .consentRequired, .outOfQuota: return true
        case .coachOff, .busy, .ready: return false
        }
    }
}

/// Everything the state is resolved from — plain values so the decision is pure and unit-testable without a simulator.
struct CoachTabStateInput: Equatable {
    /// The shared `coach` feature flag.
    var coachFlagOn: Bool
    /// The user's own switch (Settings › AI Coach › Enable AI Coach).
    var masterEnabled: Bool
    /// Cloud coach in use: the `coach_cloud` flag is on *and* the provider is set to it. Otherwise the on-device /
    /// bring-your-own-key path answers, and no account, consent or quota applies.
    var cloudInUse: Bool
    /// The account, as `AgaraCloud.phase` reports it.
    var account: CoachAccountState = .signedOut
    /// The third-party disclosure for the cloud coach is on record (`CoachConsentStore`).
    var consentGiven: Bool = false
    /// A turn is running for this account.
    var busy: Bool = false
    /// Cloud questions left today, from `X-Coach-Remaining-Day`; nil until the first response of the day.
    var remainingTurnsToday: Int? = nil
    /// When today's quota resets, from `X-Coach-Day-Resets-At`.
    var dayResetsAt: Date? = nil
}

/// The slice of the account the coach cares about, kept independent of `AgaraCloud` so the resolver is pure.
enum CoachAccountState: Equatable {
    /// No session: nobody to attribute a paid turn to.
    case signedOut
    /// A session whose email is unverified — the server answers `403 email_not_verified`.
    case unverified
    /// A verified session.
    case verified
}

extension CoachTabStateInput {
    /// The live input: the shared feature flags and user switch, the account, the disclosure record and the quota the
    /// cloud client last reported. One place assembles it, so the tab and Settings › AI Coach can never disagree about
    /// whether the coach can answer.
    @MainActor
    static func current() -> CoachTabStateInput {
        let settings = CoachSettingsStore.shared.settings
        let cloud = AgaraCloud.shared
        return CoachTabStateInput(
            coachFlagOn: AgaraFeatureStore.isOn(.coach),
            masterEnabled: settings.coachMasterEnabled,
            // The cloud is selected (`agaraCloud` — the Release default — or the debug `backendProxy`) AND an account
            // exists: then the account and the AI disclosure gate the tab, so a missing consent shows the consent card
            // instead of being skipped. No account → the on-device coach answers (the coach is not behind sign-in).
            // Until 2026-10-22 this read `== .backendProxy` only, so no Release user ever saw the consent step.
            cloudInUse: cloudInUse(flagOn: AgaraFeatureStore.isOn(.coachCloud), provider: settings.providerMode,
                                   signedIn: cloud.isSignedIn),
            account: {
                switch cloud.phase {
                case .ready: return .verified
                case .needsVerification: return .unverified
                case .signedOut, .needsConsent, .notConfigured: return .signedOut
                }
            }(),
            consentGiven: CoachConsentStore.shared.hasConsent,
            busy: CoachQuotaStore.shared.isTurnInFlight,
            remainingTurnsToday: CoachQuotaStore.shared.remainingTurnsToday,
            dayResetsAt: CoachQuotaStore.shared.dayResetsAt
        )
    }

    /// Pure, so every combination is tested (`CoachConsentGateTests`).
    nonisolated static func cloudInUse(flagOn: Bool, provider: CoachProviderMode, signedIn: Bool) -> Bool {
        flagOn && [.agaraCloud, .backendProxy].contains(provider) && signedIn
    }

    /// The state the app should show right now (debug builds honour `-coachState`).
    @MainActor
    static func currentState() -> CoachTabState {
        #if DEBUG
        if let forced = CoachTabState.debugOverride() { return forced }
        #endif
        return CoachTabState.resolve(current())
    }
}

extension CoachTabState {
    /// Resolve the tab's state. Precedence is the server's own order (coach-proxy.md §4): the kill switch and the
    /// user's switch first, then authentication, then the disclosure, then the transient limits. Quota comes last
    /// because it is the only one the user waits out rather than fixes.
    static func resolve(_ input: CoachTabStateInput) -> CoachTabState {
        guard input.coachFlagOn, input.masterEnabled else { return .coachOff }
        guard input.cloudInUse else { return .ready }
        switch input.account {
        case .signedOut: return .signedOut
        case .unverified: return .emailUnverified
        case .verified: break
        }
        guard input.consentGiven else { return .consentRequired }
        if input.busy { return .busy }
        if let remaining = input.remainingTurnsToday, remaining <= 0 {
            return .outOfQuota(resetsAt: input.dayResetsAt)
        }
        return .ready
    }
}

#if DEBUG
extension CoachTabState {
    /// `-coachState <name>` — the debug launch argument that makes every state reachable in the UI test, since the
    /// real ones need a signed-in account, a used-up quota and a running turn. Debug builds only, like every other
    /// `DebugLaunch` hook.
    static func debugOverride() -> CoachTabState? {
        guard let raw = DebugLaunch.string("coachState")?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return nil
        }
        switch raw {
        case "off", "coachoff": return .coachOff
        case "signedout": return .signedOut
        case "unverified", "emailunverified": return .emailUnverified
        case "consent", "consentrequired": return .consentRequired
        case "busy": return .busy
        case "quota", "outofquota": return .outOfQuota(resetsAt: CoachQuotaStore.shared.dayResetsAt)
        case "ready": return .ready
        default: return nil
        }
    }
}
#endif
