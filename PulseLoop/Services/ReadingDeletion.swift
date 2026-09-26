import Foundation
import SwiftData

/// Deleting individual readings (port of Android's `MeasurementDeletion`, issue #60). A reading can be wrong in
/// ways nothing downstream detects (ring worn loosely, a test started by mistake); deletion only — a recorded
/// value may be removed, never edited.
///
/// Two rules make a delete stick, and both live here so no caller has to remember them:
///  * **Tombstone anything the ring can re-send.** History rows are upserted on (kind, exact timestamp) so a
///    re-synced day is idempotent — which would also restore a deleted reading. A `history` row therefore
///    leaves a `MeasurementDeletion` (`history:<kind>:<epoch ms>`, Android's key) that the persistence gate
///    (`isHistoryDeleted`) checks before writing. A live/manual row (a fresh UUID nothing regenerates) is
///    deleted outright.
///  * **Delete a blood-pressure reading as a pair** — systolic and diastolic share a timestamp.
///
/// Known limit (as on Android): iOS has no `spot` source yet, so a live spot reading the ring also logged into
/// its own history can come back as a history row on the next sync. Readings already exported to Apple Health
/// stay there.
@MainActor
enum ReadingDeletion {
    /// Tombstone keys already known (loaded once per context from the store, then kept in step by `delete`).
    /// The persistence path checks it per history sample, so it must stay off the database.
    private static var cache: Set<String>?
    private static weak var cacheContext: ModelContext?

    static func historyKey(kindRaw: String, timestamp: Date) -> String {
        "history:\(kindRaw):\(Int64((timestamp.timeIntervalSince1970 * 1000).rounded()))"
    }

    static func activityKey(startEpoch: Int) -> String { "activity:\(Int64(startEpoch) * 1000)" }

    static let bloodPressureKinds: [MeasurementKind] = [.bloodPressureSystolic, .bloodPressureDiastolic]

