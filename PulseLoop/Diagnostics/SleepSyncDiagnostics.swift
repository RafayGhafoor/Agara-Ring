import Foundation

/// Counts of the sleep-transfer failures that used to be silent, for the diagnostics export.
///
/// One place, because these are the questions a support report has to answer: was a night missing because
/// the ring kept none, because its transfer lost a page (BUG-201), because the record carried no curve
/// (BUG-108), because the ring's own count disagreed with the curve (BUG-202), or because the peer was not
/// the ring (SEC-301)? The sync engine counts them; `DiagnosticsExporter` prints them.
///
/// Thread-safe (`@unchecked Sendable` + a lock) because the engine is main-actor and the exporter may run
/// off it. Process-wide: the counters are cumulative for the app run, like `SensorIdentity`'s state.
nonisolated final class SleepSyncDiagnostics: @unchecked Sendable {
    static let shared = SleepSyncDiagnostics()

    /// The fields the export carries, spelled once. Keys are stable snake_case so a report can be diffed.
    enum Field: String, CaseIterable {
        /// A transfer whose page run was short or whose session count did not match — the day is retried.
        case incompleteTransfers = "incomplete_transfers"
        /// Sessions dropped because the `A1` block overran the payload or had no `A5` curve (BUG-108).
        case rejectedSessions = "rejected_sessions"
        /// Sessions whose curve disagreed with the ring's own `A3` total/awake count (BUG-202, diagnostic).
        case countMismatches = "count_mismatches"
        /// Sessions whose `a1` MAC contradicted the identity this peripheral first reported (SEC-301).
        case provenanceMismatches = "provenance_mismatches"
        /// Sessions on a link that never reported an `a1` MAC at all (SEC-301's null case).
        case provenanceNullIdentity = "provenance_null_identity"
    }

    private let lock = NSLock()
    private var counts: [Field: Int] = [:]

    func record(_ field: Field, by amount: Int = 1) {
        lock.lock(); counts[field, default: 0] += amount; lock.unlock()
    }

    func count(_ field: Field) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[field] ?? 0
    }

    /// Every field, including the zeros — a report should say "0 mismatches" as clearly as "3".
    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: Field.allCases.map { ($0.rawValue, counts[$0] ?? 0) })
    }

    /// Tests only: start from zero so a count is attributable.
    func reset() {
        lock.lock(); counts.removeAll(); lock.unlock()
    }
}
