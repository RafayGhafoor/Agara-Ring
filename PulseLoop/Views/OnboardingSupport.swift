import Foundation

/// Parses decimal-pad input without assuming one separator. iOS keyboards follow the user's
/// region, so European users commonly enter `72,5` while other regions enter `72.5`.
enum LocalizedDecimalInput {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        var normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        if let separator = locale.decimalSeparator, separator != "." {
            normalized = normalized.replacingOccurrences(of: separator, with: ".")
        }
        normalized = normalized.replacingOccurrences(of: ",", with: ".")

        guard !normalized.isEmpty,
              normalized.filter({ $0 == "." }).count <= 1 else { return nil }
        return Double(normalized)
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

enum OnboardingStep: String, CaseIterable, Codable, Identifiable {
    case welcome
    case ring
    /// After pairing: the history sync day by day (leave-able; the sync continues in the background).
    case syncing
    case profile
    case goals
    case baseline

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct OnboardingProgressStore {
    static let storageKey = "onboarding.route.v2"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPath() -> [OnboardingStep] {
        guard let values = defaults.stringArray(forKey: Self.storageKey) else { return [.welcome] }
        let path = values.compactMap(OnboardingStep.init(rawValue:))
        guard path.first == .welcome, !path.isEmpty else { return [.welcome] }
        return path
    }

    func savePath(_ path: [OnboardingStep]) {
        let safePath = path.first == .welcome && !path.isEmpty ? path : [.welcome]
        defaults.set(safePath.map(\.rawValue), forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

struct ProfileDraft: Equatable {
    /// Profile field names, as the coach's JSON spells them.
    enum Field {
        static let age = "age", sex = "sex", heightCm = "height_cm", weightKg = "weight_kg"
    }

    var name = ""
    // Any edit of an imported value makes it the user's own (no longer "from Apple Health"). Whole-draft assignment
    // (loading the screen) does not trigger these observers.
    var age: Int? { didSet { healthImported.remove(Field.age) } }
    var sex: String? { didSet { healthImported.remove(Field.sex) } }
    var heightCm: Double? { didSet { healthImported.remove(Field.heightCm) } }
    var weightKg: Double? { didSet { healthImported.remove(Field.weightKg) } }
    var units: UnitsPreference
    /// Fields whose value came from Apple Health and was not edited since (`UserProfile.healthImported`).
    var healthImported: Set<String> = []

    /// "Import from Apple Health": fills what Health has and marks those fields as imported.
    mutating func importFromHealth(age: Int?, sex: String?, heightCm: Double?, weightKg: Double?) -> Int {
        var count = 0
        if let age { self.age = age; healthImported.insert(Field.age); count += 1 }
        if let sex, ["female", "male", "other"].contains(sex) { self.sex = sex; healthImported.insert(Field.sex); count += 1 }
        if let heightCm { self.heightCm = heightCm; healthImported.insert(Field.heightCm); count += 1 }
        if let weightKg { self.weightKg = weightKg; healthImported.insert(Field.weightKg); count += 1 }
        return count
    }

    init(profile: UserProfile? = nil, locale: Locale = .current) {
        name = profile?.name ?? ""
        age = profile?.age
        sex = profile?.sex
        heightCm = profile?.heightCm
        weightKg = profile?.weightKg
        units = profile?.units ?? Self.preferredUnits(for: locale)
        healthImported = profile?.healthImported ?? []
    }

    static func preferredUnits(for locale: Locale) -> UnitsPreference {
        locale.measurementSystem == .us ? .imperial : .metric
    }

    var heightDisplayValue: Int? {
        guard let heightCm else { return nil }
        return units == .metric ? Int(heightCm.rounded()) : Int((heightCm / 2.54).rounded())
    }

    var weightDisplayValue: Double? {
        guard let weightKg else { return nil }
        return units == .metric ? weightKg : weightKg * 2.2046226
    }

    mutating func setHeight(displayValue: Int?) {
        guard let displayValue else { heightCm = nil; return }
        heightCm = units == .metric ? Double(displayValue) : Double(displayValue) * 2.54
    }

    mutating func setWeight(displayValue: Double?) {
        guard let displayValue else { weightKg = nil; return }
        weightKg = units == .metric ? displayValue : displayValue / 2.2046226
    }

    func apply(to profile: UserProfile) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = trimmed.isEmpty ? nil : trimmed
        profile.age = age
        profile.sex = sex
        profile.heightCm = heightCm
        profile.weightKg = weightKg
        profile.healthImported = healthImported
        profile.units = units
        profile.updatedAt = AppClock.now
    }
}

struct GoalDraft: Equatable {
    static let recommendedDistanceMeters = 8_000.0

    var steps: Double = 10_000
    var distance: Double
    var calories: Double = 500
    var activeMinutes: Double = 45
    var sleepHours: Double = 8
    var workouts: Double = 4

    init(goal: UserGoal? = nil, units: UnitsPreference) {
        let metersPerUnit = Self.metersPerUnit(for: units)
        if let goal {
            steps = Double(goal.steps)
            distance = (goal.distanceMeters / metersPerUnit * 10).rounded() / 10
            calories = Double(goal.calories)
            activeMinutes = Double(goal.activeMinutes)
            sleepHours = Double(goal.sleepMinutes) / 60
            workouts = Double(goal.workoutsPerWeek)
        } else {
            distance = (Self.recommendedDistanceMeters / metersPerUnit * 10).rounded() / 10
        }
    }

    static func metersPerUnit(for units: UnitsPreference) -> Double {
        units == .metric ? 1_000 : 1_609.344
    }

    func apply(to goal: UserGoal, units: UnitsPreference, includeWeeklyWorkouts: Bool) {
        goal.steps = Int(steps)
        goal.distanceMeters = distance * Self.metersPerUnit(for: units)
        goal.calories = Int(calories)
        goal.activeMinutes = Int(activeMinutes)
        goal.sleepMinutes = Int(sleepHours * 60)
        if includeWeeklyWorkouts {
            goal.workoutsPerWeek = Int(workouts)
        }
        goal.updatedAt = AppClock.now
    }
}
