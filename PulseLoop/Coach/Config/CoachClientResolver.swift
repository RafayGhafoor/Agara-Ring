import Foundation

/// What this build offers as coach providers. A value rather than an `#if` at each use site, so the routing table can
/// be tested for both builds (contract `docs/ring/coach-proxy.md` decision 4: release = Agara Cloud + on-device;
/// bring-your-own-key is debug only).
nonisolated enum CoachBuildChannel: Sendable {
    case release
    case debug

    static var current: CoachBuildChannel {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }

    /// The providers the Settings picker offers. Everything is a valid **stored** value in both builds (an install can
    /// be updated from either), but only these can be chosen.
    var offeredModes: [CoachProviderMode] {
        switch self {
        case .release: return [.agaraCloud, .appleOnDevice]
        case .debug: return CoachProviderMode.allCases
        }
    }
}

/// The Agara Cloud coach's readiness and how to build its client. Injectable so the routing tests never touch the
/// Keychain, a real account or the network.
@MainActor
struct CoachCloudWiring {
    /// `CoachGate.cloudReady` for the signed-in/verified/consent/flags combination in play.
    var isReady: Bool
    var makeClient: () -> ResponsesClient

    static var live: CoachCloudWiring {
        CoachCloudWiring(isReady: CoachGate.cloudReady, makeClient: {
            AgaraCoachProxyClient(config: .current, auth: AgaraCloud.shared.auth)
        })
    }

    /// Not ready, and building a client is a bug (the routing never asks for one).
    static let unavailable = CoachCloudWiring(isReady: false, makeClient: { AppleFoundationModelsClient() })
}

