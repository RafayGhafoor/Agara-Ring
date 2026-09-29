import Foundation
import OSLog
import SwiftData

/// One-off repair for sleep stored before records were source-stamped (`sleep-session-merge.md`, D4).
///
/// The old iOS rule was add-only, deduplicated by block start, so a record that grew between syncs
/// (00:21–06:25, then 00:21–11:11) left its stale shorter runs next to the new ones, and overlapping
/// records from different sources stacked into one row whose stages added up to more than its span. The
/// signature is **overlapping unsourced blocks on one waking day**. For those days only, the E0 transfers
/// still in the raw-packet trace are decoded again and re-applied, oldest first, through the normal record
/// rule — so each night ends up as its latest version, with no stale runs. Days without overlap are left
/// alone, as is everything already source-stamped.
///
/// Limits (recorded, not hidden): the trace is a rolling window of `storage_raw_packets_window_hours` and `_max_rows`
/// rows and is only kept in DEBUG builds or when the user enabled capture, so on most installs there is
/// nothing to replay and the repair does nothing. Raw rows carry no link identity, so re-applied records stay
/// unsourced (as the blocks they replace were), and two sources' legacy records on one night resolve as
/// "latest wins". Idempotent: re-applying the same records is a no-op.
@MainActor
enum SleepRecordRepair {
    static let log = Logger(subsystem: "com.agara.ring", category: "sleep-repair")

    /// One sleep record recovered from the trace.
    struct Record: Equatable {
        let receivedAt: Date
        let start: Date
        let stages: [SleepStage]
    }

