import Foundation

/// Compact context the model sees every turn — ports the web app's
/// CoachContextPacket (`backend/app/coach/context.py`). Deliberately small:
/// latest values + rollups + warnings. Dense arrays are never embedded; the
/// model fetches those on demand via tools.
///
/// Encoded camelCase → snake_case by the prompt builder so property names stay
/// idiomatic Swift while the wire shape matches the web contract.
nonisolated struct CoachContextPacket: Codable {
    var generatedAt: String
    var timezone: String
    var profile: ProfileContext
    var device: DeviceContext
    var goals: GoalContext
    var today: DayContext
    var lastSevenDays: WeekContext
    var latestVitals: VitalsContext
    var latestSleep: SleepContext?
    var recentWorkouts: [WorkoutContext]
    var memories: [MemoryContext]
    var conversationSummary: String?
    var dataQualityWarnings: [String]
    /// Opt-in city-level location + current weather. Nil when the toggle is off,
    /// permission is denied, or WeatherKit is unavailable. Raw coordinates NEVER
    /// appear here — only the reverse-geocoded city/region.
    var environment: EnvironmentContext?
    /// Opt-in nutrition tracking summary. Nil when the feature is off or the user
    /// doesn't share it with the coach — absent from the JSON entirely.
    var nutrition: NutritionContext?

    struct ProfileContext: Codable {
        var name: String?
        var age: Int?
        var sex: String?
        var heightCm: Double?
        var weightKg: Double?
        /// "metric" | "imperial" — the units the coach should answer in.
        var units: String
        /// "empty" | "partial" | "complete"
        var completeness: String
        /// Fields imported from Apple Health (`UserProfile.healthImported`): the on-device coach may use them; the cloud
        /// coach drops them (`CloudContextTrimmer`, `CloudToolOutputFilter`). Nil when none.
        var healthImported: [String]? = nil
    }

    struct DeviceContext: Codable {
        var name: String?
        var batteryPercent: Int?
        var state: String
        var lastConnectedAt: String?
        var lastSyncAt: String?
    }

    struct GoalContext: Codable {
        var stepsDaily: Int
        var activeMinutesDaily: Int
        var sleepHours: Double
        var exerciseDaysWeekly: Int
        // Nutrition intake goals (nil = not set; only present while nutrition is shared).
        var calorieIntakeDaily: Int?
        var proteinGDaily: Int?
        var carbsGDaily: Int?
        var fatGDaily: Int?
    }

    struct DayContext: Codable {
        var localDate: String
        var steps: Int?
        var calories: Double?
        var distanceKm: Double?
        var activeMinutes: Int?
        /// "none" | "low" | "medium" | "high"
        var dataConfidence: String
    }

    struct WeekContext: Codable {
        var daysAvailable: Int
        var avgSteps: Int?
        var totalSteps: Int?
        var activeMinutesTotal: Int?
        var exerciseDays: Int
        var mostActiveDay: String?
    }

    struct VitalsContext: Codable {
        var latestHr: Double?
        var latestHrAt: String?
        var latestSpo2: Double?
        var latestSpo2At: String?
        var restingHrEstimate: Double?
        var peakHrToday: Double?
    }

    struct SleepContext: Codable {
        var date: String
        /// **Last night's** asleep minutes: the main sleep's deep + light + REM. This is the number behind "how long did I
        /// sleep", and it is what the coach must quote for "last night".
        var nightMin: Int = 0
        /// REM minutes of the main sleep (already inside `nightMin`). The ring reports REM; the coach may name it.
        var remMin: Int = 0
        /// The waking day's asleep total (`SleepDayRule`: main sleep + naps). NOT last night — only "today's sleep".
        var dayTotalMin: Int
        var deepMin: Int
        var lightMin: Int
        var awakeMin: Int
        var score: Int?
        var confidence: String
        var decoderNote: String
        /// Minutes of the day's naps (included in `dayTotalMin`); nil when there were none.
        var napMin: Int? = nil
    }

    struct WorkoutContext: Codable {
        var id: String
        var type: String
        var startTime: String
        var durationMin: Double?
        var distanceKm: Double?
        var avgHr: Double?
        var status: String
    }

    struct MemoryContext: Codable {
        var type: String
        var key: String
        var value: String
        var importance: Int
    }

    /// Today's consumed nutrition + goals + meal list. Only present when the user
    /// enabled nutrition tracking AND sharing it with the coach.
    struct NutritionContext: Codable {
        var caloriesConsumed: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var mealsLoggedToday: Int
        var mealsToday: [MealBrief]
        var yesterdayCalories: Double?

        struct MealBrief: Codable {
            var mealId: String
            var name: String
            var mealType: String
            var time: String
            var kcal: Double
            /// "off_barcode" | "off_search" | "llm_estimate" | "manual"
            var source: String
        }
    }

    /// City-level location + current/forecast weather. City-only privacy: never a
    /// street, never coordinates. Any field may be nil when weather degrades to a
    /// city-only or stale result.
    struct EnvironmentContext: Codable {
        var city: String?
        var region: String?
        var tempC: Double?
        var condition: String?
        var highC: Double?
        var lowC: Double?
        var precipitationChancePct: Int?
        var sunrise: String?
        var sunset: String?
        var asOf: String
    }
}
