import Foundation
import SwiftData
import os

/// Pushes the app's local rows to — and pulls the signed-in user's rows from — the Agara
/// PocketBase instance. Following the app's own rules of idempotency:
///
/// - `health_days` is one record per (user, date) — unique index on the server; upsert by day.
/// - `measurements` is one record per (user, client_key) where `client_key` is
///   `"<kind>-<epoch>-<source>"`, so re-syncs never duplicate a reading.
///
/// Pull replays cloud rows through the same `RingEventBridge` → persistence path the BLE sync and
/// the one-time backfill use, so the data lands with the standard dedup and sanity gates.
@MainActor
final class AgaraCloudSync {
    static let shared = AgaraCloudSync()
    private let client = AgaraCloudClient.shared
    private static let log = Logger(subsystem: "com.pulseloop.lab", category: "agara-sync")

    // MARK: Push

    /// Push the last `days` days of activity/sleep plus up to `maxMeasurements` recent readings.
    /// Returns the counts pushed. Skipped entirely when nobody is signed in.
    func push(context: ModelContext, days: Int = AgaraConfig.Cloud.pushDays, maxMeasurements: Int = AgaraConfig.Cloud.pushMaxMeasurements) async throws -> (days: Int, measurements: Int) {
        guard client.isSignedIn, let userID = client.userID else { return (0, 0) }

        var pushedDays = 0
        let existingDays = try await client.list(AgaraConfig.Cloud.healthDaysCollection, filter: "user='\(userID)'")
        let dayDates = existingDays.compactMap { $0["date"] as? String }
        // Fold rather than `Dictionary(uniqueKeysWithValues:)`: that initialiser **traps** on a
        // duplicate key, so one duplicated row on the server (a race between two devices pushing the
        // same day) would crash the app instead of being an idempotent upsert.
        var dayByDate: [String: String] = [:]
        for record in existingDays {
            guard let date = record["date"] as? String, let id = record["id"] as? String else { continue }
            dayByDate[date] = id
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let activityRows = try context.fetch(FetchDescriptor<ActivityDaily>())
            .filter { $0.date >= cutoff }
        // Defensive dedupe by day: the app can hold more than one ActivityDaily row per date
        // (ring sync + live ratchet can each write one), and the server's (user, date) index is
        // unique — last row wins locally, so last row wins here too.
        var activityByDay: [String: ActivityDaily] = [:]
        for row in activityRows { activityByDay[Self.dayString(row.date)] = row }

        var pushedMeasurements = 0
        let existingMeasurements = try await client.list(AgaraConfig.Cloud.measurementsCollection, filter: "user='\(userID)'")
        let measurementKeys = Set(existingMeasurements.compactMap { $0["client_key"] as? String })
        var measurementByKey: [String: String] = [:]
        for record in existingMeasurements {
            guard let key = record["client_key"] as? String, let id = record["id"] as? String else { continue }
            measurementByKey[key] = id
        }

        for (dateString, day) in activityByDay {
            let sleep = sleepSummary(for: day.date, context: context)
            let body: [String: Any] = [
                "user": userID, "date": dateString,
                "steps": day.steps,
                "distance_km": day.distanceMeters / 1000,
                "calories": day.calories,
                "sleep_start": sleep.map { Int($0.startAt.timeIntervalSince1970) } ?? 0,
                "sleep_end": sleep.map { Int($0.endAt.timeIntervalSince1970) } ?? 0,
                "deep": sleep?.deep ?? 0,
                "light": sleep?.light ?? 0,
                "awake": sleep?.awake ?? 0,
                "other": sleep?.other ?? 0,
                "quality": sleep?.quality ?? 0,
            ]
            if let existingID = dayByDate[dateString] {
                try await client.update(AgaraConfig.Cloud.healthDaysCollection, recordID: existingID, body: body)
            } else if !dayDates.contains(dateString) {
                try await client.create(AgaraConfig.Cloud.healthDaysCollection, body: body)
            }
            pushedDays += 1
        }

        let measurements = try context.fetch(
            FetchDescriptor<Measurement>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        ).prefix(maxMeasurements)
        // Dedupe by client key (kind+epoch+source), newest first — same unique-index protection as
        // the day dedupe above.
        var measurementsByKey: [String: Measurement] = [:]
        for measurement in measurements {
            let key = "\(measurement.kind.rawValue)-\(Int(measurement.timestamp.timeIntervalSince1970))-\(measurement.sourceRaw)"
            if measurementsByKey[key] == nil { measurementsByKey[key] = measurement }
        }
        for (key, measurement) in measurementsByKey {
            let body: [String: Any] = [
                "user": userID, "kind": measurement.kind.rawValue,
                "value": measurement.value, "unit": measurement.unit,
                "timestamp": Int(measurement.timestamp.timeIntervalSince1970),
                "source": measurement.sourceRaw, "client_key": key,
            ]
            if let existingID = measurementByKey[key] {
                try await client.update(AgaraConfig.Cloud.measurementsCollection, recordID: existingID, body: body)
            } else if !measurementKeys.contains(key) {
                try await client.create(AgaraConfig.Cloud.measurementsCollection, body: body)
            }
            pushedMeasurements += 1
        }
        Self.log.info("pushed \(pushedDays) days, \(pushedMeasurements) measurements")
        return (pushedDays, pushedMeasurements)
    }

    // MARK: Pull

    /// Pull the signed-in user's cloud rows and replay them as ring events so they persist exactly
    /// like local sync. Returns the number of days pulled.
    @discardableResult
    func pull(context: ModelContext) async throws -> Int {
        guard client.isSignedIn, let userID = client.userID else { return 0 }
        let days = try await client.list(AgaraConfig.Cloud.healthDaysCollection, filter: "user='\(userID)'")
        let measurements = try await client.list(AgaraConfig.Cloud.measurementsCollection, filter: "user='\(userID)'")

        let calendar = Calendar.current
        var events: [RingDecodedEvent] = []
        for day in days {
            guard let dateString = day["date"] as? String else { continue }
            guard let date = Self.date(from: dateString, calendar: calendar) else { continue }
            let steps = (day["steps"] as? NSNumber)?.intValue ?? 0
            let distanceKm = (day["distance_km"] as? NSNumber)?.doubleValue ?? 0
            let calories = (day["calories"] as? NSNumber)?.doubleValue ?? 0
            events.append(.activityUpdate(
                timestamp: date, steps: steps,
                distanceMeters: distanceKm * 1000, calories: calories
            ))
            let start = (day["sleep_start"] as? NSNumber)?.intValue ?? 0
            let end = (day["sleep_end"] as? NSNumber)?.intValue ?? 0
            if start > 0, end > start {
                let deep = (day["deep"] as? NSNumber)?.intValue ?? 0
                let light = (day["light"] as? NSNumber)?.intValue ?? 0
                let awake = (day["awake"] as? NSNumber)?.intValue ?? 0
                let other = (day["other"] as? NSNumber)?.intValue ?? 0
                let stages = [SleepStage](repeating: .deep, count: deep)
                    + [SleepStage](repeating: .light, count: light)
                    + [SleepStage](repeating: .awake, count: awake)
                    + [SleepStage](repeating: .unknown, count: other)
                events.append(.sleepTimeline(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(start)), stages: stages
                ))
            }
        }
        for measurement in measurements {
            guard let kindRaw = measurement["kind"] as? String,
                  let kind = MeasurementKind(rawValue: kindRaw),
                  let value = (measurement["value"] as? NSNumber)?.doubleValue,
                  let epoch = (measurement["timestamp"] as? NSNumber)?.intValue
            else { continue }
            events.append(.historyMeasurement(
                kind: kind, value: value, timestamp: Date(timeIntervalSince1970: TimeInterval(epoch))
            ))
        }

        for decoded in events {
            // trustTimestamps: cloud rows are our own server's, not the ring's year-less clock, so a
            // restored two-month account must not be trimmed by the history-window guard.
            for pulseEvent in RingEventBridge.events(for: decoded, trustTimestamps: true) {
                await PulseEventBus.shared.publish(pulseEvent)
            }
        }
        Self.log.info("pulled \(days.count) days, \(measurements.count) measurements")
        return days.count
    }

    // MARK: Helpers

    /// Aggregate the sleeping-day's stage blocks into the durations the cloud record carries.
    private func sleepSummary(for day: Date, context: ModelContext) -> (startAt: Date, endAt: Date, deep: Int, light: Int, awake: Int, other: Int, quality: Int)? {
        let calendar = Calendar.current
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>()))?
            .filter { calendar.isDate($0.date, inSameDayAs: day) } ?? []
        guard let session = sessions.min(by: { $0.startAt < $1.startAt }) else { return nil }
        let blocks = (try? context.fetch(FetchDescriptor<SleepStageBlock>()))?
            .filter { $0.sessionId == session.id } ?? []
        var deep = 0, light = 0, awake = 0, other = 0
        for block in blocks {
            switch block.stage {
            case .deep: deep += block.durationMinutes
            case .light: light += block.durationMinutes
            case .awake: awake += block.durationMinutes
            case .rem, .unknown: other += block.durationMinutes
            }
        }
        return (session.startAt, session.endAt, deep, light, awake, other, session.score ?? 0)
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func date(from string: String, calendar: Calendar) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}