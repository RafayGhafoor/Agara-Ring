import Foundation

/// The pure decision behind Agara Cloud's background refresh (release 1.1): given the account state, either cancel the
/// pending `BGAppRefreshTask` or schedule it `delaySeconds` from now. The Android twin (`CloudSchedule`) has the same
/// rule and the same test cases, so both apps sync on the same terms.
///
/// delay = max(0, max(lastSync + interval, retryNextAt ?? 0) - now)
nonisolated enum AgaraCloudSchedule {
    struct Input: Equatable, Sendable {
        var consent: Bool
        var signedIn: Bool
        var verified: Bool
        /// End of the unverified grace when the server said; nil = unknown (the server decides).
        var graceEndsAt: Date?
        /// A stop that needs the user: `email_not_verified` (grace over) or `update_required`.
        var blocked: Bool
        var now: Date
        var lastSync: Date?
        var intervalMinutes: Int
        var retryNextAt: Date?
    }

    enum Decision: Equatable, Sendable {
        case cancel
        case schedule(delaySeconds: Int)
    }

    static func decide(_ input: Input) -> Decision {
        guard input.consent, input.signedIn, !input.blocked else { return .cancel }
        if !input.verified, let ends = input.graceEndsAt, ends <= input.now { return .cancel }
        var earliest = input.now
        if let last = input.lastSync { earliest = max(earliest, last.addingTimeInterval(Double(max(1, input.intervalMinutes)) * 60)) }
        if let retry = input.retryNextAt { earliest = max(earliest, retry) }
        return .schedule(delaySeconds: Int(earliest.timeIntervalSince(input.now).rounded(.up)))
    }

    /// Foreground entry: sync when nothing has synced yet or the last successful sync is at least `minGapMinutes` old.
    static func shouldSyncOnOpen(lastSync: Date?, now: Date, minGapMinutes: Int) -> Bool {
        guard let last = lastSync else { return true }
        return now.timeIntervalSince(last) >= Double(max(0, minGapMinutes)) * 60
    }
}
