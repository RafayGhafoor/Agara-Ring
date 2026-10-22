import Foundation

/// User preference: whether the Veepoo/TK20 ring streams heart rate continuously while connected.
/// Live streaming holds the `D0 01` test stream open (~1 Hz, one stored row per 5 s) so the HR card ticks during
/// exercise, at the cost of ring battery; off reverts to the one-shot measurement + the periodic poll.
///
/// Spec (`docs/process/plans/rebrand-measure-1.0.md` item 1, both apps): an **unset** preference means
/// `AgaraConfig.Ring.liveHrDefaultOn` (catalog `ring_live_hr_default_on`, 0 → off). A change posts
/// `didChangeNotification`; the engine reacts at once (turning it off sends `D0 00` once), not at the next poll tick.
@Observable
final class VeepooLivePrefsStore {
    static let shared = VeepooLivePrefsStore()

    /// Posted on every change of `liveHeartRateEnabled`.
    static let didChangeNotification = Notification.Name("agara.liveHeartRatePreferenceChanged")

    /// Install-bound key (kept from upstream).
    static let key = "veepoo.liveHeartRateEnabled"

    /// The value an unset preference reads as.
    static var defaultEnabled: Bool { AgaraConfig.Ring.liveHrDefaultOn != 0 }

    @ObservationIgnored private let defaults: UserDefaults

    var liveHeartRateEnabled: Bool {
        didSet {
            guard liveHeartRateEnabled != oldValue else { return }
            defaults.set(liveHeartRateEnabled, forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        liveHeartRateEnabled = defaults.object(forKey: Self.key) as? Bool ?? Self.defaultEnabled
    }
}
