import Foundation

/// Runtime view of the shared feature flags (`docs/config/features.yaml` → the generated `AgaraFeature`).
/// Same name and rule as Android's `AgaraFeatureStore`:
///
/// * `isOn(feature)` is the debug override when one is set, otherwise the catalog's `defaultOn`.
/// * Overrides exist **only in debug builds**: the `-features "a=on,b=off"` launch argument (applied at
///   launch, like `-theme`) and the Settings › Developer › Feature flags toggles, both persisted in
///   UserDefaults. A release build always reads the catalog default.
/// * Flags gate UI and *new writes to the ring*. Decoding and storing data the ring already sends is
///   never gated — turning a flag on later shows history that is already there.
@MainActor
@Observable
final class AgaraFeatureStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = AgaraFeatureStore()

    /// UserDefaults key holding the override map (`[flag key: Bool]`).
    static let overridesKey = "agara.featureOverrides"
    /// The launch-argument key (`-features "a=on,b=off"` lands in UserDefaults' argument domain).
    static let launchArgumentKey = "features"

    private let defaults: UserDefaults
    /// Current overrides by flag. Observed, so a toggle in Settings re-renders every gated view.
    private(set) var overrides: [AgaraFeature: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.overrides = Self.load(from: defaults)
    }

    /// The flag's effective value.
    func isOn(_ feature: AgaraFeature) -> Bool {
        #if DEBUG
        if let value = overrides[feature] { return value }
        #endif
        return feature.defaultOn
    }

    /// Shorthand for `shared.isOn(_:)`.
    static func isOn(_ feature: AgaraFeature) -> Bool { shared.isOn(feature) }

    /// The debug override for `feature`, if any.
    func override(for feature: AgaraFeature) -> Bool? { overrides[feature] }

    /// Set (or clear, with nil) a debug override and persist it.
    func setOverride(_ feature: AgaraFeature, _ value: Bool?) {
        overrides[feature] = value
        persist()
    }

    /// Drop every override — back to the catalog defaults.
    func resetAll() {
        overrides.removeAll()
        persist()
    }

    /// Apply a `-features` spec on top of the stored overrides (debug builds call this at launch).
    func applyLaunchOverrides(_ spec: String?) {
        guard let spec, !spec.isEmpty else { return }
        for (feature, value) in Self.parse(spec) { overrides[feature] = value }
        persist()
    }

    /// The parity switches (features.yaml "Parity switches", phase 6): features one app has and the other
    /// doesn't yet. Grouped in Settings › Developer › Feature flags; `parity=on` turns them all on.
    static let parityFlags: [AgaraFeature] = [
        .coach, .coachHistory, .coachCheckinExtras, .physiology, .nutrition, .strava, .agaraCloud,
        .hrZonesEditor, .activityTrackingSettings, .chartResolutionSetting, .liveHrToggle, .shareCard,
        .staleWorkoutRecovery, .activityTrendsYear,
    ]

    /// Parse `"a=on,b=off"`. Accepts on/off, true/false, 1/0, yes/no (any case, spaces ignored); unknown
    /// flags and malformed pairs are skipped rather than failing the whole spec. Two group keys: `all`
    /// (every flag) and `parity` (`parityFlags`); later pairs win, so `all=on,coach=off` works.
    static func parse(_ spec: String) -> [AgaraFeature: Bool] {
        var result: [AgaraFeature: Bool] = [:]
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard parts.count == 2 else { continue }
            let value: Bool
            switch parts[1] {
            case "on", "true", "1", "yes": value = true
            case "off", "false", "0", "no": value = false
            default: continue
            }
            switch parts[0] {
            case "all": for feature in AgaraFeature.allCases { result[feature] = value }
            case "parity": for feature in parityFlags { result[feature] = value }
            default:
                guard let feature = AgaraFeature(rawValue: parts[0]) else { continue }
                result[feature] = value
            }
        }
        return result
    }

    private func persist() {
        let map = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        defaults.set(map, forKey: Self.overridesKey)
    }

    private static func load(from defaults: UserDefaults) -> [AgaraFeature: Bool] {
        guard let map = defaults.dictionary(forKey: overridesKey) as? [String: Bool] else { return [:] }
        var result: [AgaraFeature: Bool] = [:]
        for (key, value) in map {
            if let feature = AgaraFeature(rawValue: key) { result[feature] = value }
        }
        return result
    }
}

/// Launch-argument tooling (`-seedDemo YES`, `-virtualRing 9909`, `-cloudBaseUrl …`, `-historyDays N`, …) arrives
/// through the UserDefaults argument domain. It exists for the simulator/E2E rigs only: a Release build ignores
/// every such key, so nobody can reshape a shipped app's data or endpoints by launching it with arguments.
/// Every launch-argument read goes through here.
nonisolated enum DebugLaunch {
    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func string(_ key: String) -> String? { isEnabled ? UserDefaults.standard.string(forKey: key) : nil }
    static func bool(_ key: String) -> Bool { isEnabled && UserDefaults.standard.bool(forKey: key) }
    static func integer(_ key: String) -> Int { isEnabled ? UserDefaults.standard.integer(forKey: key) : 0 }
    /// The key is present at all (a bare `-virtualRing`).
    static func isSet(_ key: String) -> Bool { isEnabled && UserDefaults.standard.object(forKey: key) != nil }
    static func environment(_ name: String) -> String? {
        isEnabled ? ProcessInfo.processInfo.environment[name] : nil
    }
}
