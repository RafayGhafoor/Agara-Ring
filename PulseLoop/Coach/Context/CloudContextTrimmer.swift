import Foundation

/// The `context` object of one Agara Cloud coach turn — exactly what contract §5 of
/// `docs/ring/coach-proxy.md` allows to leave the device, and nothing else.
///
/// Built by an explicit field-by-field projection from `CoachContextPacket`, never by encoding the
/// packet and deleting keys. That direction matters: a field added to the packet later (or a future
/// HealthKit import) cannot reach the cloud by accident — it only travels once it is added here *and*
/// to the contract. Fields removed by construction, so they cannot leak:
///
/// * `profile.name` (the contract's "never sent" list) — the model addresses the user without a name;
/// * `profile.completeness`, `device.state`, `device.lastConnectedAt` — internal bookkeeping, not in §5;
/// * `timezone` — a coarse location proxy that §5 does not list; `today.local_date` already tells the
///   model which local day it is looking at;
/// * `conversationSummary` — it travels as the turn's `summary` field instead (§6);
/// * the whole `environment` block — city, region and anything WeatherKit-derived. §5 sends it only
///   for users who opted in; the cloud coach does not send it at all;
/// * workout ids, distance, average HR and status — §5 sends "recent workouts (type/start/duration
///   only)", which is also how a HealthKit-sourced workout would have to arrive (distance/HR samples
///   are the only HealthKit-reachable values in the app), so they are dropped here.
///
/// HealthKit: `HealthSyncService` is write-only (`readTypes` is empty apart from the profile
/// characteristics the user confirms), so no HealthKit sample exists in the store for the packet to
/// carry. The projection above is what keeps it that way — `CloudContextTrimmerTests` pins the encoded
/// key set, so a new field fails the test instead of shipping.
nonisolated struct CoachCloudContext: Encodable, Equatable {
    var generatedAt: String
    var profile: Profile
    var device: Device
    var goals: Goals
    var today: Today
    var lastSevenDays: Week
    var latestVitals: Vitals
    var latestSleep: Sleep?
    var recentWorkouts: [Workout]
    var memories: [Memory]
    var dataQualityWarnings: [String]
    var nutrition: Nutrition?

    /// §5: age as an integer, sex, height, weight rounded to 0.5 kg, units. No name, no email.
    struct Profile: Encodable, Equatable {
        var age: Int?
        var sex: String?
        var heightCm: Double?
        var weightKg: Double?
        var units: String
    }

    /// §5: device name, battery, last sync — nothing about the connection or its history.
    struct Device: Encodable, Equatable {
        var name: String?
        var batteryPercent: Int?
        var lastSyncAt: String?
    }

    struct Goals: Encodable, Equatable {
        var stepsDaily: Int
        var activeMinutesDaily: Int
        var sleepHours: Double
        var exerciseDaysWeekly: Int
        var calorieIntakeDaily: Int?
        var proteinGDaily: Int?
        var carbsGDaily: Int?
        var fatGDaily: Int?
    }

    struct Today: Encodable, Equatable {
        var localDate: String
        var steps: Int?
        var calories: Double?
        var distanceKm: Double?
        var activeMinutes: Int?
        var dataConfidence: String
    }

    struct Week: Encodable, Equatable {
        var daysAvailable: Int
        var avgSteps: Int?
        var totalSteps: Int?
        var activeMinutesTotal: Int?
        var exerciseDays: Int
        var mostActiveDay: String?
    }

    struct Vitals: Encodable, Equatable {
        var latestHr: Double?
        var latestHrAt: String?
        var latestSpo2: Double?
        var latestSpo2At: String?
        var restingHrEstimate: Double?
        var peakHrToday: Double?
    }

    struct Sleep: Encodable, Equatable {
        var date: String
        var totalMin: Int
        var deepMin: Int
        var lightMin: Int
        var awakeMin: Int
        var score: Int?
        var confidence: String
        var decoderNote: String
        var napMin: Int?
    }

    /// §5: "type/start/duration only" — the model asks `get_activity_sessions` when it needs more.
    struct Workout: Encodable, Equatable {
        var type: String
        var startTime: String
        var durationMin: Double?
    }

    struct Memory: Encodable, Equatable {
        var type: String
        var key: String
        var value: String
        var importance: Int
    }

    /// Present only when nutrition tracking is on *and* shared with the coach (contract §5). The meal
    /// ids stay because the edit/delete meal tools address a meal by id; they are row ids, not device
    /// or account identifiers.
    struct Nutrition: Encodable, Equatable {
        var caloriesConsumed: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var mealsLoggedToday: Int
        var mealsToday: [Meal]
        var yesterdayCalories: Double?

        struct Meal: Encodable, Equatable {
            var mealId: String
            var name: String
            var mealType: String
            var time: String
            var kcal: Double
            var source: String
        }
    }
}

