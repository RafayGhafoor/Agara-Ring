import Foundation
import Observation

/// The user's answer to the cloud coach's third-party disclosure (Apple 5.1.2(i), `docs/ring/coach-proxy.md` §11).
///
/// Consent is what unlocks the first cloud turn, so it is recorded with the version of the text that was shown:
/// bumping `version` re-asks everyone, which is how a changed provider or retention policy reaches existing users
/// without an email. Withdrawing clears it and — see `CoachSettingsSection` — switches the coach back to on-device,
/// so a cloud turn cannot happen after withdrawal even if the screen is reopened.
///
/// Plain `UserDefaults`: nothing here is secret, and "Delete all my data" (which clears the defaults domain) resets
/// it like the rest of the app.
@MainActor
@Observable
final class CoachConsentStore {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    /// Bump when the disclosure changes materially — the provider, the retention window, or what is sent (§5).
    static let version = 1

    static let shared = CoachConsentStore()

    private let defaults: UserDefaults

    private enum Key {
        static let version = "agara.coach.consentVersion"
        static let at = "agara.coach.consentAt"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Consent is on record for the current disclosure version.
    var hasConsent: Bool { defaults.integer(forKey: Key.version) >= Self.version }

    /// When the user agreed, if they did.
    var consentedAt: Date? { defaults.object(forKey: Key.at) as? Date }

    func give(at date: Date = AppClock.now) {
        defaults.set(Self.version, forKey: Key.version)
        defaults.set(date, forKey: Key.at)
    }

    func withdraw() {
        defaults.removeObject(forKey: Key.version)
        defaults.removeObject(forKey: Key.at)
    }
}
