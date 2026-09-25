import Foundation

/// A reference range from the shared catalog (`AgaraConfig.Health`, from `docs/config/shared.yaml`):
/// `"lo-hi"`, lower inclusive, upper exclusive; `"-hi"` has no lower bound. Held as **raw integers**
/// (value × `scale`) so a boundary compare is exact — the vendor compares floats against doubles, which
/// flags an HDL of 0.96 (0.9599…f) as below 0.96. Android parses the same strings the same way.
struct HealthRange: Equatable {
    let lower: Int?
    let upper: Int

    init(lower: Int?, upper: Int) {
        self.lower = lower
        self.upper = upper
    }

    init?(_ spec: String, scale: Int) {
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let hi = Double(parts[1]) else { return nil }
        upper = Int((hi * Double(scale)).rounded())
        if parts[0].isEmpty {
            lower = nil
        } else if let lo = Double(parts[0]) {
            lower = Int((lo * Double(scale)).rounded())
        } else {
            return nil
        }
    }

    func contains(raw: Int) -> Bool {
        if let lower, raw < lower { return false }
        return raw < upper
    }
}

/// Reference ranges, the abnormal count and display units for the five blood-component estimates.
enum BloodComponents {
    /// Raw-integer scale used for range compares: lipids in hundredths of a mmol/L; uric acid in whole
    /// µmol/L (the vendor rounds it to an integer before comparing).
    static func scale(for metric: MetricKind) -> Int {
        metric == .uricAcid ? 1 : 100
    }

    /// The canonical value (mmol/L or µmol/L) as the raw integer the ranges compare against.
    static func raw(_ value: Double, for metric: MetricKind) -> Int {
        Int((value * Double(scale(for: metric))).rounded())
    }

    /// The catalog range for `metric` and sex. Uric acid and HDL differ by sex; a profile with no sex set
    /// uses the male ranges (the vendor app's default).
    static func range(for metric: MetricKind, sex: BiologicalSex) -> HealthRange? {
        let female = sex == .female
        let spec: String
        switch metric {
        case .totalCholesterol: spec = AgaraConfig.Health.totalCholesterolMmol
        case .triglycerides: spec = AgaraConfig.Health.triglyceridesMmol
        case .hdl: spec = female ? AgaraConfig.Health.hdlMmolFemale : AgaraConfig.Health.hdlMmolMale
        case .ldl: spec = AgaraConfig.Health.ldlMmol
        case .uricAcid: spec = female ? AgaraConfig.Health.uricAcidUmolFemale : AgaraConfig.Health.uricAcidUmolMale
        default: return nil
        }
        return HealthRange(spec, scale: scale(for: metric))
    }

    static func isAbnormal(_ value: Double, metric: MetricKind, sex: BiologicalSex) -> Bool {
        guard let range = range(for: metric, sex: sex) else { return false }
        return !range.contains(raw: raw(value, for: metric))
    }

    /// How many of the given latest values fall outside their range. Missing metrics don't count.
    static func abnormalCount(_ values: [MetricKind: Double], sex: BiologicalSex) -> Int {
        values.filter { isAbnormal($0.value, metric: $0.key, sex: sex) }.count
    }

    /// Straight from a ring reading's integers (uric acid ÷10 rounded, like the vendor).
    static func abnormalCount(_ reading: BloodComponentsReading, sex: BiologicalSex) -> Int {
        let raws: [(MetricKind, Int)] = [
            (.totalCholesterol, reading.totalCholesterolRaw), (.triglycerides, reading.triglyceridesRaw),
            (.hdl, reading.hdlRaw), (.ldl, reading.ldlRaw),
            (.uricAcid, Int((Double(reading.uricAcidRaw) / 10).rounded())),
        ]
        return raws.filter { metric, raw in
            guard let range = range(for: metric, sex: sex) else { return false }
            return !range.contains(raw: raw)
        }.count
    }

    // MARK: Display units

    /// mmol/L (µmol/L for uric acid) by default; mg/dL when the user reads glucose in mg/dL.
    static func displayValue(_ value: Double, metric: MetricKind, unit: GlucoseUnit) -> Double {
        guard unit == .mgdl else { return value }
        switch metric {
        case .totalCholesterol, .hdl, .ldl: return value * 38.67
        case .triglycerides: return value * 88.57
        case .uricAcid: return value / 59.48
        default: return value
        }
    }

    /// The inverse of `displayValue`.
    static func canonicalValue(_ display: Double, metric: MetricKind, unit: GlucoseUnit) -> Double {
        guard unit == .mgdl else { return display }
        switch metric {
        case .totalCholesterol, .hdl, .ldl: return display / 38.67
        case .triglycerides: return display / 88.57
        case .uricAcid: return display * 59.48
        default: return display
        }
    }

    static func displayUnit(metric: MetricKind, unit: GlucoseUnit) -> String {
        if unit == .mgdl { return "mg/dL" }
        return metric == .uricAcid ? "µmol/L" : "mmol/L"
    }

    /// Formatted in the display unit: mmol/L to two decimals, µmol/L whole, mg/dL whole (uric acid in
    /// mg/dL to one decimal — its values sit around 4).
    static func format(_ value: Double, metric: MetricKind, unit: GlucoseUnit) -> String {
        let shown = displayValue(value, metric: metric, unit: unit)
        switch (metric, unit) {
        case (.uricAcid, .mgdl): return String(format: "%.1f", shown)
        case (.uricAcid, _), (_, .mgdl): return "\(Int(shown.rounded()))"
        default: return String(format: "%.2f", shown)
        }
    }

    /// Zones in canonical units for the detail legend and chart colouring: below / in / above range.
    static func zones(for metric: MetricKind, sex: BiologicalSex) -> [MetricZone] {
        guard let range = range(for: metric, sex: sex) else { return [] }
        let scale = Double(scale(for: metric))
        let lower = range.lower.map { Double($0) / scale }
        let upper = Double(range.upper) / scale
        var zones: [MetricZone] = []
        if let lower {
            zones.append(MetricZone(id: "\(metric.rawValue).low", label: "Below range", lower: nil, upper: lower,
                                    severity: .watch, colorToken: .blue,
                                    explanation: "Below the reference range. An optical estimate, not a lab result."))
        }
        zones.append(MetricZone(id: "\(metric.rawValue).in", label: "In range", lower: lower, upper: upper,
                                severity: .normal, colorToken: .mint,
                                explanation: "Within the reference range."))
        zones.append(MetricZone(id: "\(metric.rawValue).high", label: "Above range", lower: upper, upper: nil,
                                severity: .watch, colorToken: .amber,
                                explanation: "Above the reference range. An optical estimate, not a lab result."))
        return zones
    }
}

/// What the Vitals "Blood components" card shows: the latest of each estimate and how many are out of
/// range (sex from the profile).
struct BloodComponentsSummary: Equatable {
    /// Latest canonical value per component (absent components are simply missing).
    let values: [MetricKind: Double]
    /// When the newest of them was recorded.
    let updatedAt: Date?
    let abnormalCount: Int

    init(values: [MetricKind: Double], updatedAt: Date?, sex: BiologicalSex) {
        self.values = values
        self.updatedAt = updatedAt
        self.abnormalCount = BloodComponents.abnormalCount(values, sex: sex)
    }

    var isEmpty: Bool { values.isEmpty }

    /// "No values out of range" / "1 value out of range" / "N values out of range".
    var abnormalText: String {
        switch abnormalCount {
        case 0: return "No values out of range"
        case 1: return "1 value out of range"
        default: return "\(abnormalCount) values out of range"
        }
    }
}
