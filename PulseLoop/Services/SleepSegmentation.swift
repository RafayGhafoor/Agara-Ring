import Foundation
import SwiftData

/// Identities stamped on sleep records (`SleepStageBlock.sourceAddress`) besides a ring's own.
///
/// A ring's identity is its link address: on iOS the CoreBluetooth peripheral UUID (CoreBluetooth hides
/// the MAC Android uses — a recorded platform difference). It is stable per phone and ring, which is all
/// the merge rule needs: tell one source's revisions of a night from another source's night.
enum SleepSource {
    /// The debug socket transport to `ring-emulator` (`-virtualRing <port>`), which has no peripheral.
    static let virtualTransport = "virtual"
    /// Nights restored from the Agara cloud (`AgaraCloudSync.pull`).
    static let cloud = "cloud"
}

extension SleepStageBlock {
    var endAt: Date { startAt.addingTimeInterval(Double(durationMinutes) * 60) }
}

/// Which of a waking day's sessions the app shows (decision D2 of `sleep-session-merge.md`). Nothing is
/// deleted: other sources' nights stay stored, they just aren't displayed.
enum SleepSourcePolicy {
    /// Per waking day: the paired ring's sessions when it has any; otherwise the one source with the most
    /// sleep that day (an earlier ring's history, or the emulator's on a simulator, still shows). Rows written
    /// before sleep was source-stamped (nil source) show only on days no sourced record exists. Order kept.
    static func visible(_ sessions: [SleepSession], pairedSource: String?, calendar: Calendar = .current) -> [SleepSession] {
        var shown = Set<UUID>()
        for day in Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.date) }).values {
            let sourced = day.filter { $0.sourceAddress != nil }
            let picked: [SleepSession]
            if sourced.isEmpty {
                picked = day
            } else if let pairedSource, sourced.contains(where: { $0.sourceAddress == pairedSource }) {
                picked = sourced.filter { $0.sourceAddress == pairedSource }
            } else {
                let minutes = Dictionary(grouping: sourced, by: { $0.sourceAddress ?? "" })
                    .mapValues { rows in rows.reduce(0) { $0 + $1.totalMinutes } }
                let best = minutes.max { l, r in l.value != r.value ? l.value < r.value : l.key > r.key }?.key
                picked = sourced.filter { $0.sourceAddress == best }
            }
            for row in picked { shown.insert(row.id) }
        }
        return sessions.filter { shown.contains($0.id) }
    }
}

/// Splits a waking-day's sleep into distinct sessions — the main night vs. daytime
/// naps — so each can surface as its own carousel page (issue #59). Pure and
/// testable; the SwiftData-facing reconciliation lives in `SleepService`.
enum SleepSegmentation {
    /// A run of >= this many minutes with no recorded sleep data marks a boundary
    /// between two sessions. The ring writes a contiguous per-minute block for each
    /// timeline packet, so short mid-night awakenings stay in one session while a nap
    /// hours after the night (a genuine gap in the blocks) splits into its own.
    static let sessionGapMinutes = 60

    /// Group blocks into chronological sessions, splitting wherever the gap from one
    /// block's end to the next block's start is >= `sessionGapMinutes`. Input need not
    /// be sorted. Returns time-ordered groups; empty in -> empty out.
    static func segment(_ blocks: [SleepStageBlock]) -> [[SleepStageBlock]] {
        let sorted = blocks.sorted { $0.startAt < $1.startAt }
        guard let firstBlock = sorted.first else { return [] }
        let gapSeconds = Double(sessionGapMinutes) * 60
        var groups: [[SleepStageBlock]] = []
        var current: [SleepStageBlock] = [firstBlock]
        var prevEnd = firstBlock.startAt.addingTimeInterval(Double(firstBlock.durationMinutes) * 60)
        for block in sorted.dropFirst() {
            if block.startAt.timeIntervalSince(prevEnd) >= gapSeconds {
                groups.append(current)
                current = [block]
            } else {
                current.append(block)
            }
            // `max` guards against nested/overlapping blocks pulling the running end backwards.
            let end = block.startAt.addingTimeInterval(Double(block.durationMinutes) * 60)
            prevEnd = max(prevEnd, end)
        }
        groups.append(current)
        return groups
    }
}

