import Foundation

enum MetricKey: String, CaseIterable {
    case steps
    case heartRate = "hr"
    case spo2
    case sleep
    case calories
    case distance
    case activeMinutes = "active_minutes"
    case battery
    // an earlier ring metrics (capability-gated in the UI).
    case stress
    case hrv
    case temperature = "temp"
    // an earlier protocol metrics (capability-gated in the UI).
    case bloodPressureSystolic = "bp_sys"
    case bloodPressureDiastolic = "bp_dia"
    case fatigue
    case bloodSugar = "glucose"
    // Calorie-intake tracking. No wearable capability — gated instead on the
    // NutritionPrefs master toggle (see TodayStore / TodaySettingsView).
    case nutrition
    // Agara ring DF history series (measure-hub spec §5). `bloodComponents` is the one Vitals card for the
    // five estimates (a card id, like `nutrition`); the five keys below it are their stored series.
    case respiratoryRate = "resp_rate"
    case met
    case cardiacLoad = "cardiac_load"
    case bloodComponents = "blood_components"
    case totalCholesterol = "total_cholesterol"
    case triglycerides
    case hdl
    case ldl
    case uricAcid = "uric_acid"

    /// The wearable capability that must be present for this metric to be shown.
    var requiredCapability: WearableCapability? {
        switch self {
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .stress: return .stress
        case .hrv: return .hrv
        case .temperature: return .temperature
        case .bloodPressureSystolic, .bloodPressureDiastolic: return .bloodPressure
        case .fatigue: return .fatigue
        case .bloodSugar: return .bloodSugar
        case .steps, .calories, .distance, .activeMinutes: return .steps
        case .sleep: return .sleep
        case .battery: return .battery
        case .nutrition: return nil
        case .respiratoryRate: return .respiration
        case .met: return .met
        case .cardiacLoad: return .cardiacLoad
        case .bloodComponents, .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid: return .bloodComponents
        }
    }

    /// The feature flag that must be on for this metric's card to show (`docs/config/features.yaml`).
    /// The data is stored regardless — the flag only gates the UI.
    var requiredFeature: AgaraFeature? {
        switch self {
        case .respiratoryRate: return .vitalsRespiration
        case .met: return .vitalsMet
        case .cardiacLoad: return .vitalsCardiacLoad
        case .bloodComponents, .totalCholesterol, .triglycerides, .hdl, .ldl, .uricAcid: return .bloodComponents
        default: return nil
        }
    }

    /// Capability gate against an already-fetched capability set. `MetricsService.supports` reads the
    /// same answer from the DB; views that hold a cached snapshot use this so a `body` re-render never
    /// triggers a fetch.
    func isSupported(by capabilities: Set<WearableCapability>) -> Bool {
        if let feature = requiredFeature, !AgaraFeatureStore.isOn(feature) { return false }
        guard let required = requiredCapability else { return true }
        return capabilities.contains(required)
    }
}

// `MetricRange` lives in ChartSample.swift (shared with the widget extension).

enum SleepRangeKey: String, CaseIterable {
    case day
    case week
    case month
    case year
}

enum DataFreshness: String {
    case live
    case syncedToday = "synced_today"
    case stale
    case missing
    case demo
    case calibrating
    case experimental
}

enum MetricConfidence: String {
    case high
    case medium
    case low
    case partial
    case experimental
}

struct MetricSample: Identifiable {
    /// Stable across recomputes (a fresh `UUID()` per build made every chart diff treat every point as
    /// new, re-animating and re-laying out the whole series on each data batch).
    var id: String { "\(timestamp.timeIntervalSince1970)|\(value)" }
    let timestamp: Date
    let value: Double
}

struct DailyMetricPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct MetricState {
    let freshness: DataFreshness
    let confidence: MetricConfidence
    let source: String?
    let sampleCount: Int
    let requiredSamples: Int
    let lastUpdatedAt: Date?
    let status: String
    let zeroIsReal: Bool
}

struct CalibrationState {
    let isCalibrating: Bool
    let day: Int
    let totalDays: Int
    let startedAt: Date?
    let reason: String
}

struct GoalsSummary {
    let stepsDaily: Int
    let activeMinutesDaily: Int
    let sleepHours: Double
    let exerciseDaysWeekly: Int
    let distanceMetersDaily: Double
    /// Daily active-energy *burn* goal (kcal) — not intake.
    let caloriesDaily: Int
    // Nutrition intake goals (nil = not set — the app never invents a target).
    var intakeCalories: Int? = nil
    var intakeProteinG: Int? = nil
    var intakeCarbsG: Int? = nil
    var intakeFatG: Int? = nil
}

