import Foundation

/// The shared `coach` flag (docs/config/features.yaml, parity phase 6) over the user's own master switch: the
/// coach, its FAB, cards, summaries and check-ins exist only when both are on. One place so every surface agrees.
@MainActor
enum CoachGate {
    /// The coach may appear/run: the parity flag is on and the user turned the coach on.
    static var isOn: Bool { AgaraFeatureStore.isOn(.coach) && CoachSettingsStore.shared.settings.coachMasterEnabled }
    /// Conversation history (list of past chats) — flag `coach_history`, iOS only today.
    static var historyOn: Bool { AgaraFeatureStore.isOn(.coachHistory) }

    // MARK: Agara Cloud coach

    /// The account facts the cloud coach needs (contract `docs/ring/coach-proxy.md` §4). Taken from the one cloud
    /// account the app has, so there is no second notion of "signed in".
    struct Account: Equatable, Sendable {
        var signedIn: Bool
        var emailVerified: Bool
        /// The Agara Cloud consent (`§11`, Apple 5.1.2(i)) — health context leaves the device only after it.
        var consented: Bool
    }

    /// `coach_cloud` AND the user's master switch AND the account. The server re-checks all three (§4); this is what
    /// keeps the app from sending a turn that can only fail, and what picks the provider.
    static func cloudReady(flagOn: Bool, userOn: Bool, account: Account) -> Bool {
        flagOn && userOn && account.signedIn && account.emailVerified && account.consented
    }

    /// The live account facts, from `AgaraCloud` (its `phase` already folds in the config, the consent and the stored
    /// session's `email_verified`).
    static var account: Account {
        Account(
            signedIn: AgaraCloud.shared.isSignedIn,
            emailVerified: AgaraCloud.shared.phase == .ready,
            consented: AgaraCloud.shared.hasConsent)
    }

    /// The cloud coach may run.
    static var cloudReady: Bool { cloudReady(facts: .live) }

    /// Everything the gate reads, as one value: injectable so the routing table can be tested for every combination
    /// without a Keychain, a signed-in account or the Firebase network.
    struct Facts: Equatable, Sendable {
        var flagOn: Bool
        var userOn: Bool
        var account: Account

        var isReady: Bool { cloudReady(flagOn: flagOn, userOn: userOn, account: account) }

        static var live: Facts {
            Facts(flagOn: AgaraFeatureStore.isOn(.coachCloud),
                  userOn: CoachSettingsStore.shared.settings.coachMasterEnabled,
                  account: CoachGate.account)
        }
    }

    static func cloudReady(facts: Facts) -> Bool {
        cloudReady(flagOn: facts.flagOn, userOn: facts.userOn, account: facts.account)
    }
}

/// Resolves "can the real coach run, and which tool classes are allowed" from
/// the user's settings plus whether a key is actually present. Mirrors the web
/// app's `settings.coach_enabled` gate, extended with per-class tool toggles.
struct CoachFeatureFlags {
    let settings: CoachSettings
    let hasAPIKey: Bool
    /// Snapshot of the nutrition feature's prefs, bridged in so tool/context gating
    /// composes with the coach gates. Defaulted so existing construction sites and
    /// tests keep compiling (default = feature off).
    var nutritionPrefs: NutritionPrefs = .default
    /// Overrides the live `CoachGate.cloudReady` for tests and previews. Nil (the default) means "ask the gate", so
    /// every existing construction site keeps working; a snapshot value lets a test prove the cloud coach's rules
    /// without an account, a Keychain or the network.
    var cloudReadyOverride: Bool? = nil

    /// User-facing master switch — when off, the coach tab, summaries and
    /// notifications are all hidden. This is the gate the UI checks; the
    /// `coachEnabled` flag below additionally factors in provider/key state.
    var masterEnabled: Bool { settings.coachMasterEnabled }

    /// The provider mode a turn actually runs in (see `CoachClientResolver.effectiveMode`): in a release build a
    /// stored bring-your-own-key mode resolves to the Agara cloud coach or to on-device, and the cloud coach needs
    /// its gate. Both this and the resolver read the same rule, so the status line cannot disagree with the turn.
    var providerMode: CoachProviderMode {
        CoachClientResolver.effectiveMode(for: settings.providerMode,
                                         cloudReady: cloudReadyOverride ?? CoachGate.cloudReady)
    }

