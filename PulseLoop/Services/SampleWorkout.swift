import Foundation
import SwiftData

/// The one workout the sample ("Explore without ring") data set carries: a 45-minute walk with a GPS route and a heart
/// rate that builds to about 128 bpm, so the Workouts list, the workout summary and its route map can be reviewed
/// without a ring. It mirrors the walk in the `hero` ring-emulator scenario (17:30, 45 min, peak near 128 bpm) and
/// is a port of Android's `SampleWorkout` (same route, same curve, same numbers).
///
/// **It follows the sample-data rules** (`SampleDataStore`):
///  * it is recognisable as sample data — `ActivitySession` has no source column, so the session id plays that part:
///    every id carries the `idPrefix` (`SampleWorkout.isSample`); the heart-rate rows are `mock` samples;
///  * it is **never exported or synced**: sample mode blocks Apple Health, the archive and the cloud as a whole
///    (`SampleDataStore.isActive`), and the id prefix additionally keeps it out of the Health workout export, the
///    Strava upload queue and the archive when the walk is present without sample mode (the store-capture run);
///  * it is **wiped** with the rest of the sample data (`SeedData.clearData`, which runs when a real ring connects);
///  * it adds **no** blood pressure, glucose, lipids, fatigue or temperature — heart rate only.
///
/// The numbers are built purely from `now` (`build`), so `SampleWorkoutTests` checks every property without a
/// database. The coordinates are synthetic (a fictional loop in open country); the map shows whatever the map
/// provider draws there.
enum SampleWorkout {
    /// First segment of every sample session id (`5A3D1E00-…`), and of nothing the app generates by itself.
    static let idPrefix = "5A3D1E00-"

    static let type = "walk"
    static let durationMinutes = 45
    static let startHour = 17
    static let startMinute = 30
    static let peakHeartRate = 128
    static let targetDistanceMeters = 4_200.0
    static let calories = 196.0
    private static let fixCount = 180          // one fix about every 15 s

    /// Synthetic centre of the loop (open country, no landmark).
    private static let originLat = 47.0
    private static let originLon = 8.0

    /// True for the sample workout's session id.
    nonisolated static func isSample(_ id: UUID) -> Bool { id.uuidString.hasPrefix(idPrefix) }
    nonisolated static func isSample(_ session: ActivitySession) -> Bool { isSample(session.id) }

    /// `5A3D1E00-0000-4000-8000-<start epoch seconds as 12 hex digits>`: valid, deterministic per start time, so
    /// seeding twice (or launching twice) never duplicates the walk.
    nonisolated static func sessionID(start: Date) -> UUID {
        let seconds = UInt64(max(0, start.timeIntervalSince1970))
        let text = idPrefix + "0000-4000-8000-" + String(format: "%012llX", seconds)
        return UUID(uuidString: text) ?? UUID()
    }

    struct Built {
        let session: ActivitySession
        let gpsPoints: [ActivityGpsPoint]
        let heartRate: [ActivitySample]
        let events: [ActivityEvent]
    }