/// Single source of truth for "which `ResponsesClient` runs, given the user's
/// settings + stored keys." Shared by the chat view-model, the summary service,
/// and the notification service so provider logic lives in exactly one place.
///
/// The returned `key` is a readiness sentinel: non-`nil` means the provider can
/// run (used to build `CoachFeatureFlags.hasAPIKey`). For cloud providers it's
/// the actual key; for on-device it's a `"on-device"` placeholder; for the Agara
/// cloud coach it's `"agara-cloud"` when the gate passed.
@MainActor
enum CoachClientResolver {
    static func resolve(
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        minimaxKeyStore: APIKeyStore,
        // Defaulted so the four existing call sites don't each have to learn about a provider
        // whose key is optional anyway.
        localKeyStore: APIKeyStore = LocalLLMKeychainStore(),
        openAIClientFactory: (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) },
        channel: CoachBuildChannel = .current,
        cloud: CoachCloudWiring? = nil
    ) -> (key: String?, client: ResponsesClient) {
        let cloud = cloud ?? .live
        switch effectiveMode(for: settings.providerMode, channel: channel, cloudReady: cloud.isReady) {
        case .appleOnDevice:
            // On-device only — no cloud backup. When the local model is usable,
            // run it; otherwise hand back the client (it throws a clear error
            // that surfaces in chat) and signal "not ready" so generators degrade
            // to scripted.
            let onDevice = AppleFoundationModelsClient()
            let available = AppleOnDeviceAvailability.current.isAvailable
            return (available ? "on-device" : nil, onDevice)
        case .agaraCloud:
            // `effectiveMode` only routes here when the gate passed; the sentinel is the readiness
            // `CoachFeatureFlags` reads, exactly like a key is for the keyed providers.
            return (cloud.isReady ? "agara-cloud" : nil, cloud.makeClient())
        default:
            return directClient(
                settings.providerMode, settings: settings,
                openAIKeyStore: openAIKeyStore, geminiKeyStore: geminiKeyStore,
                openRouterKeyStore: openRouterKeyStore, minimaxKeyStore: minimaxKeyStore,
                localKeyStore: localKeyStore,
                openAIClientFactory: openAIClientFactory
            )
        }
    }

    /// The mode a turn actually runs in.
    ///
    /// The Agara cloud coach is the release default and needs its gate (`CoachGate`); a stored bring-your-own-key (or
    /// self-hosted) mode therefore resolves to the cloud coach when it can run and to the on-device model otherwise —
    /// never to a bring-your-own-key client in a release build. Debug builds honour every stored choice, so existing
    /// developer and test setups keep their provider.
    static func effectiveMode(
        for stored: CoachProviderMode,
        channel: CoachBuildChannel = .current,
        cloudReady: Bool
    ) -> CoachProviderMode {
        switch stored {
        case .appleOnDevice, .offlineStub:
            return stored
        case .agaraCloud:
            return cloudReady ? .agaraCloud : .appleOnDevice
        case .userOpenAIKey, .userGeminiKey, .userOpenRouterKey, .userMiniMaxKey, .localOpenAICompat, .backendProxy:
            if channel == .debug { return stored }
            return cloudReady ? .agaraCloud : .appleOnDevice
        }
    }

    /// Builds a client for a concrete (non-on-device) provider, mirroring the
    /// prior per-call-site logic. Returns a client even when the key is absent
    /// (`key == nil`); the feature-flags gate prevents an empty-key call.
    private static func directClient(
        _ mode: CoachProviderMode,
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        minimaxKeyStore: APIKeyStore,
        localKeyStore: APIKeyStore,
        openAIClientFactory: (String) -> ResponsesClient
    ) -> (key: String?, client: ResponsesClient) {
        switch mode {
        case .userGeminiKey:
            #if DEBUG
            let key = (try? geminiKeyStore.readKey()) ?? nil
            return (key, GeminiClient(apiKey: key ?? ""))
            #else
            break
            #endif
        case .userOpenRouterKey:
            #if DEBUG
            let key = (try? openRouterKeyStore.readKey()) ?? nil
            return (key, OpenRouterClient(
                apiKey: key ?? "",
                model: settings.openRouterModel,
                privacyRouting: settings.orEnablePrivacyRouting,
                providerSort: settings.orProviderSort))
            #else
            break
            #endif
        case .userMiniMaxKey:
            #if DEBUG
            let key = (try? minimaxKeyStore.readKey()) ?? nil
            return (key, MiniMaxClient(apiKey: key ?? "", model: settings.minimaxModel))
            #else
            break
            #endif
        case .localOpenAICompat:
            #if DEBUG
            // Readiness is a base URL that would actually work — `validate`, not "non-empty".
            // Settings persists the field as the user types, so a non-empty check would flip the
            // coach to "Active" on the first character and every turn would then fail inside
            // `send()` with the same URL error the Settings field is already showing inline.
            // The key may legitimately be absent and is passed through as nil so the client omits
            // the Authorization header entirely.
            let baseURL = settings.resolvedLocalBaseURL
            let key = (try? localKeyStore.readKey()) ?? nil
            let ready = LocalEndpoint.validate(baseURL) == nil ? baseURL : nil
            return (ready, LocalOpenAICompatClient(
                baseURL: baseURL,
                model: settings.resolvedLocalModel,
                apiKey: key,
                toolCallingEnabled: settings.localToolCalling,
                structuredOutput: settings.localStructuredOutput,
                maxOutputTokens: settings.localMaxTokens > 0 ? settings.localMaxTokens : nil,
                readTimeoutSeconds: settings.localTimeoutSeconds))
            #else
            break
            #endif
        default:
            #if DEBUG
            // userOpenAIKey / offlineStub / backendProxy (and appleOnDevice never
            // reaches here) all use the OpenAI key + factory.
            let key = (try? openAIKeyStore.readKey()) ?? nil
            return (key, openAIClientFactory(key ?? ""))
            #else
            break
            #endif
        }
        // Release: no bring-your-own-key client exists in this build (contract decision 4). `effectiveMode` never
        // routes a release turn here — this is the compile-time floor that keeps it that way.
        let onDevice = AppleFoundationModelsClient()
        return (AppleOnDeviceAvailability.current.isAvailable ? "on-device" : nil, onDevice)
    }
}