/// Turns the on-device packet into the trimmed cloud payload (`CoachCloudContext`), and encodes it as
/// the `context` of a coach turn request.
nonisolated enum CloudContextTrimmer {
    /// Weights leave at half-kilo resolution: `72.3 kg` → `72.5 kg`, so the scale reading itself never
    /// goes out while advice can still use a real number.
    static func roundWeight(_ weightKg: Double?) -> Double? {
        guard let weightKg else { return nil }
        return (weightKg * 2).rounded() / 2
    }

    /// A profile value imported from Apple Health never goes to the cloud coach (consent: "never … anything from Apple
    /// Health that another app recorded"; a smart scale's weight would otherwise leave through us).
    private static func fromHealth(_ packet: CoachContextPacket, _ field: String) -> Bool {
        packet.profile.healthImported?.contains(field) ?? false
    }

    static func build(_ packet: CoachContextPacket) -> CoachCloudContext {
        CoachCloudContext(
            generatedAt: packet.generatedAt,
            profile: CoachCloudContext.Profile(
                age: fromHealth(packet, "age") ? nil : packet.profile.age,
                sex: fromHealth(packet, "sex") ? nil : packet.profile.sex,
                heightCm: fromHealth(packet, "height_cm") ? nil : packet.profile.heightCm,
                weightKg: fromHealth(packet, "weight_kg") ? nil : roundWeight(packet.profile.weightKg),
                units: packet.profile.units
            ),
            device: CoachCloudContext.Device(
                name: packet.device.name,
                batteryPercent: packet.device.batteryPercent,
                lastSyncAt: packet.device.lastSyncAt
            ),
            goals: CoachCloudContext.Goals(
                stepsDaily: packet.goals.stepsDaily,
                activeMinutesDaily: packet.goals.activeMinutesDaily,
                sleepHours: packet.goals.sleepHours,
                exerciseDaysWeekly: packet.goals.exerciseDaysWeekly,
                calorieIntakeDaily: packet.goals.calorieIntakeDaily,
                proteinGDaily: packet.goals.proteinGDaily,
                carbsGDaily: packet.goals.carbsGDaily,
                fatGDaily: packet.goals.fatGDaily
            ),
            today: CoachCloudContext.Today(
                localDate: packet.today.localDate,
                steps: packet.today.steps,
                calories: packet.today.calories,
                distanceKm: packet.today.distanceKm,
                activeMinutes: packet.today.activeMinutes,
                dataConfidence: packet.today.dataConfidence
            ),
            lastSevenDays: CoachCloudContext.Week(
                daysAvailable: packet.lastSevenDays.daysAvailable,
                avgSteps: packet.lastSevenDays.avgSteps,
                totalSteps: packet.lastSevenDays.totalSteps,
                activeMinutesTotal: packet.lastSevenDays.activeMinutesTotal,
                exerciseDays: packet.lastSevenDays.exerciseDays,
                mostActiveDay: packet.lastSevenDays.mostActiveDay
            ),
            latestVitals: CoachCloudContext.Vitals(
                latestHr: packet.latestVitals.latestHr,
                latestHrAt: packet.latestVitals.latestHrAt,
                latestSpo2: packet.latestVitals.latestSpo2,
                latestSpo2At: packet.latestVitals.latestSpo2At,
                restingHrEstimate: packet.latestVitals.restingHrEstimate,
                peakHrToday: packet.latestVitals.peakHrToday
            ),
            latestSleep: packet.latestSleep.map { sleep in
                CoachCloudContext.Sleep(
                    date: sleep.date,
                    totalMin: sleep.totalMin,
                    deepMin: sleep.deepMin,
                    lightMin: sleep.lightMin,
                    awakeMin: sleep.awakeMin,
                    score: sleep.score,
                    confidence: sleep.confidence,
                    decoderNote: sleep.decoderNote,
                    napMin: sleep.napMin
                )
            },
            recentWorkouts: packet.recentWorkouts.map {
                CoachCloudContext.Workout(type: $0.type, startTime: $0.startTime, durationMin: $0.durationMin)
            },
            memories: packet.memories.map {
                CoachCloudContext.Memory(type: $0.type, key: $0.key, value: $0.value, importance: $0.importance)
            },
            dataQualityWarnings: packet.dataQualityWarnings,
            nutrition: packet.nutrition.map { nutrition in
                CoachCloudContext.Nutrition(
                    caloriesConsumed: nutrition.caloriesConsumed,
                    proteinG: nutrition.proteinG,
                    carbsG: nutrition.carbsG,
                    fatG: nutrition.fatG,
                    mealsLoggedToday: nutrition.mealsLoggedToday,
                    mealsToday: nutrition.mealsToday.map {
                        .init(
                            mealId: $0.mealId, name: $0.name, mealType: $0.mealType,
                            time: $0.time, kcal: $0.kcal, source: $0.source
                        )
                    },
                    yesterdayCalories: nutrition.yesterdayCalories
                )
            }
        )
    }

    /// The `context` value for a turn request. Snake_case on the wire, like every other coach payload.
    static func encode(_ packet: CoachContextPacket) -> [String: Any] {
        guard let data = try? encoder.encode(build(packet)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

/// Contract §5 applied to **tool results** — the second channel to the server. The packet above is trimmed by
/// construction; a tool result is whatever a tool returns, and tools are written for the on-device coach too
/// (`get_profile_context` returns the profile name; activity tools return the user's free-text notes). Every tool
/// result on its way to the Agara proxy passes through `sanitize` (`CoachCloudRequest.continuationBody`), so a tool
/// added later cannot reopen the hole. Found and fixed 2026-10-22 (pre-TestFlight wire audit).
nonisolated enum CloudToolOutputFilter {
    /// Keys never sent, at any depth (§5: email, city/region, coordinates, free-text notes, account identifiers).
    /// `note` (singular) is NOT here: the tools use it for system remarks ("experimental decoder (no REM)").
    static let neverKeys: Set<String> = [
        "notes", "email", "city", "region", "latitude", "longitude", "coordinates",
        "uid", "user_id", "firebase_uid",
    ]

    static func sanitize(_ value: Any) -> Any { sanitize(value, parent: nil) }

    private static func sanitize(_ value: Any, parent: String?) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            // A profile names the fields that came from Apple Health; those, and the list itself, stay on the phone.
            let fromHealth = parent == "profile"
                ? Set((object["health_imported"] as? [String]) ?? (object["healthImported"] as? [String]) ?? []) : []
            for (key, child) in object where !neverKeys.contains(key) && !fromHealth.contains(key) {
                if parent == "profile" {
                    // The person's name never leaves; the weight leaves at half-kilo resolution like the packet's.
                    if key == "name" || key == "health_imported" || key == "healthImported" { continue }
                    if key == "weight_kg", let kg = (child as? NSNumber)?.doubleValue {
                        out[key] = (kg * 2).rounded() / 2
                        continue
                    }
                }
                out[key] = sanitize(child, parent: key)
            }
            return out
        }
        if let array = value as? [Any] { return array.map { sanitize($0, parent: parent) } }
        return value
    }
}