    /// The walk that ended most recently before `now`: today at 17:30 when it has finished at least five minutes
    /// ago, otherwise yesterday at 17:30. (Under the hero clock, 19:30, that is today's walk.)
    nonisolated static func start(now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        func at(_ d: Date) -> Date {
            calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: d) ?? d
        }
        let today = at(day)
        let finishedBy = TimeInterval((durationMinutes + 5) * 60)
        if now >= today.addingTimeInterval(finishedBy) { return today }
        return at(calendar.date(byAdding: .day, value: -1, to: day) ?? day)
    }

    @MainActor
    static func build(now: Date, calendar: Calendar = .current) -> Built {
        let start = start(now: now, calendar: calendar)
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let id = sessionID(start: start)
        let gps = route(sessionId: id, start: start)
        let profile = ActivityTrackingProfile.profile(for: type)
        let distance = RouteDistanceEngine.distanceMeters(gps, profile: profile)

        let hr = (0...durationMinutes).map { minute in
            ActivitySample(sessionId: id, kind: MeasurementKind.heartRate.rawValue,
                           value: Double(heartRate(atMinute: minute)), unit: "bpm",
                           timestamp: start.addingTimeInterval(TimeInterval(minute * 60)), source: "mock")
        }
        let values = hr.map(\.value)
        let session = ActivitySession(id: id, type: type, status: .finished, startedAt: start, endedAt: end,
                                      calories: calories, distanceMeters: distance, notes: nil, useGps: true)
        session.avgHeartRate = (values.reduce(0, +) / Double(values.count)).rounded()
        session.minHeartRate = values.min()
        session.maxHeartRate = values.max()
        session.gpsPointCount = gps.count
        session.lastGpsPointAt = gps.last?.timestamp
        session.createdAt = end
        session.updatedAt = end
        return Built(session: session, gpsPoints: gps, heartRate: hr,
                     events: [ActivityEvent(sessionId: id, kind: "finished", timestamp: end)])
    }

    /// Insert the walk (session, route, heart rate, finish event). No-op when it is already there. With
    /// `creditActiveMinutes` the day's `ActivityDaily.activeMinutes` also gets the walk (the store-capture run on the
    /// ring emulator, where the ring reports no active minutes; the ring's own step/distance totals already contain
    /// the walk, so distance is not added). Sample mode passes `false`: its `ActivityDaily` rows are already seeded.
    /// The caller saves.
    @MainActor @discardableResult
    static func insert(into context: ModelContext, now: Date, creditActiveMinutes: Bool,
                       calendar: Calendar = .current) -> ActivitySession? {
        let id = sessionID(start: start(now: now, calendar: calendar))
        let existing = (try? context.fetchCount(FetchDescriptor<ActivitySession>(predicate: #Predicate { $0.id == id }))) ?? 0
        guard existing == 0 else { return nil }
        let walk = build(now: now, calendar: calendar)
        context.insert(walk.session)
        walk.gpsPoints.forEach(context.insert)
        walk.heartRate.forEach(context.insert)
        walk.events.forEach(context.insert)
        if creditActiveMinutes {
            let row: ActivityDaily
            if let day = MetricsRepository.activity(on: walk.session.startedAt, context: context) {
                row = day
            } else {
                row = ActivityDaily(date: walk.session.startedAt, source: "manual_recording")
                context.insert(row)
            }
            row.activeMinutes += durationMinutes
            row.updatedAt = AppClock.now
        }
        return walk.session
    }

    /// Beats per minute at `minute` of the walk: a warm-up ramp to `peakHeartRate` at minute 26, then an easing
    /// cool-down. Identical to Android's `SampleWorkout.heartRateAt`.
    nonisolated static func heartRate(atMinute minute: Int) -> Int {
        let m = min(max(minute, 0), durationMinutes)
        let base: Double
        if m <= 26 {
            base = 88.0 + Double(peakHeartRate - 88) * (1 - cos(Double.pi * Double(m) / 26.0)) / 2.0
        } else {
            let t = Double(m - 26) / Double(durationMinutes - 26)
            base = Double(peakHeartRate) - 16.0 * pow(t, 1.2)
        }
        let wobble = m == 26 ? 0.0 : sin(Double(m) * 1.7) * 2.0
        return min(peakHeartRate, max(60, Int((base + wobble).rounded())))
    }

    /// A loop of about `targetDistanceMeters` walked in `durationMinutes` minutes: a smooth closed curve, sampled at
    /// equal spacing, with the timing varied a little so the per-kilometre splits differ.
    @MainActor
    private static func route(sessionId: UUID, start: Date) -> [ActivityGpsPoint] {
        // Curve in metres, parameter 0..1 (stops short of closing, so start and end are distinct markers).
        func xy(_ u: Double) -> (Double, Double) {
            let a = 2 * Double.pi * 0.94 * u
            return (620 * cos(a) + 120 * cos(2 * a) + 40 * sin(3 * a),
                    420 * sin(a) + 90 * sin(2 * a) - 30 * cos(3 * a))
        }
        func dist(_ p: (Double, Double), _ q: (Double, Double)) -> Double {
            ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1)).squareRoot()
        }
        let samples = 2000
        let fine = (0...samples).map { xy(Double($0) / Double(samples)) }
        var cum = [Double](repeating: 0, count: fine.count)
        for i in 1..<fine.count { cum[i] = cum[i - 1] + dist(fine[i], fine[i - 1]) }
        let scale = targetDistanceMeters / cum[cum.count - 1]
        let cosLat = cos(originLat * Double.pi / 180)
        let duration = TimeInterval(durationMinutes * 60)
        var cursor = 0
        return (0...fixCount).map { i in
            let frac = Double(i) / Double(fixCount)
            let wanted = frac * cum[cum.count - 1]
            while cursor < cum.count - 2 && cum[cursor + 1] < wanted { cursor += 1 }
            let span = cum[cursor + 1] - cum[cursor] > 0 ? cum[cursor + 1] - cum[cursor] : 1.0
            let t = min(max((wanted - cum[cursor]) / span, 0), 1)
            let x = (fine[cursor].0 + (fine[cursor + 1].0 - fine[cursor].0) * t) * scale
            let y = (fine[cursor].1 + (fine[cursor + 1].1 - fine[cursor].1) * t) * scale
            // A steady pace with a slow surge and lull (monotonic: derivative >= 1 - 0.08*pi > 0).
            let time = (frac + 0.02 * sin(4 * Double.pi * frac)) * duration
            return ActivityGpsPoint(sessionId: sessionId,
                                    latitude: originLat + y / 111_320.0,
                                    longitude: originLon + x / (111_320.0 * cosLat),
                                    horizontalAccuracy: 5,
                                    timestamp: start.addingTimeInterval(time.rounded(.towardZero)),
                                    accepted: true)
        }
    }
}
