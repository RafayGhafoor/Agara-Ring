import SwiftUI

/// What a finished on-demand measurement returned. One shape for every metric so the service, the sheet and
/// the notifications don't switch on the kind: a whole-number value (HR, SpO₂, systolic, stress), a second
/// value (diastolic), glucose in mg/dL, the five blood components, or the combined sweep.
struct MeasurementReading: Equatable {
    var value: Int?
    /// Diastolic, for blood pressure — the only single reading that is a pair.
    var secondary: Int?
    /// Glucose in mg/dL (formatted in the user's unit for display).
    var glucoseMgdl: Double?
    var components: BloodComponentsReading?
    var vitals: RingSyncCoordinator.VitalsReading?
}

/// The ring calls a measurement spec needs. `RingSyncCoordinator` is the real one; tests pass a fake.
@MainActor
protocol MeasurementDevice: AnyObject {
    func measureHR() async -> Int?
    func measureSpO2() async -> Int?
    func measureBloodPressure() async -> RingSyncCoordinator.BloodPressureReading?
    func measureStress() async -> Int?
    func measureGlucose() async -> Double?
    func measureBloodComponents() async -> BloodComponentsReading?
}

extension RingSyncCoordinator: MeasurementDevice {}

/// One on-demand test (consistency framework, block A — the measurement engine; AGENTS.md Rule 10). A spec
/// answers everything that differs per metric — the ring command (`run`), duration, validity rule, flags,
/// capability, and (through `kind`) title, unit, icon, tint and copy — so the Measure tile, the running and
/// result UI, background execution, notifications and E2E coverage come for free. Adding a test is one entry
/// in `MeasurementRegistry.all`. Same ids and order as Android's `MeasurementRegistry` (measure-hub spec §3).
struct MeasurementSpec: Identifiable, Equatable {
    /// Shared id: `heartRate`, `spo2`, `bloodPressure`, `stress`, `glucose`, `bloodComponents`.
    let id: String
    /// Presentation (title, unit, icon, tint, instruction/working/failure copy) — `MeasurementKindPresentation`.
    let kind: MeasurementSheet.Kind
    /// Approximate duration shown on the tile (`shared.yaml` → `AgaraConfig.Ring.measureTypicalSeconds*`).
    let seconds: Int
    /// Feature flags that must all be on (none = always offered).
    let flags: [AgaraFeature]
    /// Static fallback: the family capability, used when the ring's own packets haven't been seen.
    let capability: WearableCapability
    /// What the ring's capability packets must say (used when `capability_probe` is on and seen).
    let ringSupport: KeyPath<RingCapabilities, Bool>
    /// Starts the test on the ring and waits for its value (nil = no reading).
    let run: @MainActor (MeasurementDevice) async -> MeasurementReading?

    var title: String { kind.title }
    var symbolName: String { kind.symbolName }
    var tint: Color { kind.tint }
    var durationText: String { "~\(seconds) s" }

    /// A reading only counts when it carries what this metric needs (a BP value without its diastolic half is
    /// not a usable reading; blood components need all five).
    func isUsable(_ reading: MeasurementReading?) -> Bool {
        guard let reading else { return false }
        switch kind {
        case .bloodPressure: return reading.value != nil && reading.secondary != nil
        case .glucose: return reading.glucoseMgdl != nil
        case .bloodComponents: return reading.components != nil
        case .vitals: return !(reading.vitals?.isEmpty ?? true)
        default: return reading.value != nil
        }
    }

    /// The reading as the user sees it ("72 bpm", "120/80 mmHg", "5.4 mmol/L", "5 estimates").
    func resultText(_ reading: MeasurementReading, glucoseUnit: GlucoseUnit) -> String {
        switch kind {
        case .bloodPressure:
            return "\(reading.value ?? 0)/\(reading.secondary ?? 0) mmHg"
        case .glucose:
            let g = UnitsFormatter.glucose(mgdl: reading.glucoseMgdl ?? 0, unit: glucoseUnit)
            return "\(g.value) \(UnitsFormatter.glucoseUnit(glucoseUnit))"
        case .bloodComponents:
            return "five estimates saved"
        case .vitals:
            return "results saved"
        default:
            let unit = kind.unit
            return unit.isEmpty ? "\(reading.value ?? 0)" : "\(reading.value ?? 0) \(unit)"
        }
    }

    static func == (lhs: MeasurementSpec, rhs: MeasurementSpec) -> Bool { lhs.id == rhs.id }
}

enum MeasurementRegistry {
    static let all: [MeasurementSpec] = [
        MeasurementSpec(id: "heartRate", kind: .hr, seconds: AgaraConfig.Ring.measureTypicalSecondsHeartRate,
                        flags: [], capability: .manualHeartRate, ringSupport: \.heartRate) { device in
            await device.measureHR().map { MeasurementReading(value: $0) }
        },
        MeasurementSpec(id: "spo2", kind: .spo2, seconds: AgaraConfig.Ring.measureTypicalSecondsSpo2,
                        flags: [], capability: .manualSpo2, ringSupport: \.spo2) { device in
            await device.measureSpO2().map { MeasurementReading(value: $0) }
        },
        MeasurementSpec(id: "bloodPressure", kind: .bloodPressure,
                        seconds: AgaraConfig.Ring.measureTypicalSecondsBloodPressure,
                        flags: [.measureBp, .vitalsBp], capability: .manualBloodPressure, ringSupport: \.bloodPressure) { device in
            await device.measureBloodPressure().map { MeasurementReading(value: $0.systolic, secondary: $0.diastolic) }
        },
        MeasurementSpec(id: "stress", kind: .stress, seconds: AgaraConfig.Ring.measureTypicalSecondsStress,
                        flags: [.measureStress], capability: .manualStress, ringSupport: \.stress) { device in
            await device.measureStress().map { MeasurementReading(value: $0) }
        },
        MeasurementSpec(id: "glucose", kind: .glucose, seconds: AgaraConfig.Ring.measureTypicalSecondsGlucose,
                        flags: [.measureGlucose, .vitalsGlucose], capability: .manualBloodSugar, ringSupport: \.bloodGlucose) { device in
            await device.measureGlucose().map { MeasurementReading(value: Int($0.rounded()), glucoseMgdl: $0) }
        },
        MeasurementSpec(id: "bloodComponents", kind: .bloodComponents,
                        seconds: AgaraConfig.Ring.measureTypicalSecondsBloodComponents,
                        flags: [.measureLipids, .bloodComponents],
                        capability: .manualBloodComponents, ringSupport: \.bloodComponents) { device in
            await device.measureBloodComponents().map { MeasurementReading(value: 1, components: $0) }
        },
    ]

    static func spec(id: String) -> MeasurementSpec? { all.first { $0.id == id } }

    /// The tiles to offer, in order: every flag on, and supported — by the ring's own capability packets
    /// when the probe is on and has run, otherwise by the family's static capability list.
    static func available(capabilities: Set<WearableCapability>,
                          ring: RingCapabilities?,
                          isOn: (AgaraFeature) -> Bool) -> [MeasurementSpec] {
        let probe = isOn(.capabilityProbe) ? ring : nil
        return all.filter { spec in
            guard spec.flags.allSatisfy(isOn) else { return false }
            if let probe { return probe[keyPath: spec.ringSupport] }
            return capabilities.contains(spec.capability)
        }
    }
}
