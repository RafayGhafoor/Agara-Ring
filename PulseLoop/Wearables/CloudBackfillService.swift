import Foundation
import SwiftData
import os

/// One-time backfill of pre-PulseLoop history from the H Ring **cloud** (the user's own prior data,
/// pulled once on the Mac by `tools/cloud_backfill.py` — never a live cloud dependency).
///
/// The app stays BLE-only for ongoing sync; this import exists so historical days the ring cleared
/// from its own storage (offsets 1–6 daily records came back empty after the first sync) don't
/// disappear from the app. It emits the **same `RingDecodedEvent`s the BLE path emits** and lets
/// `EventPersistenceSubscriber` persist them with the standard idempotent upserts — a day already
/// populated by the ring is skipped, so a cloud import can never override fresher BLE data.
///
/// The file to import is `<Documents>/cloud_backfill.json` (the exporter writes it into the app
/// container directly). After a successful import it is renamed `<Documents>/cloud_backfill.imported`
/// so it is processed once.
@MainActor
enum CloudBackfillService {
    private static let fileName = "cloud_backfill.json"
    private static let log = Logger(subsystem: "com.pulseloop.lab", category: "cloud-backfill")

    struct Slot: Decodable {
        let time: Int            // minutes-of-day at slot start
        let step: Int
        let dis: Double          // km
        let cal: Double
        let ppgs: [Int]          // per-minute HR samples
        let oxygens: [Int]
        let hrvs: [Int]
        let stresss: Int
        let l_bp: Int            // diastolic
        let h_bp: Int            // systolic
    }

    struct Day: Decodable {
        let date: String         // "yyyy-MM-dd" (local calendar, same machine the exporter ran on)
        let step: Int
        let dis_km: Double
        let cal: Double
        let sleep_start: Int?    // local wall-clock epoch seconds, like the ring's own stamps
        let sleep_end: Int?
        let deep: Int
        let light: Int
        let awake: Int
        let other: Int
        let slots: [Slot]
    }

    /// Parse `<Documents>/cloud_backfill.json` and publish mapped events, skipping days the app
    /// already has. Call once at startup, after `EventPersistenceSubscriber` is live.
    static func importIfNeeded(context: ModelContext) async {
        let documents = URL.documentsDirectory
        let source = documents.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        do {
            let data = try Data(contentsOf: source)
            let days = try JSONDecoder().decode([Day].self, from: data)
            var importedDays = 0
            var skippedExisting = 0

            let calendar = Calendar.current
            for day in days {
                let date = date(from: day.date, calendar: calendar)
                guard let date else { continue }

                // A day the ring already synced is authoritative — never override it.
                if MetricsRepository.activity(on: date, context: context) != nil {
                    skippedExisting += 1
                    continue
                }

                var events: [RingDecodedEvent] = []
                // Day totals.
                events.append(.activityUpdate(
                    timestamp: date, steps: day.step,
                    distanceMeters: day.dis_km * 1000, calories: day.cal
                ))
                // Sleep night (durations-only expansion, same caveat as the ring's E0 decode).
                if let start = day.sleep_start, let end = day.sleep_end, end > start {
                    let stages = [SleepStage](repeating: .deep, count: day.deep)
                        + [SleepStage](repeating: .light, count: day.light)
                        + [SleepStage](repeating: .awake, count: day.awake)
                        + [SleepStage](repeating: .unknown, count: day.other)
                    events.append(.sleepTimeline(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(start)), stages: stages
                    ))
                }
                // Intraday 5-minute slots (buckets upsert by timestamp — re-imports are idempotent).
                for slot in day.slots {
                    let slotDate = calendar.date(byAdding: .minute, value: slot.time, to: date) ?? date
                    events.append(.activityBucket(
                        timestamp: slotDate, steps: slot.step, distanceMeters: slot.dis * 1000
                    ))
                    for (offset, bpm) in slot.ppgs.enumerated() {
                        let t = calendar.date(byAdding: .minute, value: offset, to: slotDate) ?? slotDate
                        events.append(.historyMeasurement(kind: .heartRate, value: Double(bpm), timestamp: t))
                    }
                    for (offset, value) in slot.oxygens.enumerated() {
                        let t = calendar.date(byAdding: .minute, value: offset, to: slotDate) ?? slotDate
                        events.append(.historyMeasurement(kind: .spo2, value: Double(value), timestamp: t))
                    }
                    for (offset, value) in slot.hrvs.enumerated() {
                        let t = calendar.date(byAdding: .minute, value: offset, to: slotDate) ?? slotDate
                        events.append(.historyMeasurement(kind: .hrv, value: Double(value), timestamp: t))
                    }
                    if slot.stresss > 0 {
                        events.append(.historyMeasurement(kind: .stress, value: Double(slot.stresss), timestamp: slotDate))
                    }
                    if slot.l_bp > 0, slot.h_bp > 0 {
                        events.append(.historyMeasurement(kind: .bloodPressureSystolic, value: Double(slot.h_bp), timestamp: slotDate))
                        events.append(.historyMeasurement(kind: .bloodPressureDiastolic, value: Double(slot.l_bp), timestamp: slotDate))
                    }
                }

                for decoded in events {
                    for pulseEvent in RingEventBridge.events(for: decoded) {
                        await PulseEventBus.shared.publish(pulseEvent)
                    }
                }
                importedDays += 1
            }

            if importedDays > 0 || skippedExisting > 0 {
                log.info("cloud backfill: imported \(importedDays) day(s), skipped \(skippedExisting) existing")
            }
            try FileManager.default.moveItem(at: source, to: documents.appendingPathComponent("cloud_backfill.imported"))
        } catch {
            // A corrupt file must not wedge startup; leave it in place so a re-export fixes it.
            log.error("cloud backfill failed: \(error.localizedDescription)")
        }
    }

    private static func date(from string: String, calendar: Calendar) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))
    }
}