    /// Stored frames → the sleep records they carried, in arrival order, reassembled like the sync engine
    /// does (pages by index, descending, header stripped) and decoded against the moment they arrived (the
    /// ring sends no year). A transfer missing a page is skipped; consecutive identical records collapse.
    static func records(from frames: [(timestamp: Date, hex: String)], calendar: Calendar = .current) -> [Record] {
        var records: [Record] = []
        var pages: [Int: [UInt8]] = [:]
        var lastIndex: Int?
        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let data = try? Data(hexString: frame.hex), data.count >= 4, data[0] == 0xE0 else { continue }
            let bytes = [UInt8](data)
            // No-data marker: this day has no sleep; whatever was pending is abandoned.
            if bytes[2] == 0x00 {
                pages.removeAll(); lastIndex = nil
                continue
            }
            let index = Int(bytes[1])
            // Pages count down to 0; a higher index than the last means a new transfer began before the
            // previous one finished (a repeated page — a duplicated request — is just overwritten).
            if let lastIndex, index > lastIndex { pages.removeAll() }
            pages[index] = bytes
            lastIndex = index
            guard index == 0 else { continue }
            defer { pages.removeAll(); lastIndex = nil }
            guard let top = pages.keys.max(), (0...top).allSatisfy({ pages[$0] != nil }) else { continue }
            let payload = pages.keys.sorted(by: >).flatMap { Array(pages[$0]!.dropFirst(4)) }
            let receivedAt = frame.timestamp
            let decoder = VeepooDecoder(calendar: calendar, now: { receivedAt })
            for summary in decoder.sleepSummaries(payload: payload) {
                let record = Record(receivedAt: receivedAt, start: summary.start, stages: summary.stages)
                if let last = records.last, last.start == record.start, last.stages == record.stages { continue }
                records.append(record)
            }
        }
        return records
    }

    /// Waking days whose unsourced blocks overlap each other — the add-only rule's corruption.
    static func affectedDays(context: ModelContext, calendar: Calendar = .current) -> Set<Date> {
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let dayOf = Dictionary(sessions.map { ($0.id, calendar.startOfDay(for: $0.date)) }, uniquingKeysWith: { first, _ in first })
        let legacy = ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []).filter { $0.sourceAddress == nil }
        var days = Set<Date>()
        for (day, blocks) in Dictionary(grouping: legacy, by: { dayOf[$0.sessionId] }) {
            guard let day else { continue }
            var runningEnd: Date?
            for block in blocks.sorted(by: { $0.startAt < $1.startAt }) {
                if let runningEnd, block.startAt < runningEnd { days.insert(day); break }
                runningEnd = max(runningEnd ?? block.endAt, block.endAt)
            }
        }
        return days
    }

    /// Re-apply the trace's records to the affected days. Returns (records found, records applied, days).
    @discardableResult
    static func run(context: ModelContext, calendar: Calendar = .current) -> (found: Int, applied: Int, days: Int) {
        let days = affectedDays(context: context, calendar: calendar)
        guard !days.isEmpty else {
            log.info("sleep repair: no overlapping unsourced blocks, nothing to do")
            return (0, 0, 0)
        }
        let incoming = PacketDirection.incoming.rawValue
        let descriptor = FetchDescriptor<RawPacketRecord>(
            predicate: #Predicate { $0.commandId == 0xE0 && $0.directionRaw == incoming },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        // Traces captured before the BLOB model live in the legacy hex rows until maintenance converts them.
        let legacy = FetchDescriptor<RawPacketRow>(
            predicate: #Predicate { $0.commandId == 0xE0 && $0.directionRaw == incoming },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        let oldRows = (try? context.fetch(legacy)) ?? []
        let found = records(from: (rows.map { ($0.timestamp, $0.hexPayload) } + oldRows.map { ($0.timestamp, $0.hexPayload) }),
                            calendar: calendar)
        var applied = 0
        for record in found where days.contains(calendar.wakingDay(forSleepStart: record.start)) {
            SleepService.applySleepRecord(start: record.start, stages: record.stages, source: nil, context: context)
            applied += 1
        }
        let summary = #"{"affected_days":\#(days.count),"records":\#(found.count),"applied":\#(applied)}"#
        context.insert(DerivedUpdateRow(kind: "sleep_repair", entityType: "sleep_session", entityId: "raw_packets",
                                        payloadJSON: summary))
        log.info("sleep repair: \(days.count) affected days, \(found.count) records in the trace, \(applied) re-applied")
        return (found.count, applied, days.count)
    }
}

@MainActor
extension SleepService {
    static let sleepSourceMigrationKey = "sleepSourceMerge.v1"

    /// One-time step after the source-stamped schema lands: repair the add-only corruption from the raw
    /// trace (`SleepRecordRepair`), then re-derive every waking day once so each row gets its stored score
    /// (rows written before D1 have none, so their cloud `quality` was 0). `UserDefaults`-gated and idempotent.
    static func migrateSleepSourcesIfNeeded(context: ModelContext) {
        defer { rescoreSleepIfNeeded(context: context) }
        guard !UserDefaults.standard.bool(forKey: sleepSourceMigrationKey) else { return }
        SleepRecordRepair.run(context: context)
        try? context.save()
        let calendar = Calendar.current
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let blocksBySession = Dictionary(grouping: (try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [],
                                         by: { $0.sessionId })
        for (day, daySessions) in Dictionary(grouping: sessions, by: { calendar.startOfDay(for: $0.date) }) {
            reconcileWakingDay(dateKey: day, context: context, daySessions: daySessions,
                               dayBlocks: daySessions.flatMap { blocksBySession[$0.id] ?? [] })
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: sleepSourceMigrationKey)
    }

    static let sleepScoreInputsKey = "sleepScore.androidInputs.v1"

    /// One-time: re-store every night's score after the score inputs changed to Android's (asleep minutes,
    /// deep = DEEP + REM — audit batch B), so the cloud `quality`, insights and the coach read the number
    /// the Sleep tab now shows. Writes only rows whose score changed.
    static func rescoreSleepIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: sleepScoreInputsKey) else { return }
        let sessions = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let blocksBySession = Dictionary(grouping: (try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [],
                                         by: { $0.sessionId })
        var changed = 0
        for row in sessions {
            let score = SleepScore.calculate(SleepService.summary(session: row, blocks: blocksBySession[row.id] ?? [])).score
            if row.score != score { row.score = score; changed += 1 }
        }
        if changed > 0 { try? context.save() }
        UserDefaults.standard.set(true, forKey: sleepScoreInputsKey)
    }
}
