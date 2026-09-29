import Foundation

/// The runtime configuration of Agara Cloud: the catalog values (`AgaraConfig.Cloud`), with the debug-only launch
/// overrides used by the simulator rigs and the UI tests. An empty Firebase key or an empty server URL means
/// "not configured": the cloud screens say so and nothing ever touches the network.
nonisolated struct AgaraCloudConfig: Sendable, Equatable {
    var firebaseApiKey: String
    var firebaseProjectId: String
    var baseURL: URL?
    var syncIntervalMinutes: Int
    var retryBackoffSeconds: [Int]
    var verifyPollSeconds: Int
    /// Opening the app syncs only when the last successful sync is older than this (catalog `cloud_sync_open_min_gap_minutes`).
    var syncOpenMinGapMinutes = AgaraConfig.Cloud.syncOpenMinGapMinutes

    /// Identity Toolkit and Secure Token hosts. Overridable only so tests can pin them; production uses Google's.
    var identityToolkitBase = URL(string: "https://identitytoolkit.googleapis.com")!
    var secureTokenBase = URL(string: "https://securetoken.googleapis.com")!

    var isConfigured: Bool { !firebaseApiKey.isEmpty && baseURL != nil }

    /// The shipped configuration, plus (DEBUG only) `-cloudBaseUrl`, `-cloudFirebaseKey`.
    @MainActor static var current: AgaraCloudConfig {
        var key = AgaraConfig.Cloud.firebaseApiKey
        var base = AgaraConfig.Cloud.v2BaseUrl
        if let override = DebugLaunch.string("cloudBaseUrl"), !override.isEmpty { base = override }
        if let override = DebugLaunch.string("cloudFirebaseKey"), !override.isEmpty { key = override }
        return AgaraCloudConfig(
            firebaseApiKey: key,
            firebaseProjectId: AgaraConfig.Cloud.firebaseProjectId,
            baseURL: base.isEmpty ? nil : URL(string: base),
            syncIntervalMinutes: AgaraConfig.Cloud.syncIntervalMinutes,
            retryBackoffSeconds: parseLadder(AgaraConfig.Cloud.syncRetryBackoffSeconds),
            verifyPollSeconds: AgaraConfig.Cloud.verifyPollSeconds
        )
    }

    /// `"30,120,600,1800"` → `[30, 120, 600, 1800]`; junk is dropped and an empty result falls back to one minute.
    static func parseLadder(_ text: String) -> [Int] {
        let steps = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
        return steps.isEmpty ? [60] : steps
    }
}
