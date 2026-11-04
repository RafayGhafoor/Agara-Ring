import Foundation
import SwiftData
import OSLog

/// The client half of the EV40 Daily Tracker sync (cloud-v2 §2.1/§3.2): which rows to send, how they go on the wire,
/// how an acknowledgement is recorded, and how a pulled row is applied.
///
/// The merge is **server-stamped last-write-to-reach-the-server wins** (plan D3): the client sends only
/// `{date, mask}` and keeps the stamp the server answers with, so no device clock takes part in a conflict.
/// `Ev40Day.mask != ackedMask` is the only "needs upload" signal, which makes a replay harmless (the server answers
/// `duplicate`) and a crash mid-request safe (nothing was acknowledged, so it is sent again).
@MainActor
enum AgaraCloudTracker {
    /// The server's per-request cap (cloud-v2 §5, `413 too_many_tracker`).
    nonisolated static let maxRowsPerRequest = 400

    private static let log = Logger(subsystem: "com.agara.ring", category: "agara-sync")

    /// Rows whose ticks have not reached the server yet, oldest first and capped.
    static func pending(context: ModelContext, limit: Int = maxRowsPerRequest) -> [Ev40Day] {
        let descriptor = FetchDescriptor<Ev40Day>(sortBy: [SortDescriptor(\.dateKey, order: .forward)])
        let all = (try? context.fetch(descriptor)) ?? []
        var out: [Ev40Day] = []
        for day in all where day.hasUnsentChange {
            out.append(day)
            if out.count == limit { break }
        }
        return out
    }

    /// The envelope objects for `days`.
    nonisolated static func payload(_ days: [Ev40Day]) -> [String] {
        days.map { WireBlockBuilder.json(dateKey: $0.dateKey, mask: $0.mask) }
    }

    /// Record the server's acknowledgement: `ackedMask` becomes the mask that was sent, and the row keeps the
    /// **server's** stamp. A row the user ticks again while the request is in flight stays unacknowledged
    /// (`mask != ackedMask`), so the next pass sends it — nothing is lost to a race with the UI.
    static func mark(synced rows: [(day: Ev40Day, mask: Int, serverUpdatedAt: Date?)], context: ModelContext) {
        guard !rows.isEmpty else { return }
        for row in rows {
            row.day.ackedMask = row.mask
            if let stamp = row.serverUpdatedAt { row.day.serverUpdatedAt = stamp }
        }
        try? context.save()
    }

    /// Apply one page of pulled rows. Returns whether anything changed locally, and whether a local row is still
    /// behind the server (which makes the engine run another push → pull round).
    ///
    /// Rules (cloud-v2 §2.1): a row the server has never seen is inserted; a row with an unsent local change is
    /// **not** overwritten (the push in this round sends it, and the server's answer is the truth); otherwise the
    /// server's copy wins only when its stamp is newer than the one this device holds.
    static func applyPulled(_ rows: [WireEv40Day], context: ModelContext) -> (changed: Bool, needsUpload: Bool) {
        guard !rows.isEmpty else { return (false, false) }
        var changed = false
        var needsUpload = false
        for row in rows {
            let key = row.date
            let incomingMask = Ev40Disciplines.normalised(row.mask)
            let incomingStamp = Date(timeIntervalSince1970: Double(row.updatedAt) / 1000)
            if let local = Ev40Repo.row(key, context: context) {
                if local.hasUnsentChange {
                    needsUpload = true
                    continue
                }
                if row.updatedAt > 0, incomingStamp > (local.serverUpdatedAt ?? .distantPast) {
                    if local.mask != incomingMask { changed = true }
                    local.mask = incomingMask
                    local.ackedMask = incomingMask
                    local.serverUpdatedAt = incomingStamp
                    local.updatedAt = incomingStamp
                }
            } else {
                // A day this device has never seen: adopt it whole, acknowledged, with the server's stamp.
                let created = Ev40Day(dateKey: key, mask: incomingMask, ackedMask: incomingMask,
                                      serverUpdatedAt: incomingStamp)
                context.insert(created)
                changed = true
            }
        }
        if changed || needsUpload { try? context.save() }
        if needsUpload { Self.log.info("tracker: a local day is still unsent after the pull") }
        return (changed, needsUpload)
    }
}
