import Foundation

/// A single, coalesced "persisted data changed" signal. `EventPersistenceSubscriber` bumps it once
/// per batched save (not per event), so observers (e.g. `TodayStore`, `VitalsStore`) recompute their
/// cached state once per sync burst instead of once per packet. Decouples the persistence layer from
/// the stores without a broad `@Query`/model-observation graph.
@MainActor
@Observable
final class AgaraDataChange {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = AgaraDataChange()

    /// Monotonic token; changes on every batched persistence flush. Observe via `.onChange(of:)`.
    private(set) var token: Int = 0

    func notify() { token &+= 1 }
}
