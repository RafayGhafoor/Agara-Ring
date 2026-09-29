import Foundation
import SwiftData

/// The one read path over measurement history (Rule 10; storage-compression.md §3.3): sealed days come from blocks,
/// open days from rows, and week/month/year zoom uses the block summary columns without decoding. Callers that used to
/// fetch `Measurement` rows for a window ask `MetricsRepository`, which delegates here for anything older than the hot
/// window. Per `(source, sensor_id, utc_day)` at most one of {sealed block, rows} is the source of truth; if both exist
/// (the verify-then-delete transaction was interrupted) the **rows win** and the next maintenance pass finishes the job
/// (storage-format.md §11 "Read path"). A block in state skip/quarantine is a gap: excluded, never deleted.
nonisolated enum MeasurementSeries {
    struct Point: Equatable {
        let ts: Int64
        let value: Double
        let metric: String
        let sourceRaw: String
        let sensorId: String
        var date: Date { BlockStore.date(ms: ts) }
    }

    /// Whether a metric has any sealed block at all (one indexed count) — lets callers skip block lookups entirely.
    static func hasBlocks(metric: String, context: ModelContext) -> Bool {
        var d = FetchDescriptor<MeasurementBlock>(predicate: #Predicate { $0.metric == metric && $0.sealed == true && $0.state == 0 })
        d.fetchLimit = 1
        return ((try? context.fetchCount(d)) ?? 0) > 0
    }

    /// Sealed, readable blocks of a metric whose day overlaps `[fromMs, toMs]`, minus those whose rows still exist.
    static func visibleBlocks(metric: String, fromMs: Int64, toMs: Int64, context: ModelContext, now: Date = Date()) -> [MeasurementBlock] {
        let lo = Int(BlockStore.utcDay(ms: fromMs)), hi = Int(BlockStore.utcDay(ms: toMs))
        guard lo <= hi else { return [] }
        let d = FetchDescriptor<MeasurementBlock>(
            predicate: #Predicate { $0.metric == metric && $0.utcDay >= lo && $0.utcDay <= hi && $0.sealed == true && $0.state == 0 },
            sortBy: [SortDescriptor(\.utcDay)]
        )
        let blocks = (try? context.fetch(d)) ?? []
        guard let first = blocks.first, let last = blocks.last else { return [] }
        // Fast path: one count says whether any row of this metric sits inside the blocks' span. After compaction
        // there are none, so the per-block "rows win" check below never runs.
        let spanLo = BlockStore.dayStart(Int64(first.utcDay)).addingTimeInterval(-1)
        let spanHi = BlockStore.dayStart(Int64(last.utcDay) + 1).addingTimeInterval(1)
        let rowCount = FetchDescriptor<Measurement>(predicate: #Predicate { $0.kindRaw == metric && $0.timestamp >= spanLo && $0.timestamp <= spanHi })
        guard ((try? context.fetchCount(rowCount)) ?? 0) > 0 else { return blocks }
        return blocks.filter { block in
            let key = BlockStore.Key(metric: block.metric, sourceRaw: BlockStore.rawSource(forKeySource: block.source),
                                     sensorId: block.sensorId, day: Int64(block.utcDay))
            return !BlockStore.hasRows(for: key, context: context)
        }
    }

    /// Decode a block for reading. A block that no longer decodes is marked (state 1/2) and yields nothing.
    static func points(of block: MeasurementBlock, context: ModelContext, now: Date = Date()) -> [Point] {
        let dec = AGB.decode(block.data)
        guard dec.isOK else {
            BlockStore.markUnreadable(block, dec.status, context: context, now: now)
            return []
        }
        let raw = BlockStore.rawSource(forKeySource: block.source)
        return zip(dec.timestamps, dec.values).map { Point(ts: $0, value: $1, metric: block.metric, sourceRaw: raw, sensorId: block.sensorId) }
    }

    /// Every sealed point of `metric` with `from <= ts <= to`, oldest first. Rows are NOT included; callers add them.
    static func points(metric: String, from: Date, to: Date, context: ModelContext, now: Date = Date()) -> [Point] {
        let lo = BlockStore.ms(from), hi = BlockStore.ms(to)
        var out: [Point] = []
        for block in visibleBlocks(metric: metric, fromMs: lo, toMs: hi, context: context, now: now) {
            out.append(contentsOf: points(of: block, context: context, now: now).filter { $0.ts >= lo && $0.ts <= hi })
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// A detached `Measurement` for callers that still speak rows. Not inserted into any context.
    @MainActor
    static func detached(_ p: Point) -> Measurement {
        let kind = MeasurementKind(rawValue: p.metric) ?? .heartRate
        return Measurement(kind: kind, value: p.value, unit: kind.unit, timestamp: p.date,
                           source: MeasurementSource(rawValue: p.sourceRaw) ?? .ring, sensorId: p.sensorId)
    }

    /// Newest sealed point of a metric (nil if none). Uses the summary column `t_last`: only the newest block is decoded.
    static func latest(metric: String, context: ModelContext, now: Date = Date()) -> Point? {
        var d = FetchDescriptor<MeasurementBlock>(
            predicate: #Predicate { $0.metric == metric && $0.sealed == true && $0.state == 0 },
            sortBy: [SortDescriptor(\.tLast, order: .reverse)]
        )
        d.fetchLimit = 4
        var best: Point?
        for block in (try? context.fetch(d)) ?? [] where block.n != nil {
            let key = BlockStore.Key(metric: block.metric, sourceRaw: BlockStore.rawSource(forKeySource: block.source),
                                     sensorId: block.sensorId, day: Int64(block.utcDay))
            if BlockStore.hasRows(for: key, context: context) { continue }
            if let last = points(of: block, context: context, now: now).last, best == nil || last.ts > best!.ts { best = last }
        }
        return best
    }

    /// Oldest sealed timestamp across all metrics (summary column only, nothing decoded).
    static func oldestTimestamp(context: ModelContext) -> Date? {
        var d = FetchDescriptor<MeasurementBlock>(
            predicate: #Predicate { $0.sealed == true && $0.state == 0 },
            sortBy: [SortDescriptor(\.tFirst)]
        )
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.tFirst.map(BlockStore.date(ms:))
    }

    // MARK: Coarse zoom — summary columns, decode only the edge days

    struct Stats: Equatable {
        var count = 0
        var sum = 0.0
        var firstTs: Int64?
        var lastTs: Int64?
        mutating func add(count n: Int, sum s: Double, first: Int64, last: Int64) {
            count += n; sum += s
            firstTs = Swift.min(firstTs ?? first, first)
            lastTs = Swift.max(lastTs ?? last, last)
        }
        var mean: Double? { count > 0 ? sum / Double(count) : nil }
    }

    /// Count / sum / first / last of a metric's sealed points in `[fromMs, toMs)`. A block whose whole UTC day lies inside
    /// the window contributes its stored `n`/`sum`/`t_first`/`t_last` **without decoding**; only the (at most two) blocks per
    /// series that straddle the window edges are decoded and clipped.
    static func stats(metric: String, fromMs: Int64, toMs: Int64, context: ModelContext, now: Date = Date()) -> Stats {
        var out = Stats()
        for block in visibleBlocks(metric: metric, fromMs: fromMs, toMs: toMs - 1, context: context, now: now) {
            let dayLo = Int64(block.utcDay) * AGB.dayMs, dayHi = dayLo + AGB.dayMs
            if dayLo >= fromMs, dayHi <= toMs, let n = block.n, let sum = block.vSum, let f = block.tFirst, let l = block.tLast {
                out.add(count: n, sum: sum, first: f, last: l)
                continue
            }
            let inside = points(of: block, context: context, now: now).filter { $0.ts >= fromMs && $0.ts < toMs }
            if let f = inside.first, let l = inside.last { out.add(count: inside.count, sum: inside.reduce(0) { $0 + $1.value }, first: f.ts, last: l.ts) }
        }
        return out
    }

    /// Per-UTC-day count/min/max/sum of a metric from the summary columns alone (nothing decoded). Sealed blocks only.
    struct DaySummary: Equatable {
        let day: Int64
        let n: Int
        let min: Double
        let max: Double
        let sum: Double
    }

    static func daySummaries(metric: String, fromDay: Int64, toDay: Int64, context: ModelContext) -> [DaySummary] {
        visibleBlocks(metric: metric, fromMs: fromDay * AGB.dayMs, toMs: (toDay + 1) * AGB.dayMs - 1, context: context).compactMap { b in
            guard let n = b.n, let lo = b.vMin, let hi = b.vMax, let sum = b.vSum else { return nil }
            return DaySummary(day: Int64(b.utcDay), n: n, min: lo, max: hi, sum: sum)
        }
    }
}
