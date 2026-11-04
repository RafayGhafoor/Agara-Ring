import Foundation

/// Small persistent bookkeeping of the cloud client: consent, the pull cursor, which account the `block_sync` ledger
/// belongs to, what the server rejected, and a fingerprint per uploaded day row. Plain `UserDefaults` (nothing secret —
/// tokens live in the Keychain), so "Delete all my data" (which clears the defaults domain) resets it too.
nonisolated final class AgaraCloudState: @unchecked Sendable {
    /// Bump when the consent text changes materially: everyone is asked again before the next upload.
    static let consentVersion = 1

    private let defaults: UserDefaults
    private let lock = NSLock()

    private enum Key {
        static let consentVersion = "agara.cloud.consentVersion"
        static let consentAt = "agara.cloud.consentAt"
        static let cursor = "agara.cloud.cursor"
        static let ledgerOwner = "agara.cloud.ledgerOwner"
        static let lastSync = "agara.cloud.lastSync"
        static let lastAttempt = "agara.cloud.lastAttempt"
        static let dayHashes = "agara.cloud.dayHashes"
        static let rejected = "agara.cloud.rejected"
        static let unverifiedSince = "agara.cloud.unverifiedSince"
        static let sleepModel = "agara.cloud.sleepModel"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: Server-side model tuning (plan asana-heart-bugs-2026-11-01, item F)

    /// The last accepted sleep-score model, as `SleepScoreConfig.Cache` encodes it.
    var sleepModel: String? {
        get { lock.lock(); defer { lock.unlock() }; return defaults.string(forKey: Key.sleepModel) }
    }
    func setSleepModel(_ raw: String?) {
        lock.lock(); defer { lock.unlock() }
        if let raw { defaults.set(raw, forKey: Key.sleepModel) } else { defaults.removeObject(forKey: Key.sleepModel) }
    }

    // MARK: Consent

    var hasConsent: Bool { defaults.integer(forKey: Key.consentVersion) >= Self.consentVersion }
    var consentDate: Date? { defaults.object(forKey: Key.consentAt) as? Date }

    func giveConsent(at date: Date) {
        defaults.set(Self.consentVersion, forKey: Key.consentVersion)
        defaults.set(date, forKey: Key.consentAt)
    }

    func revokeConsent() {
        defaults.removeObject(forKey: Key.consentVersion)
        defaults.removeObject(forKey: Key.consentAt)
    }

    // MARK: Pull cursor and ledger ownership

    var cursor: String {
        get { defaults.string(forKey: Key.cursor) ?? "" }
        set { defaults.set(newValue, forKey: Key.cursor) }
    }

    /// Non-reversible marker of a uid (first 16 hex of SHA-256 over a fixed prefix + uid): the ledger stores this, never the uid.
    static func ownerDigest(_ uid: String) -> String {
        AGB.hex(AGB.sha256(Data(("agara.cloud.owner.v1|" + uid).utf8))).prefix(16).description
    }

    /// The uid whose server state the ledger's `synced_*` columns describe.
    var ledgerOwner: String? {
        get { defaults.string(forKey: Key.ledgerOwner) }
        set { defaults.set(newValue, forKey: Key.ledgerOwner) }
    }

    var lastSync: Date? {
        get { defaults.object(forKey: Key.lastSync) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSync) }
    }

    var lastAttempt: Date? {
        get { defaults.object(forKey: Key.lastAttempt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastAttempt) }
    }

    /// When this device first saw the account unverified (the 72 h grace banner counts from the server's `grace_ends_at`;
    /// this is only the fallback).
    var unverifiedSince: Date? {
        get { defaults.object(forKey: Key.unverifiedSince) as? Date }
        set { defaults.set(newValue, forKey: Key.unverifiedSince) }
    }

    // MARK: Day rows and rejected blocks

    /// `date → SHA-256 hex of the encoded day row the server last acknowledged`.
    var dayHashes: [String: String] {
        get { (defaults.dictionary(forKey: Key.dayHashes) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.dayHashes) }
    }

    /// `block_key → content_hash hex` the server refused: the same bytes are never sent again.
    var rejected: [String: String] {
        get { (defaults.dictionary(forKey: Key.rejected) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.rejected) }
    }

    // MARK: Resets

    /// Forget everything about the server's copy (a different account, or the account was deleted). Consent stays.
    func resetServerView() {
        for key in [Key.cursor, Key.ledgerOwner, Key.lastSync, Key.lastAttempt, Key.dayHashes, Key.rejected, Key.unverifiedSince] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Everything, consent included (delete account, "Delete all my data").
    func resetAll() {
        resetServerView()
        revokeConsent()
    }
}