struct TrendsSummary {
    let steps7d: [DailyMetricPoint]
    let calories7d: [DailyMetricPoint]
    let distance7d: [DailyMetricPoint]
    let hrSamples24h: [MetricSample]
    let spo2Samples24h: [MetricSample]
}

struct SleepSummary {
    let session: SleepSession
    let lightMinutes: Int
    let deepMinutes: Int
    let awakeMinutes: Int
    let blocks: [SleepStageBlock]
    /// REM minutes carried by a summary whose blocks were dropped (range views keep only the totals).
    var remMinutesWithoutBlocks: Int? = nil

    /// REM minutes from the stage blocks (the Agara ring reports REM: A5 bitmap code 2, A3 offset 23).
    /// Deep + light + REM + awake adds up to the time in bed.
    var remMinutes: Int {
        if blocks.isEmpty, let remMinutesWithoutBlocks { return remMinutesWithoutBlocks }
        return blocks.filter { $0.stage == .rem }.reduce(0) { $0 + $1.durationMinutes }
    }
}

struct SleepRangeSummary {
    let range: SleepRangeKey
    let start: Date
    let end: Date
    let expectedNights: Int
    let sessions: [SleepSummary]
    
    var hasData: Bool { !sessions.isEmpty }
    
    var averageTotalMinutes: Int? {
        guard !sessions.isEmpty else { return nil }
        return sessions.reduce(0) { $0 + $1.session.totalMinutes } / sessions.count
    }
}

struct ActivitySessionSummary {
    let session: ActivitySession
    let durationSeconds: Int?
    let distanceMeters: Double?
    let calories: Double?
    let averageHeartRate: Double?
    let minHeartRate: Double?
    let maxHeartRate: Double?
    let averageSpO2: Double?
    let latestSpO2: Double?
    let heartRateSampleCount: Int
    let spo2SampleCount: Int
}

struct ActiveMinutesResult {
    let minutes: Int
    let source: String
}

struct ActivityDailyUpdate {
    let date: Date
    let steps: Int?
    let calories: Double?
    let distanceMeters: Double?
    let activeMinutes: Int?
    let source: String
    let syncedAt: Date?
    
    init(
        date: Date,
        steps: Int? = nil,
        calories: Double? = nil,
        distanceMeters: Double? = nil,
        activeMinutes: Int? = nil,
        source: String = "sync",
        syncedAt: Date? = Date()
    ) {
        self.date = date
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
        self.source = source
        self.syncedAt = syncedAt
    }
}

/// A flattened snapshot of one "latest" measurement reading. Holds plain values (no live
/// SwiftData object) so a `TodaySummary` can be cached and passed around safely.
struct LatestReading: Equatable {
    var value: Double
    var timestamp: Date
    var sourceRaw: String
    var confidenceRaw: String

    init(value: Double, timestamp: Date, sourceRaw: String, confidenceRaw: String) {
        self.value = value
        self.timestamp = timestamp
        self.sourceRaw = sourceRaw
        self.confidenceRaw = confidenceRaw
    }

    init?(_ measurement: Measurement?) {
        guard let m = measurement else { return nil }
        self.value = m.value
        self.timestamp = m.timestamp
        self.sourceRaw = m.sourceRaw
        self.confidenceRaw = m.confidenceRaw
    }
}

struct TodaySummary {
    var date: Date
    var steps: Int?
    /// Display value: device-reported, or the estimated TOTAL burn (BMR + net active).
    var calories: Double?
    /// Active-energy portion (device value or net estimate) — what the calorie goal ring measures.
    var activeCalories: Double?
    var distanceMeters: Double?
    var activeMinutes: Int?
    var activeMinutesSource: String
    var latestHeartRate: LatestReading?
    var latestSpO2: LatestReading?
    var restingHeartRateEstimate: Double?
    var peakHeartRateToday: Double?
    var sleep: SleepSummary?
    var batteryPercent: Int?
    var deviceState: RingConnectionState
    var trends: TrendsSummary
    var metricStates: [MetricKey: MetricState]
    var calibration: CalibrationState
    var goals: GoalsSummary
    var isDemo: Bool
    /// Consumed nutrition for the day. nil when the nutrition feature is disabled.
    var nutrition: NutritionDayTotals? = nil

    var sevenDaySteps: [DailyMetricPoint] { trends.steps7d }
}
