import Foundation

/// Who measured a reading (AGB v1 §4): the ring's identity from its `a1` reply, the per-install id for
/// phone-sourced data, or the "unknown" id. Also holds the per-install `client_id` (sync bookkeeping only; never
/// part of a block key). Thread-safe, because `Measurement.init` reads it from wherever a row is created.
///
/// The ring identity is the MAC from the `a1` reply (bytes 12…17 reversed), **not** the CoreBluetooth peripheral
/// UUID: iOS never sees the BLE address, but both platforms read the `a1` bytes, so an iPhone and an iPad that
/// sync the same ring produce the same key and the merge de-duplicates instead of doubling every reading.
nonisolated final class SensorIdentity: @unchecked Sendable {
    static let shared = SensorIdentity()
    static let installKey = "agara.storage.installUUID"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var ringSensor: String?
    private var cachedInstallUUID: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The per-install random UUID (lowercase, hyphenated), created on first use. Also the sync `client_id`.
    var clientId: String {
        lock.lock(); defer { lock.unlock() }
        if let cachedInstallUUID { return cachedInstallUUID }
        let id: String
        if let stored = defaults.string(forKey: Self.installKey), UUID(uuidString: stored) != nil {
            id = stored.lowercased()
        } else {
            id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Self.installKey)
        }
        cachedInstallUUID = id
        return id
    }

    var installSensorId: String { AGB.sensorId(installUUID: clientId) }

    /// The connected ring's sensor id (nil until the link's `a1` reply arrived).
    var ringSensorId: String? {
        lock.lock(); defer { lock.unlock() }
        return ringSensor
    }

    /// Record the link's sensor id (from its `a1` reply), or clear it (a disconnect, a forgotten ring).
    func setRing(sensorId: String?) {
        lock.lock(); ringSensor = sensorId; lock.unlock()
    }

    /// Convenience for a raw MAC (tests, tools). Nil / malformed → unknown.
    func setRing(mac: String?) { setRing(sensorId: mac.flatMap { AGB.sensorId(ringMac: $0) }) }

    /// Forget the cached install id (the "delete all my data" wipe removed the defaults domain; the next read mints a new one).
    func reset() {
        lock.lock(); cachedInstallUUID = nil; ringSensor = nil; lock.unlock()
    }

    /// The sensor id a row of `source` (a `MeasurementSource` raw value) gets at insert time. Phone-sourced rows
    /// (manual entries) carry the install id; everything the ring produced carries the ring id, or unknown when
    /// no `a1` reply has been seen on this connection. Such rows form their own key and are never re-attributed.
    func sensorId(forSource source: String) -> String {
        if source == MeasurementSource.manual.rawValue { return installSensorId }
        return ringSensorId ?? AGB.unknownSensor
    }
}
