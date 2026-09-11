import Foundation

/// User preference: whether the Veepoo/TK20 ring streams heart rate continuously while connected.
/// Live streaming holds the `D0 01` test stream open (~1 Hz) so the HR card ticks during exercise,
/// at the cost of battery; turning it off reverts to the one-shot measurement + the periodic poll.
/// The engine re-reads this store on its poll tick, so a change applies within ~30 s of connect.
@Observable
final class VeepooLivePrefsStore {
    static let shared = VeepooLivePrefsStore()

    private static let key = "veepoo.liveHeartRateEnabled"

    var liveHeartRateEnabled: Bool {
        didSet { UserDefaults.standard.set(liveHeartRateEnabled, forKey: Self.key) }
    }

    init() {
        liveHeartRateEnabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}