@MainActor
extension SleepService {
    /// Store one sleep record (one E0 `A1` block) from `source`.
    ///
    /// The rule (`sleep-session-merge.md` §5.2, identical on Android): the record **replaces every block
    /// from the same source that overlaps it** — a re-send of a night that has grown, or the ring re-staging
    /// its own night — and never touches another source's blocks, so the emulator or a second ring can't
    /// rewrite this ring's night. Blocks written before sleep was source-stamped (nil) are only ever replaced
    /// by unsourced records. The old rule here was add-only, deduplicated by block start: a grown record left
    /// its stale shorter runs in place and six overlapping nights stacked into one row.
    ///
    /// Runs that come back unchanged keep their row (same id, so an identical re-send is a true no-op and
    /// HealthKit sees stable ids); a run whose length changed is updated in place. Then every waking day the
    /// record touched is re-derived by `reconcileWakingDay`. Does not save; the caller owns the transaction.
    static func applySleepRecord(start: Date, stages: [SleepStage], source: String?, context: ModelContext) {
        guard !stages.isEmpty else { return }
        let calendar = Calendar.current
        let end = start.addingTimeInterval(Double(stages.count) * 60)
        var allSessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let allBlocks = (try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []
        let sessionsById = Dictionary(allSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let dateKey = calendar.wakingDay(forSleepStart: start)
        let superseded = allBlocks.filter { $0.sourceAddress == source && $0.startAt < end && $0.endAt > start }
        var affectedDays: Set<Date> = [dateKey]
        for block in superseded {
            if let row = sessionsById[block.sessionId] { affectedDays.insert(calendar.startOfDay(for: row.date)) }
        }

        // The row new blocks attach to: this source's earliest row on the day, or a new one.
        let container: SleepSession
        if let existing = allSessions
            .filter({ $0.sourceAddress == source && calendar.isDate($0.date, inSameDayAs: dateKey) })
            .min(by: { $0.startAt < $1.startAt }) {
            container = existing
        } else {
            container = SleepSession(date: dateKey, startAt: start, endAt: start, totalMinutes: 0,
                                     syncedAt: AppClock.now, sourceAddress: source)
            context.insert(container)
            allSessions.append(container)
        }

        struct RunKey: Hashable { let start: Date; let stage: String }
        var reusable = Dictionary(grouping: superseded, by: { RunKey(start: $0.startAt, stage: $0.stageRaw) })
        var kept = Set<UUID>()
        var inserted: [SleepStageBlock] = []
        var offset = 0
        while offset < stages.count {
            let stage = stages[offset]
            var duration = 1
            while offset + duration < stages.count, stages[offset + duration] == stage { duration += 1 }
            let runStart = start.addingTimeInterval(Double(offset) * 60)
            let key = RunKey(start: runStart, stage: stage.rawValue)
            if let block = reusable[key]?.popLast() {
                kept.insert(block.id)
                if block.durationMinutes != duration { block.durationMinutes = duration }
                if block.recordStartAt != start { block.recordStartAt = start }
                // A block left under another day's row (the record's start moved across the evening
                // boundary) moves to this record's day; otherwise reconcile decides its row.
                if let row = sessionsById[block.sessionId], !calendar.isDate(row.date, inSameDayAs: dateKey) {
                    block.sessionId = container.id
                }
            } else {
                let block = SleepStageBlock(sessionId: container.id, startAt: runStart, startMinute: 0,
                                            durationMinutes: duration, stage: stage,
                                            recordStartAt: start, sourceAddress: source)
                context.insert(block)
                inserted.append(block)
            }
            offset += duration
        }

        let removed = superseded.filter { !kept.contains($0.id) }
        for block in removed { context.delete(block) }
        let removedIds = Set(removed.map(\.id))
        let remaining = allBlocks.filter { !removedIds.contains($0.id) } + inserted

        for day in affectedDays.sorted() {
            let daySessions = allSessions.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let ids = Set(daySessions.map(\.id))
            reconcileWakingDay(dateKey: day, context: context, daySessions: daySessions,
                               dayBlocks: remaining.filter { ids.contains($0.sessionId) })
        }
    }

    /// Re-derive one waking day's sessions from its raw stage blocks: group the blocks **by source**, split
    /// each source's blocks by `SleepSegmentation`, then reconcile the SwiftData rows — match each segment to
    /// the same-source row whose prior time-range overlaps it (so identity is stable even when a nap syncs
    /// before the night it precedes), insert rows for unmatched segments, delete leftover empty rows,
    /// re-point every block to its segment, and recompute bounds and the stored score. A row never holds two
    /// sources, so the emulator's night 30 minutes from the ring's can't be glued onto it by the 60-min gap.
    /// A change signal (`DerivedUpdateRow` + `syncedAt` bump) is emitted only when a row's bounds, blocks or
    /// score actually changed, so re-syncing an unchanged day is a true no-op. Idempotent. Does not save; the
    /// caller owns the transaction boundary.
    ///
    /// The stored `score` is `SleepScore.calculate` over the row and its blocks — exactly what the Sleep tab
    /// shows — so the cloud upload (`quality`), insights and the coach read the displayed number (D1).
    ///
    /// `daySessions`/`dayBlocks` let a caller inject the day's already-in-memory rows and blocks to skip the
    /// full-table fetches. `applySleepRecord` passes them on the sync hot path; the migrations pass per-day
    /// slices of a single up-front fetch. When omitted, both are fetched here.
    static func reconcileWakingDay(dateKey: Date, context: ModelContext,
                                   daySessions injectedSessions: [SleepSession]? = nil,
                                   dayBlocks injectedBlocks: [SleepStageBlock]? = nil) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: dateKey)
        let now = AppClock.now

        let daySessions = injectedSessions ?? ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        guard !daySessions.isEmpty else { return }

        let dayBlocks: [SleepStageBlock]
        if let injectedBlocks {
            dayBlocks = injectedBlocks
        } else {
            let daySessionIds = Set(daySessions.map { $0.id })
            dayBlocks = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])
                .filter { daySessionIds.contains($0.sessionId) }
        }

        struct Segment { let blocks: [SleepStageBlock]; let start: Date; let end: Date; let source: String? }
        var segments: [Segment] = []
        for (source, blocks) in Dictionary(grouping: dayBlocks, by: { $0.sourceAddress }) {
            for group in SleepSegmentation.segment(blocks) {
                guard let start = group.first?.startAt else { continue }
                // Clamp: a block with a negative duration (corrupt row, bad import) gives an end before the
                // start, and `start...end` below traps on it.
                let end = max(start, group.map(\.endAt).max() ?? start)
                segments.append(Segment(blocks: group, start: start, end: end, source: source))
            }
        }
        segments.sort { $0.start != $1.start ? $0.start < $1.start : ($0.source ?? "") < ($1.source ?? "") }

        // No blocks left on this day — drop the empty rows entirely.
        guard !segments.isEmpty else {
            for row in daySessions { context.delete(row) }
            return
        }

        // Snapshot each row's PRIOR bounds before any mutation, for identity matching (#9)
        // and bounds-based change detection (#8). Block-set changes are detected per block
        // in the assignment loop below rather than from a snapshot, because a caller may hand
        // us blocks it just inserted — they'd already look "owned" in a snapshot.
        struct Prior { let start: Date; let end: Date }
        var prior: [UUID: Prior] = [:]
        for row in daySessions { prior[row.id] = Prior(start: row.startAt, end: row.endAt) }

        func overlap(_ a0: Date, _ a1: Date, _ b0: Date, _ b1: Date) -> TimeInterval {
            max(0, min(a1, b1).timeIntervalSince(max(a0, b0)))
        }

        // Greedily match each segment to the best-overlapping unused row of the same source; a row also
        // matches when it contains the segment's start (covers a freshly-created zero-length container row).
        var available = daySessions
        var matched: [(segment: Segment, row: SleepSession?)] = []
        for segment in segments {
            let candidates = available.enumerated().filter { $0.element.sourceAddress == segment.source }
            let best = candidates.max { l, r in
                overlap(segment.start, segment.end, prior[l.element.id]!.start, prior[l.element.id]!.end)
                    < overlap(segment.start, segment.end, prior[r.element.id]!.start, prior[r.element.id]!.end)
            }
            if let best, let p = prior[best.element.id],
               overlap(segment.start, segment.end, p.start, p.end) > 0 || (segment.start...segment.end).contains(p.start) {
                available.remove(at: best.offset)
                matched.append((segment, best.element))
            } else {
                matched.append((segment, nil))
            }
        }

        for (segment, existing) in matched {
            let row: SleepSession
            var changed: Bool
            if let existing {
                row = existing; changed = false
            } else {
                row = SleepSession(date: day, startAt: segment.start, endAt: segment.end, totalMinutes: 0,
                                   syncedAt: now, sourceAddress: segment.source)
                context.insert(row); changed = true
            }

            for block in segment.blocks {
                let newMinute = max(0, Int(block.startAt.timeIntervalSince(segment.start) / 60))
                // A re-pointed block (moved between sessions) or a re-based one (its minute
                // offset shifted) means this row's contents changed — including brand-new
                // blocks, which `applySleepRecord` inserts with `startMinute == 0`.
                if block.sessionId != row.id || block.startMinute != newMinute { changed = true }
                block.sessionId = row.id
                block.startMinute = newMinute
            }
            if let p = prior[row.id], p.start != segment.start || p.end != segment.end { changed = true }

            row.date = day
            row.startAt = segment.start
            row.endAt = segment.end
            row.totalMinutes = max(0, Int(segment.end.timeIntervalSince(segment.start) / 60))
            let score = SleepScore.calculate(SleepService.summary(session: row, blocks: segment.blocks)).score
            if row.score != score {
                row.score = score
                changed = true
            }
            if changed {
                row.syncedAt = now
                row.updatedAt = now
                context.insert(DerivedUpdateRow(kind: "sleep_timeline", entityType: "sleep_session", entityId: row.id.uuidString))
            }
        }

        // Rows not matched to any segment had all their blocks re-pointed away — delete them.
        for row in available { context.delete(row) }
    }

    /// One-time re-segmentation of existing sleep sessions that were persisted before
    /// per-session splitting: an afternoon nap used to merge into that morning's night
    /// (one row spanning ~16 h with a broken hypnogram). Re-derives each waking day into
    /// distinct sessions. Idempotent + `UserDefaults`-gated so it runs once, off the
    /// render path. Mirrors `migrateSplitSleepSessionsIfNeeded`.
    static func migrateSleepSessionSegmentsIfNeeded(context: ModelContext) {
        let key = "sleepSessionSegment.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let calendar = Calendar.current
        // Fetch every session and block once, then reconcile each day off in-memory slices —
        // waking days are disjoint, so a day's reconcile never touches another's rows, keeping
        // the up-front snapshot valid across the loop (vs. a full-table scan per day).
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let blocksBySession = Dictionary(grouping: (try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [],
                                         by: { $0.sessionId })
        let sessionsByDay = Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.date) })
        for (day, daySessions) in sessionsByDay {
            let dayBlocks = daySessions.flatMap { blocksBySession[$0.id] ?? [] }
            reconcileWakingDay(dateKey: day, context: context, daySessions: daySessions, dayBlocks: dayBlocks)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }
}
