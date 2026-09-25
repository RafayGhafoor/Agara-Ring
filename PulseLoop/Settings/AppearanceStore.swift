import Foundation
import Observation

/// Light/dark choice in Settings › Appearance. `system` follows the OS setting live.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

/// One colour family of the palette catalog (Ember, Midnight, Forest, Rose), with its dark and light theme.
/// Derived from `AgaraTheme.all`, so a flavour added to `palette.yaml` shows up here without code changes.
struct AppearanceFlavour: Identifiable, Equatable {
    let id: String
    let name: String
    let dark: AgaraTheme
    let light: AgaraTheme

    static func == (a: AppearanceFlavour, b: AppearanceFlavour) -> Bool { a.id == b.id }

    func theme(isLight: Bool) -> AgaraTheme { isLight ? light : dark }

    /// Catalog order; a flavour missing either variant is skipped.
    static var all: [AppearanceFlavour] {
        var ids: [String] = []
        for theme in AgaraTheme.all where !ids.contains(theme.flavour) { ids.append(theme.flavour) }
        return ids.compactMap { id in
            guard let dark = AgaraTheme.all.first(where: { $0.flavour == id && !$0.isLight }),
                  let light = AgaraTheme.all.first(where: { $0.flavour == id && $0.isLight }) else { return nil }
            return AppearanceFlavour(id: id, name: dark.flavourName, dark: dark, light: light)
        }
    }

    static func named(_ id: String) -> AppearanceFlavour? { all.first { $0.id == id } }
}

/// What applies until the user picks: flavour by profile sex, mode from the catalog (`shared.yaml`
/// `appearance_default_*` → `AgaraConfig.Appearance`). Same mapping as Android `AppearanceDefaults`.
enum AppearanceDefaults {
    static func flavour(for sex: String?) -> String {
        switch sex?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "male": return AgaraConfig.Appearance.defaultFlavourMale
        case "female": return AgaraConfig.Appearance.defaultFlavourFemale
        default: return AgaraConfig.Appearance.defaultFlavourOther
        }
    }

    static var mode: AppearanceMode { AppearanceMode(rawValue: AgaraConfig.Appearance.defaultMode) ?? .system }
}

/// The user's appearance choice (mode + flavour), persisted in UserDefaults, and its resolution to a catalog
/// theme. Nothing is stored until the user picks, so the defaults keep following the profile's sex.
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    static let modeKey = "appearance.mode"
    static let flavourKey = "appearance.flavour"

    @ObservationIgnored private let defaults: UserDefaults
    /// nil until the user picks.
    private(set) var storedMode: AppearanceMode?
    private(set) var storedFlavour: String?
    /// Debug `-theme <name>`: pins that theme regardless of the choice above (screenshots).
    var debugThemeOverride: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedMode = defaults.string(forKey: Self.modeKey).flatMap(AppearanceMode.init(rawValue:))
        storedFlavour = defaults.string(forKey: Self.flavourKey).flatMap { AppearanceFlavour.named($0)?.id }
    }

    var mode: AppearanceMode { storedMode ?? AppearanceDefaults.mode }

    func flavour(sex: String?) -> String { storedFlavour ?? AppearanceDefaults.flavour(for: sex) }

    func setMode(_ mode: AppearanceMode) {
        storedMode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    func setFlavour(_ id: String) {
        guard AppearanceFlavour.named(id) != nil else { return }
        storedFlavour = id
        defaults.set(id, forKey: Self.flavourKey)
    }

    /// The theme to show now. `systemIsDark` is the OS setting (only consulted in `system` mode).
    func resolvedTheme(systemIsDark: Bool, sex: String?) -> AgaraTheme {
        if let debugThemeOverride, let pinned = AgaraTheme.named(debugThemeOverride) { return pinned }
        return Self.resolve(mode: mode, systemIsDark: systemIsDark, flavour: flavour(sex: sex))
    }

    /// Mode × system × flavour → catalog theme. An unknown flavour falls back to the Ember pair.
    static func resolve(mode: AppearanceMode, systemIsDark: Bool, flavour: String) -> AgaraTheme {
        let isLight: Bool
        switch mode {
        case .system: isLight = !systemIsDark
        case .dark: isLight = false
        case .light: isLight = true
        }
        let family = AppearanceFlavour.named(flavour)
            ?? AppearanceFlavour.named(AgaraConfig.Appearance.defaultFlavourOther)
        return family?.theme(isLight: isLight) ?? (isLight ? .light : .dark)
    }
}
