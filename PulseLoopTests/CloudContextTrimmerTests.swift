import Foundation
import XCTest
@testable import PulseLoop

/// Cloud payload trimming (contract `docs/ring/coach-proxy.md` §5): the context that leaves the device
/// is an explicit projection, so personal identifiers, location and HealthKit-reachable values cannot
/// ride along — and a field added to `CoachContextPacket` later fails these tests instead of shipping.
final class CloudContextTrimmerTests: XCTestCase {
    // MARK: - Fixture

    private func packet(
        name: String? = "Ayesha Khan",
        weightKg: Double? = 72.3,
        age: Int? = 34,
        environment: CoachContextPacket.EnvironmentContext? = .init(
            city: "Lahore", region: "Punjab", tempC: 31, condition: "Hazy",
            highC: 34, lowC: 26, precipitationChancePct: 10, sunrise: "06:10", sunset: "17:52",
            asOf: "2026-10-20T07:00:00Z"),
        conversationSummary: String? = "Earlier: ayesha.khan@example.com asked about sleep."
    ) -> CoachContextPacket {
        CoachContextPacket(
            generatedAt: "2026-10-20T07:12:00Z",
            timezone: "Asia/Karachi",
            profile: .init(
                name: name, age: age, sex: "female", heightCm: 165, weightKg: weightKg,
                units: "metric", completeness: "complete"),
            device: .init(
                name: "Agara Ring", batteryPercent: 82, state: "connected",
                lastConnectedAt: "2026-10-20T07:00:00Z", lastSyncAt: "2026-10-20T07:05:00Z"),
            goals: .init(
                stepsDaily: 9000, activeMinutesDaily: 30, sleepHours: 8, exerciseDaysWeekly: 4,
                calorieIntakeDaily: nil, proteinGDaily: nil, carbsGDaily: nil, fatGDaily: nil),
            today: .init(
                localDate: "2026-10-20", steps: 4120, calories: 1810, distanceKm: 3.1,
                activeMinutes: 22, dataConfidence: "high"),
            lastSevenDays: .init(
                daysAvailable: 7, avgSteps: 8400, totalSteps: 58800, activeMinutesTotal: 190,
                exerciseDays: 4, mostActiveDay: "2026-10-18 (11200 steps)"),
            latestVitals: .init(
                latestHr: 71, latestHrAt: "2026-10-20T07:10:00Z", latestSpo2: 97,
                latestSpo2At: "2026-10-20T07:10:00Z", restingHrEstimate: 58, peakHrToday: 128),
            latestSleep: .init(
                date: "2026-10-20", totalMin: 402, deepMin: 78, lightMin: 300, awakeMin: 24,
                score: 76, confidence: "medium", decoderNote: "No REM stage decoded.", napMin: nil),
            recentWorkouts: [
                .init(
                    id: "0F2B7A0C-1111-2222-3333-444455556666", type: "walking",
                    startTime: "2026-10-18T17:30:00Z", durationMin: 34.5,
                    distanceKm: 2.87, avgHr: 118, status: "finished"),
            ],
            memories: [.init(type: "goal", key: "sleep_target", value: "In bed before 23:00", importance: 4)],
            conversationSummary: conversationSummary,
            dataQualityWarnings: ["Only 7 days of history"],
            environment: environment,
            nutrition: nil
        )
    }

    private func encode(_ packet: CoachContextPacket) -> [String: Any] {
        CloudContextTrimmer.encode(packet)
    }