    /// True when the real (LLM-backed) coach should run. Otherwise the
    /// orchestrator falls back to a deterministic scripted response.
    var coachEnabled: Bool {
        guard settings.coachMasterEnabled else { return false }
        switch providerMode {
        case .offlineStub:
            return false
        case .appleOnDevice:
            // On-device only — ready when the local model is usable on this
            // device. Otherwise the coach degrades to scripted and on-device
            // failures surface as an error in chat.
            return AppleOnDeviceAvailability.current.isAvailable
        case .agaraCloud:
            // `hasAPIKey` carries the cloud gate's sentinel (non-nil only when the account may spend a turn).
            return hasAPIKey
        case .userOpenAIKey, .userGeminiKey, .userOpenRouterKey, .userMiniMaxKey:
            return hasAPIKey
        case .localOpenAICompat:
            // `hasAPIKey` carries the local provider's readiness sentinel, which is a *usable base
            // URL* rather than a key — the key is optional on every engine in scope.
            return hasAPIKey
        case .backendProxy:
            return false  // not implemented in v1
        }
    }

    var webSearchEnabled: Bool { settings.enableWebSearch }
    var writeToolsEnabled: Bool { settings.enableWriteTools }
    var liveMeasurementsEnabled: Bool { settings.enableLiveMeasurements }
    /// The Agara Cloud coach never receives an image (§5 of the proxy contract: the payload is trimmed to numbers),
    /// so the camera is not offered for it even if the stored toggle is on. Always keyed off the *effective* provider
    /// mode: when the gate is closed a release build is running the on-device model, where images ARE allowed.
    var imageInputEnabled: Bool { settings.enableImageInput && providerMode != .agaraCloud }

    /// Nutrition data may reach the coach (context packet + read tools): the feature is on
    /// AND the user shares it with the coach.
    var nutritionContextEnabled: Bool { nutritionPrefs.masterEnabled && nutritionPrefs.shareWithCoach }
    /// The coach may log/edit meals: nutrition context is shared AND write tools are on.
    var nutritionWriteEnabled: Bool { nutritionContextEnabled && writeToolsEnabled }

    var maxToolCalls: Int { max(1, settings.maxToolCalls) }
    var maxRounds: Int { max(1, settings.maxRounds) }
    var model: String { settings.model }

    /// The model string actually sent for the active provider — the single place
    /// that resolves the per-provider naming (OpenRouter/MiniMax read their own
    /// slug fields; on-device has no external model name). Used to label and price
    /// a turn's usage. Mirrors `CoachClientResolver`'s per-provider `model` choice.
    var effectiveModel: String {
        switch providerMode {
        case .appleOnDevice: return "apple-on-device"
        case .offlineStub: return "offline-stub"
        // The cloud coach's model is server configuration (contract decision 1): the app must not know or name it,
        // so switching provider never needs a release.
        case .agaraCloud: return "agara-cloud"
        case .userOpenRouterKey: return settings.openRouterModel
        case .userMiniMaxKey: return settings.minimaxModel
        // Blank is legitimate: llama.cpp ignores the field unless started with --alias. Label it
        // rather than leave the usage row empty.
        case .localOpenAICompat:
            return settings.resolvedLocalModel.isEmpty ? "local-model" : settings.resolvedLocalModel
        case .userOpenAIKey, .userGeminiKey, .backendProxy: return settings.model
        }
    }

    /// One-line status for the Settings UI.
    var statusLine: String {
        if !settings.coachMasterEnabled { return "Off — turn on AI Coach to enable." }
        switch providerMode {
        case .offlineStub:
            return "Offline — scripted replies only."
        case .appleOnDevice:
            return AppleOnDeviceAvailability.current.statusMessage
        case .agaraCloud:
            return hasAPIKey ? "Ready · Agara Cloud" : "Sign in with a verified e-mail to use the Agara Cloud coach."
        case .userOpenAIKey:
            return hasAPIKey ? "Ready · \(settings.model)" : "Add an OpenAI key to enable."
        case .userGeminiKey:
            return hasAPIKey ? "Ready · \(settings.model)" : "Add a Gemini key to enable."
        case .userOpenRouterKey:
            return hasAPIKey ? "Ready · \(settings.openRouterModel)" : "Add an OpenRouter key to enable."
        case .userMiniMaxKey:
            return hasAPIKey ? "Ready · \(settings.minimaxModel)" : "Add a MiniMax key to enable."
        case .localOpenAICompat:
            guard hasAPIKey else { return "Add your server's address to enable." }
            let model = settings.resolvedLocalModel
            return model.isEmpty ? "Ready · self-hosted" : "Ready · \(model)"
        case .backendProxy:
            return "Backend proxy not available yet."
        }
    }
}
