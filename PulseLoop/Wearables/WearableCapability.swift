import Foundation

/// What a connected wearable can actually do. The active device's `Set<WearableCapability>` is the
/// single source the product UI consults to decide which metric cards / actions to render: the Agara
/// ring declares the metrics it records, and a metric it doesn't declare simply isn't offered.
///
/// Borrowed (in spirit) from GadgetBridge's `DeviceCoordinator.supportsX()` capability queries, but
/// collapsed into one enum so capabilities can be persisted as a CSV on `Device` and gated in SwiftUI
/// without a per-feature boolean sprawl.
///
/// Raw values are persisted (see `Device.capabilitiesRaw`); **append cases, never rename/reorder.**
enum WearableCapability: String, CaseIterable, Codable, Sendable {
    // Metrics the app renders and the Agara ring records.
    case heartRate
    case spo2
    case steps
    case sleep
    case battery

    case remSleep
    case stress
    case hrv
    case temperature

    case bloodPressure
    case bloodSugar
    case fatigue

    // Interaction capabilities
    case manualHeartRate      // single-shot on-demand HR
    case manualSpo2           // single-shot on-demand SpO2
    case manualHrv            // single-shot on-demand HRV (rides the same live stream as HR)
    case manualBloodPressure  // single-shot on-demand BP
    /// One measurement returns *every* vital at once. Drives a single "Measure Vitals" action instead
    /// of a button per metric; the Agara ring measures one at a time, so it does not declare this.
    case combinedVitalsMeasurement
    case realtimeHeartRate    // live HR stream
    case realtimeSteps        // live activity stream
    case findDevice
    case powerOff
    case factoryReset

    // Configurable all-day measurement: the device exposes a settable HR sampling interval. A device
    // without it keeps the Measurement settings screen hidden.
    case measurementInterval

    // The device records all-day SpO2 on-ring and the app can read that log back. Drives the workout
    // vitals plan: a device with no `manualSpo2` but with this capability shows the latest logged value
    // instead of pretending it can spot-measure.
    case spo2History
}

extension Set where Element == WearableCapability {
    /// Serialize to a stable comma-separated string for SwiftData storage.
    var csv: String {
        WearableCapability.allCases
            .filter { contains($0) }   // deterministic order
            .map(\.rawValue)
            .joined(separator: ",")
    }

    /// Parse from the CSV form. Unknown tokens are ignored so older/newer stores stay forward-compatible.
    init(csv: String) {
        let parsed = csv
            .split(separator: ",")
            .compactMap { WearableCapability(rawValue: String($0)) }
        self = Set(parsed)
    }
}
