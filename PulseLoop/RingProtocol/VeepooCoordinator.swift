import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the Veepoo / Agara Ring (the "H Ring" vendor app, `cn.hring.veepoo`).
///
/// Recognition is name-first, like an earlier family: the ring advertises as `TK20` (the verified unit
/// advertised nothing but the name + `FEE7` service + a `f8f8` manufacturer marker, and `TK20` does
/// not hit the `an earlier family` prefix, so the earlier coordinator in the registry cannot shadow it).
///
/// ## Capability discipline
///
/// Every baseline entry here was **verified on hardware** in the `tools/` BLE harness this project
/// built against the real ring (battery 76 %, daily history 107 records / 835 steps / 0.706 km /
/// 41.1 kcal with HR, SpO₂, HRV, BP, stress, glucose; sleep deep/light/awake/other minutes).
///
/// Deliberately **absent** — the verified subset ends where the ring's abilities do:
///
/// - No `.realtimeHeartRate`: the ring has no push HR stream outside the one-shot D0 test.
/// - No `.powerOff`, `.measurementInterval`: not implemented. `.findDevice` (`b5 0a`/`0b`) is claimed
///   since the measure-hub work; the ring's capability packet 3 byte 8 says it has it.
/// - Fatigue (0x81) and breathing-rate (0x82) tests exist in the SDK and the python client, but no
///   reply decode has been pinned for them yet — the `tools/` harness raw-dumps those streams until a
///   live run defines the byte maps; the app will claim them once that lands.
/// - `.spo2History` **is** included: the all-day SpO₂ is read back as part of the daily DF records
///   (B9), so the "latest logged value" path works off the same transfer. The one-shot SpO₂
///   measurement (0x80) rides too, with the byte-map note carried in `VeepooDecoder.oxygen` (byte 4
///   read constant at 100 on the confirming run).
///
/// MET (BF), respiration (B6), cardiac load (B9 20–24) and the C2 blood components are decoded and
/// stored; their cards sit behind feature flags (`docs/config/features.yaml`).
@MainActor
final class VeepooCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .veepoo

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalized.hasPrefix("TK20") { return true }
        }
        if let model = WearableModel.model(advertisedName: name), model.family == .veepoo { return true }
        // Manufacturer marker from the advertisement capture: `f8f8` company prefix (Veepoo) +
        // the reversed MAC. Backs up the name match; never claimed on its own (FEE7 alone is too
        // common a service to hang a match on).
        if let mfg = advertisement.manufacturerData,
           mfg.count >= 2, mfg[0] == 0xf8, mfg[1] == 0xf8,
           name?.uppercased().hasPrefix("TK") == true
        {
            return true
        }
        return false
    }

    /// The floor, all hardware-verified (see the doc comment above): day steps + the ~1 Hz live
    /// step stream, sleep, in-band battery, the daily-history vitals (HR, SpO₂, HRV, BP, stress,
    /// glucose) with their all-day SpO₂ log — and the one-shot **measurements** the SDK's test
    /// builders drive (heart-rate D0, SpO₂ 0x80, BP 0x90), whose start/stop frames were verified
    /// against the ring via `tools/veepoo_live.py --measure`.
    let capabilities: Set<WearableCapability> = [
        .steps, .realtimeSteps, .sleep, .remSleep, .battery,   // REM: A5 stage bitmap, verified 2026-09-25
        .heartRate, .spo2, .spo2History, .hrv, .stress, .bloodSugar, .bloodPressure,
        .manualHeartRate, .manualSpo2, .manualBloodPressure,
        // Measure hub (docs/process/plans/measure-hub-spec.md): tests the ring's capability packets
        // advertise (`a7`), the DF history series it fills, and find-device (`b5`). The hub still asks
        // `RingCapabilities` per unit when the probe has run; this is the static fallback.
        .manualStress, .manualBloodSugar, .manualBloodComponents,
        .respiration, .met, .cardiacLoad, .bloodComponents, .findDevice,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        VeepooDriver(writer: writer)
    }
}