    private func jsonString(_ packet: CoachContextPacket) -> String {
        guard let data = try? CloudContextTrimmer.encoder.encode(CloudContextTrimmer.build(packet)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Nothing personal leaves

    func testEncodedPayloadCarriesNoNameEmailOrCity() {
        let json = jsonString(packet())
        for identifier in ["Ayesha", "ayesha", "Khan", "@example.com", "Lahore", "Punjab", "Karachi", "Asia/"] {
            XCTAssertFalse(json.contains(identifier), "cloud context leaked \(identifier): \(json)")
        }
    }

    func testEnvironmentBlockIsNeverSentEvenWhenThePacketHasIt() {
        let context = encode(packet())
        XCTAssertNil(context["environment"])
        // Weather, sunrise and the city-level fields all came with the block.
        let json = jsonString(packet())
        XCTAssertFalse(json.contains("Hazy"))
        XCTAssertFalse(json.contains("06:10"))
    }

    func testProfileSendsAgeAsIntegerAndWeightToHalfAKilo() {
        let context = encode(packet(weightKg: 72.3))
        let profile = context["profile"] as? [String: Any]
        XCTAssertEqual(profile?["age"] as? Int, 34)
        XCTAssertEqual(profile?["weight_kg"] as? Double, 72.5)
        XCTAssertEqual(profile?["height_cm"] as? Double, 165)
        XCTAssertEqual(profile?["units"] as? String, "metric")
        XCTAssertEqual(profile?["sex"] as? String, "female")
        XCTAssertNil(profile?["name"])
        XCTAssertNil(profile?["completeness"])
    }

    func testWeightRoundingToNearestHalfKilo() {
        XCTAssertEqual(CloudContextTrimmer.roundWeight(72.3), 72.5)
        XCTAssertEqual(CloudContextTrimmer.roundWeight(72.2), 72.0)
        XCTAssertEqual(CloudContextTrimmer.roundWeight(72.25), 72.5)
        XCTAssertEqual(CloudContextTrimmer.roundWeight(81.74), 81.5)
        XCTAssertNil(CloudContextTrimmer.roundWeight(nil))
    }

    /// HealthKit-reachable values are distance and workout heart rate (HealthSyncService writes them
    /// out; nothing else could carry an external sample). §5 sends "type/start/duration only", so they
    /// are dropped — and the equivalent top-level keys of the averaging blocks are pinned below.
    func testWorkoutsSendOnlyTypeStartAndDuration() {
        let context = encode(packet())
        let workouts = context["recent_workouts"] as? [[String: Any]]
        let workout = try? XCTUnwrap(workouts?.first)
        XCTAssertEqual(Set(workout?.keys.map { $0 } ?? []), ["type", "start_time", "duration_min"])
        XCTAssertEqual(workout?["duration_min"] as? Double, 34.5)
        let json = jsonString(packet())
        XCTAssertFalse(json.contains("2.87"), "workout distance leaked: \(json)")
        XCTAssertFalse(json.contains("118"), "workout average HR leaked: \(json)")
        XCTAssertFalse(json.contains("0F2B7A0C-1111-2222-3333-444455556666"), "workout id leaked: \(json)")
        XCTAssertFalse(json.contains("finished"))
    }

    // MARK: - Allowlist, so an unknown field can never travel

    func testTopLevelKeySetIsTheContractAllowlist() {
        let context = encode(packet())
        XCTAssertEqual(
            Set(context.keys),
            [
                "generated_at", "profile", "device", "goals", "today", "last_seven_days",
                "latest_vitals", "latest_sleep", "recent_workouts", "memories", "data_quality_warnings",
            ]
        )
        XCTAssertNil(context["conversation_summary"])
    }

    /// §5 sends the device name, and a user can name the ring after themselves or put an instruction in
    /// it — which is why the server prompt treats it as data. Everything else the app knows about the
    /// connection stays home.
    func testDeviceSendsNameBatteryAndLastSyncOnly() {
        let device = encode(packet())["device"] as? [String: Any]
        XCTAssertEqual(Set(device?.keys.map { $0 } ?? []), ["name", "battery_percent", "last_sync_at"])
        XCTAssertEqual(device?["name"] as? String, "Agara Ring")
        XCTAssertEqual(device?["battery_percent"] as? Int, 82)
    }

    func testEmptyPacketStillEncodesTheAllowlistWithoutNutrition() {
        var sparse = packet(name: nil, weightKg: nil, age: nil, environment: nil, conversationSummary: nil)
        sparse.latestSleep = nil
        sparse.recentWorkouts = []
        sparse.memories = []
        sparse.dataQualityWarnings = []
        let context = encode(sparse)
        // An absent optional block is omitted, not sent as null (the server ignores unknown keys).
        XCTAssertEqual(
            Set(context.keys),
            [
                "generated_at", "profile", "device", "goals", "today", "last_seven_days",
                "latest_vitals", "recent_workouts", "memories", "data_quality_warnings",
            ]
        )
        let profile = context["profile"] as? [String: Any]
        XCTAssertEqual(Set(profile?.keys.map { $0 } ?? []), ["sex", "height_cm", "units"])
    }

    func testNutritionIsSentOnlyWhenThePacketCarriesIt() {
        var withNutrition = packet()
        withNutrition.nutrition = .init(
            caloriesConsumed: 1420, proteinG: 71, carbsG: 160, fatG: 48, mealsLoggedToday: 1,
            mealsToday: [
                .init(
                    mealId: "AB12", name: "Oatmeal with berries", mealType: "breakfast",
                    time: "07:40", kcal: 380, source: "off_search"),
            ],
            yesterdayCalories: 2100)
        let nutrition = encode(withNutrition)["nutrition"] as? [String: Any]
        XCTAssertEqual(nutrition?["calories_consumed"] as? Double, 1420)
        let meal = (nutrition?["meals_today"] as? [[String: Any]])?.first
        XCTAssertEqual(meal?["meal_id"] as? String, "AB12", "meal ids stay: the edit/delete meal tools need them")
        XCTAssertNil(encode(packet())["nutrition"])
    }
}