    /// The rows one reading is stored as: a blood-pressure row brings its partner at the same timestamp.
    static func readingRows(for row: Measurement, context: ModelContext) -> [Measurement] {
        guard let kind = MeasurementKind(rawValue: row.kindRaw), bloodPressureKinds.contains(kind) else { return [row] }
        let sys = MeasurementKind.bloodPressureSystolic.rawValue, dia = MeasurementKind.bloodPressureDiastolic.rawValue
        let ts = row.timestamp
        let pair = (try? context.fetch(FetchDescriptor<Measurement>(predicate: #Predicate {
            ($0.kindRaw == sys || $0.kindRaw == dia) && $0.timestamp == ts
        }))) ?? []
        return pair.isEmpty ? [row] : pair
    }

    /// Delete `rows` (expanded to whole readings), tombstoning the history ones, and save. Returns rows removed.
    @discardableResult
    static func delete(_ rows: [Measurement], context: ModelContext, now: Date = Date()) -> Int {
        var byId: [UUID: Measurement] = [:]
        for row in rows { for r in readingRows(for: row, context: context) { byId[r.id] = r } }
        guard !byId.isEmpty else { return 0 }
        var keys = loadCache(context)
        for row in byId.values {
            if row.sourceRaw == MeasurementSource.history.rawValue {
                let key = historyKey(kindRaw: row.kindRaw, timestamp: row.timestamp)
                if !keys.contains(key) {
                    context.insert(MeasurementDeletion(measurementId: key, kindRaw: row.kindRaw, timestamp: row.timestamp, deletedAt: now))
                    keys.insert(key)
                }
            }
            // A workout chart keeps its own copy of the sample; it goes with the reading.
            let id = row.id
            for linked in (try? context.fetch(FetchDescriptor<ActivitySample>(predicate: #Predicate { $0.measurementId == id }))) ?? [] {
                context.delete(linked)
            }
            context.delete(row)
        }
        cache = keys
        try? context.save()
        AgaraDataChange.shared.notify()
        return byId.count
    }

    /// A history sample for (kind, timestamp) the user deleted — the persistence gate.
    static func isHistoryDeleted(kindRaw: String, timestamp: Date, context: ModelContext) -> Bool {
        loadCache(context).contains(historyKey(kindRaw: kindRaw, timestamp: timestamp))
    }

    static func isActivityDeleted(startEpoch: Int, context: ModelContext) -> Bool {
        loadCache(context).contains(activityKey(startEpoch: startEpoch))
    }

    /// Remember a new tombstone (activity buckets, archive import).
    static func record(key: String, kindRaw: String, timestamp: Date, context: ModelContext, now: Date = Date()) {
        var keys = loadCache(context)
        guard !keys.contains(key) else { return }
        context.insert(MeasurementDeletion(measurementId: key, kindRaw: kindRaw, timestamp: timestamp, deletedAt: now))
        keys.insert(key)
        cache = keys
    }

    /// Forget the in-memory keys (a restore wiped the table, or tests swap stores).
    static func invalidate() { cache = nil; cacheContext = nil }

    private static func loadCache(_ context: ModelContext) -> Set<String> {
        if let cache, cacheContext === context { return cache }
        let rows = (try? context.fetch(FetchDescriptor<MeasurementDeletion>())) ?? []
        let keys = Set(rows.map(\.measurementId))
        cache = keys
        cacheContext = context
        return keys
    }
}

/// Deleting an hour of steps (port of Android's `ActivityBucketDeletion`, issue #70). Three rules, all here:
///  * **Tombstone it** (`activity:<epoch ms>`), so the next history sync doesn't write the bucket back
///    (`ActivityService.applyActivityBucket` checks).
///  * **Recompute the day without the ratchet** — a deletion is the one case the day's total must fall.
///  * **Remember the deficit** (`ActivityDaily.deletedSteps/deletedDistanceMeters`): the ring's live cumulative
///    count still includes the deleted block, so every later reading is corrected by it
///    (`ratchetAgainstRing`). That is also why it is offered for today only.
/// Calories: the ring's daily figure counted the block and can't be corrected, so it is cleared and the app's
/// own estimate (recomputed from what remains) takes over.
@MainActor
enum ActivityBucketDeletion {
    /// Delete every bucket starting in [start, end) — one hour on the Steps-by-hour card. Returns steps removed.
    @discardableResult
    static func deleteBuckets(from start: Date, to end: Date, context: ModelContext) -> Int {
        let lo = Int(start.timeIntervalSince1970), hi = Int(end.timeIntervalSince1970)
        let buckets = (try? context.fetch(FetchDescriptor<ActivityBucketSample>(predicate: #Predicate {
            $0.startEpoch >= lo && $0.startEpoch < hi
        }))) ?? []
        guard !buckets.isEmpty else { return 0 }
        let total = buckets.reduce(0) { $0 + $1.steps }
        var removed: [Date: (steps: Int, distance: Double)] = [:]
        for bucket in buckets {
            ReadingDeletion.record(key: ReadingDeletion.activityKey(startEpoch: bucket.startEpoch),
                                   kindRaw: "activity_bucket", timestamp: bucket.timestamp, context: context)
            let sum = removed[bucket.date] ?? (0, 0)
            removed[bucket.date] = (sum.steps + bucket.steps, sum.distance + bucket.distanceMeters)
            context.delete(bucket)
        }
        try? context.save()   // the deleted buckets must be gone before the day is re-summed
        for (day, sum) in removed { restate(day: day, removedSteps: sum.steps, removedDistance: sum.distance, context: context) }
        try? context.save()
        for day in removed.keys { DailyCalorieEstimator.recompute(day: day, context: context) }
        try? context.save()
        AgaraDataChange.shared.notify()
        return total
    }

    /// The day's totals become the sum of the buckets it still has (no ratchet), plus the deficit.
    private static func restate(day: Date, removedSteps: Int, removedDistance: Double, context: ModelContext) {
        let remaining = (try? context.fetch(FetchDescriptor<ActivityBucketSample>(predicate: #Predicate { $0.date == day }))) ?? []
        let row: ActivityDaily
        if let existing = MetricsRepository.activity(on: day, context: context) {
            row = existing
        } else {
            row = ActivityDaily(date: day, source: ActivityService.ringHistorySource)
            context.insert(row)
        }
        row.steps = remaining.reduce(0) { $0 + $1.steps }
        row.distanceMeters = remaining.reduce(0) { $0 + $1.distanceMeters }
        row.deletedSteps += removedSteps
        row.deletedDistanceMeters += removedDistance
        row.calories = 0
        row.updatedAt = Date()
    }

    /// What a day's stored total becomes when the ring pushes a cumulative `ringTotal` for it.
    static func ratchetAgainstRing(stored: Int, ringTotal: Int, deleted: Int) -> Int {
        max(stored, max(ringTotal - deleted, 0))
    }

    static func ratchetAgainstRing(stored: Double, ringTotal: Double, deleted: Double) -> Double {
        max(stored, max(ringTotal - deleted, 0))
    }
}
