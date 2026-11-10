import XCTest
import SwiftData
@testable import PulseLoop

/// Source-aware sleep records (`docs/process/plans/sleep-session-merge.md` §5–7): the real 2026-09-25
/// transfers from ring B and the emulator, replayed through the decoder, the engine and the store. Each test
/// here fails on the old code — add-only storage stacked the nights, the engine never completed a
/// two-session day and decoded only its first session, and nothing wrote the stored score.
@MainActor
final class SleepSourceMergeTests: XCTestCase {
    /// Fake link identities (peripheral-UUID shaped); no real ring's address appears in the tests.
    private let ringB = "00000000-0000-4000-8000-00000000000B"
    private let emulator = "00000000-0000-4000-8000-0000000000EE"

    /// The transfers arrived on 2026-09-25; decode against that evening so the year is 2026 whenever this runs.
    private let received = SleepSourceMergeTests.date(9, 25, 23, 0)
    private var decoder: VeepooDecoder {
        let now = received
        return VeepooDecoder(calendar: .current, now: { now })
    }

    private static func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var night: Date { Self.date(9, 25, 0, 0) }

    private func record(_ pages: [String]) -> VeepooSleepSummary {
        let summaries = decoder.sleepSummaries(payload: SleepTransferFixtures.payload(pages))
        XCTAssertEqual(summaries.count, 1)
        return summaries[0]
    }

    // MARK: Decoder

    func testEveryRealTransferDecodesToOneSessionAtItsStart() {
        let expected: [([String], Date, Int)] = [
            (SleepTransferFixtures.ringB0625, Self.date(9, 25, 0, 21), 364),
            (SleepTransferFixtures.ringB1105, Self.date(9, 25, 0, 21), 644),
            (SleepTransferFixtures.ringB1111, Self.date(9, 25, 0, 21), 650),
            (SleepTransferFixtures.emu2148, Self.date(9, 25, 0, 24), 411),
            (SleepTransferFixtures.emu2151, Self.date(9, 24, 22, 1), 501),
            (SleepTransferFixtures.emu2152, Self.date(9, 24, 21, 11), 505),
            (SleepTransferFixtures.emu2153, Self.date(9, 25, 0, 18), 359),
            (SleepTransferFixtures.emu2154, Self.date(9, 25, 0, 7), 380),
            (SleepTransferFixtures.emu2159, Self.date(9, 24, 22, 55), 443),
        ]
        for (pages, start, minutes) in expected {
            let summary = record(pages)
            XCTAssertEqual(summary.start, start)
            XCTAssertEqual(summary.stages.count, minutes)
        }
        // The single-session real fixture is unchanged by the multi-block walk: 135/379/98/38.
        let stages = record(SleepTransferFixtures.ringB1111).stages
        XCTAssertEqual([SleepStage.deep, .light, .rem, .awake].map { s in stages.filter { $0 == s }.count }, [135, 379, 98, 38])
    }

    /// Ring B's first transfer's `A1` block (declared length 196) plus a copy moved to the afternoon — a day
    /// with a nap, `e0 <n> 02 <day>` — paged the way the ring pages it.
    private func twoSessionFrames() -> [Data] {
        let first = Array(SleepTransferFixtures.payload(SleepTransferFixtures.ringB0625).prefix(196))
        XCTAssertEqual(first[0], 0xA1)
        XCTAssertEqual(veepooUInt16LE(first, 1), first.count)
        var nap = first
        let a3 = (0..<nap.count - 1).first { nap[$0] == 0xA3 && nap[$0 + 1] == 0x24 }! + 2
        nap[a3 + 2] = 13; nap[a3 + 3] = 0       // start 09-25 13:00
        nap[a3 + 6] = 19; nap[a3 + 7] = 4       // end 19:04
        let payload = first + nap
        let pageCount = (payload.count + 15) / 16
        return (0..<pageCount).map { page -> Data in
            let index = pageCount - 1 - page     // descending, like the ring
            let chunk = payload[(page * 16)..<min(payload.count, page * 16 + 16)]
            return Data([0xE0, UInt8(index), 0x02, 0x00] + chunk + [UInt8](repeating: 0, count: 16 - chunk.count))
        }
    }

    func testTwoSessionTransferDecodesBothSessions() {
        let payload = twoSessionFrames().sorted { $0[1] > $1[1] }.flatMap { [UInt8]($0.dropFirst(4)) }
        let summaries = decoder.sleepSummaries(payload: payload)
        XCTAssertEqual(summaries.map(\.start), [Self.date(9, 25, 0, 21), Self.date(9, 25, 13, 0)])
        XCTAssertEqual(summaries.map(\.stages.count), [364, 364])
    }

    // MARK: Engine

    private final class Writer: RingCommandWriter {
        let identity: String?
        init(identity: String?) { self.identity = identity }
        var deviceIdentifier: String? { identity }
        var commands: [Data] = []
        var emitted: [RingDecodedEvent] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
        var timelines: [(start: Date, count: Int, source: String?)] {
            emitted.compactMap {
                if case let .sleepTimeline(start, stages, source) = $0 { return (start, stages.count, source) }
                return nil
            }
        }
    }

    private var writer = Writer(identity: nil)

    private func engine(identity: String?) -> VeepooSyncEngine {
        writer = Writer(identity: identity)
        let engine = VeepooSyncEngine(writer: writer, decoder: decoder, historyDays: 2)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        return engine
    }

    func testTwoSessionTransferCompletesOnItsLastPageAndEmitsTwoTimelines() {
        let engine = engine(identity: ringB)
        for frame in twoSessionFrames() { engine.handle(.unknown(commandId: 0xE0, raw: frame)) }
        XCTAssertTrue(writer.commands.contains(VeepooEncoder.dailyHistory(dayOffset: 0)),
                      "the `e0 00 02` last page must complete the sleep phase without the watchdog")
        XCTAssertEqual(writer.timelines.map(\.start), [Self.date(9, 25, 0, 21), Self.date(9, 25, 13, 0)])
        XCTAssertEqual(writer.timelines.map(\.source), [ringB, ringB])
        engine.connectionDidEnd()
    }

    func testRealTransferIsStampedWithTheLinksIdentity() {
        let engine = engine(identity: ringB)
        for frame in SleepTransferFixtures.frames(SleepTransferFixtures.ringB1111) {
            engine.handle(.unknown(commandId: 0xE0, raw: frame))
        }
        XCTAssertEqual(writer.timelines.count, 1)
        XCTAssertEqual(writer.timelines.first?.count, 650)
        XCTAssertEqual(writer.timelines.first?.source, ringB)
        engine.connectionDidEnd()
    }

    // MARK: Store

    private typealias Delivery = (pages: [String], source: String)

    /// Every record in arrival order (§2.2): ring B's three versions, then the six emulator nights.
    private var arrivalOrder: [Delivery] {
        SleepTransferFixtures.ringB.map { ($0, ringB) } + SleepTransferFixtures.emulator.map { ($0, emulator) }
    }

    private func replay(_ deliveries: [Delivery], into context: ModelContext) {
        let subscriber = EventPersistenceSubscriber(context: context)
        for delivery in deliveries {
            let summary = record(delivery.pages)
            subscriber.persist(.sleepTimeline(timestamp: summary.start, stages: summary.stages, source: delivery.source))
        }
        subscriber.stop()
    }

    private func blocks(of source: String?, in context: ModelContext) -> [SleepStageBlock] {
        ((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? [])
            .filter { $0.sourceAddress == source }
            .sorted { $0.startAt < $1.startAt }
    }

    private func sessions(of source: String?, in context: ModelContext) -> [SleepSession] {
        SleepRepository.allSessions(context: context).filter { $0.sourceAddress == source }
    }

    private struct BlockShape: Equatable { let start: Date; let minutes: Int; let stage: SleepStage }
    private func shape(_ blocks: [SleepStageBlock]) -> [BlockShape] {
        blocks.map { BlockShape(start: $0.startAt, minutes: $0.durationMinutes, stage: $0.stage) }
    }

    /// The acceptance criterion: ring B → one session 09-25 00:21–11:11, 612 min asleep, 38 awake.
    private func assertRingBNight(in context: ModelContext, file: StaticString = #filePath, line: UInt = #line) {
        let rows = sessions(of: ringB, in: context)
        XCTAssertEqual(rows.count, 1, "ring B's night is one session", file: file, line: line)
        guard let row = rows.first else { return }
        XCTAssertEqual(row.startAt, Self.date(9, 25, 0, 21), file: file, line: line)
        XCTAssertEqual(row.endAt, Self.date(9, 25, 11, 11), file: file, line: line)
        XCTAssertEqual(row.date, night, file: file, line: line)
        let own = blocks(of: ringB, in: context)
        XCTAssertTrue(own.allSatisfy { $0.sessionId == row.id }, file: file, line: line)
        XCTAssertEqual(own.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes }, 612, file: file, line: line)
        XCTAssertEqual(own.filter { $0.stage == .awake }.reduce(0) { $0 + $1.durationMinutes }, 38, file: file, line: line)
        // No stale or stacked run: the blocks tile the span exactly.
        XCTAssertEqual(own.reduce(0) { $0 + $1.durationMinutes }, 650, file: file, line: line)
        XCTAssertTrue(zip(own, own.dropFirst()).allSatisfy { $0.endAt <= $1.startAt }, file: file, line: line)
        XCTAssertTrue(own.allSatisfy { $0.recordStartAt == Self.date(9, 25, 0, 21) }, file: file, line: line)
    }

    func testArrivalOrderReplayKeepsRingBsNightWhole() throws {
        let context = try TestSupport.makeContext()
        replay(arrivalOrder, into: context)
        assertRingBNight(in: context)
        // The emulator's records are kept, as their own sessions, and never mixed into ring B's row.
        let emulatorRows = sessions(of: emulator, in: context)
        XCTAssertFalse(emulatorRows.isEmpty)
        XCTAssertFalse(blocks(of: emulator, in: context).isEmpty)
        XCTAssertTrue(Set(emulatorRows.map(\.id)).isDisjoint(with: Set(sessions(of: ringB, in: context).map(\.id))))
    }

    /// The emulator's records may land before, between or after ring B's; ring B's night comes out the same.
    /// (Ring B's own records keep their order: a ring re-sends its night as it grows, oldest first.)
    func testRingBsNightIsTheSameWhereverTheEmulatorsRecordsLand() throws {
        let reference = try TestSupport.makeContext()
        replay(arrivalOrder, into: reference)
        let expected = shape(blocks(of: ringB, in: reference))

        let emu = SleepTransferFixtures.emulator.map { ($0, emulator) }
        let b = SleepTransferFixtures.ringB.map { ($0, ringB) }
        let orders: [[Delivery]] = [
            emu + b,
            emu.reversed() + b,
            [b[0]] + emu + [b[1], b[2]],
            [b[0], emu[5], b[1], emu[0], emu[1], b[2], emu[2], emu[3], emu[4]],
            b + emu.reversed(),
        ]
        for order in orders {
            let context = try TestSupport.makeContext()
            replay(order, into: context)
            assertRingBNight(in: context)
            XCTAssertEqual(shape(blocks(of: ringB, in: context)), expected)
        }
    }

    func testGrownResendLeavesNoStaleRunAndAnIdenticalResendIsANoOp() throws {
        let context = try TestSupport.makeContext()
        replay(SleepTransferFixtures.ringB.map { ($0, ringB) }, into: context)
        let alone = try TestSupport.makeContext()
        replay([(SleepTransferFixtures.ringB1111, ringB)], into: alone)
        XCTAssertEqual(shape(blocks(of: ringB, in: context)), shape(blocks(of: ringB, in: alone)),
                       "06:25 → 11:05 → 11:11 must leave exactly the 11:11 record")

        try context.save()
        let ids = blocks(of: ringB, in: context).map(\.id)
        let updates = ((try? context.fetch(FetchDescriptor<DerivedUpdateRow>())) ?? []).count
        replay([(SleepTransferFixtures.ringB1111, ringB)], into: context)
        XCTAssertEqual(blocks(of: ringB, in: context).map(\.id), ids, "unchanged runs keep their rows")
        XCTAssertEqual(((try? context.fetch(FetchDescriptor<DerivedUpdateRow>())) ?? []).count, updates)
    }

    func testSleepTabShowsOnlyThePairedRingsNight() throws {
        let context = try TestSupport.makeContext()
        replay(arrivalOrder, into: context)
        let device = Device()
        device.peripheralIdentifier = ringB
        context.insert(device)

        let shown = SleepRepository.sessions(context: context).filter { Calendar.current.isDate($0.date, inSameDayAs: night) }
        XCTAssertEqual(Set(shown.compactMap(\.sourceAddress)), [ringB])
        let tab = SleepService.sleepForDate(night, context: context)
        XCTAssertEqual(tab?.session.sourceAddress, ringB)
        XCTAssertEqual(tab?.session.totalMinutes, 650)
        XCTAssertEqual(tab?.blocks.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes }, 612)

        // Pair the emulator instead: its nights show, ring B's stay stored.
        device.peripheralIdentifier = emulator
        let emulatorShown = SleepRepository.sessions(context: context).filter { Calendar.current.isDate($0.date, inSameDayAs: night) }
        XCTAssertEqual(Set(emulatorShown.compactMap(\.sourceAddress)), [emulator])
        XCTAssertEqual(sessions(of: ringB, in: context).count, 1)
    }

    func testUnsourcedBlocksSurviveASourcedRecordButAreHiddenOnItsDay() throws {
        let context = try TestSupport.makeContext()
        let legacy = TestSupport.insertSleep(nightStart: Self.date(9, 25, 0, 30), stages: Array(repeating: .light, count: 300), into: context)
        let legacyBlocks = blocks(of: nil, in: context).count
        replay([(SleepTransferFixtures.ringB1111, ringB)], into: context)
        XCTAssertEqual(blocks(of: nil, in: context).count, legacyBlocks, "a sourced record never deletes unsourced blocks")
        assertRingBNight(in: context)
        let shown = SleepRepository.sessions(context: context).map(\.id)
        XCTAssertFalse(shown.contains(legacy.id))
        XCTAssertEqual(shown.count, 1)
    }

    // MARK: Score (D1)

    func testStoredScoreIsTheDisplayedScoreAndIsUploaded() throws {
        let context = try TestSupport.makeContext()
        replay(arrivalOrder, into: context)
        let device = Device()
        device.peripheralIdentifier = ringB
        context.insert(device)
        guard let tab = SleepService.sleepForDate(night, context: context) else { return XCTFail("no night") }
        let displayed = SleepScore.calculate(tab).score
        XCTAssertEqual(tab.session.score, displayed)
        // Android's inputs (asleep minutes, deep = DEEP + REM, awake share of the 650-min span) — the same value
        // Android's `SleepSourceMergeTest` pins for ring B's night (audit batch B).
        //
        // **Policy change 2026-11-05:** `sleep_score_v2` now ships on, so this night scores 76 on both platforms
        // instead of v1's 64. Kept as one literal on each side because that agreement *is* the parity proof.
        XCTAssertEqual(displayed, 76)
        XCTAssertEqual(AgaraCloudDays.sleepSummary(for: night, context: context)?.quality, displayed,
                       "the cloud `quality` is the displayed score, not 0")
        // Every stored row carries its own displayed score, emulator rows included.
        for row in SleepRepository.allSessions(context: context) {
            XCTAssertEqual(row.score, SleepScore.calculate(SleepService.summary(for: row, context: context)).score)
        }
    }

    // MARK: Repair (D4)

    /// The old add-only rule: one container row per waking day, a run skipped only when a block already
    /// starts on the same minute. This is how iOS stored these records before the fix.
    private func legacyAddOnly(_ pages: [String], into context: ModelContext) {
        let summary = record(pages)
        let day = Calendar.current.wakingDay(forSleepStart: summary.start)
        let rows = ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? []).filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        let row = rows.first ?? {
            let new = SleepSession(date: day, startAt: summary.start, endAt: summary.start, totalMinutes: 0)
            context.insert(new)
            return new
        }()
        var starts = Set(((try? context.fetch(FetchDescriptor<SleepStageBlock>())) ?? []).map(\.startAt))
        var offset = 0
        let stages = summary.stages
        while offset < stages.count {
            var run = 1
            while offset + run < stages.count, stages[offset + run] == stages[offset] { run += 1 }
            let start = summary.start.addingTimeInterval(Double(offset) * 60)
            if !starts.contains(start) {
                context.insert(SleepStageBlock(sessionId: row.id, startAt: start, startMinute: 0, durationMinutes: run, stage: stages[offset]))
                starts.insert(start)
            }
            offset += run
        }
        SleepService.reconcileWakingDay(dateKey: day, context: context)
    }

    private func storeRawTransfer(_ pages: [String], at timestamp: Date, into context: ModelContext) {
        for (index, hex) in pages.enumerated() {
            context.insert(RawPacketRecord(timestamp: timestamp.addingTimeInterval(Double(index) * 0.05),
                                        direction: .incoming, commandId: 0xE0, hexPayload: hex))
        }
    }

    func testRawFramesYieldEachDistinctRecordOnce() {
        var frames: [(timestamp: Date, hex: String)] = []
        func add(_ pages: [String], _ at: Date, copies: Int = 1) {
            for (index, hex) in pages.enumerated() {
                for copy in 0..<copies { frames.append((at.addingTimeInterval(Double(index * copies + copy) * 0.05), hex)) }
            }
        }
        add(SleepTransferFixtures.ringB0625, Self.date(9, 25, 6, 36))
        add(SleepTransferFixtures.ringB0625, Self.date(9, 25, 6, 38))                 // served again, unchanged
        add(SleepTransferFixtures.ringB1111, Self.date(9, 25, 11, 26), copies: 3)     // a duplicated request
        add(Array(SleepTransferFixtures.ringB1105.dropLast(2)), Self.date(9, 25, 11, 40)) // cut short: skipped
        let records = SleepRecordRepair.records(from: frames)
        XCTAssertEqual(records.map(\.start), [Self.date(9, 25, 0, 21), Self.date(9, 25, 0, 21)])
        XCTAssertEqual(records.map(\.stages.count), [364, 650])
    }

    func testRepairRebuildsAStackedNightFromTheRawTraceAndIsIdempotent() throws {
        let context = try TestSupport.makeContext()
        for pages in SleepTransferFixtures.ringB { legacyAddOnly(pages, into: context) }
        let stacked = blocks(of: nil, in: context)
        XCTAssertGreaterThan(stacked.reduce(0) { $0 + $1.durationMinutes }, 650, "the old rule stacks stale runs")
        XCTAssertEqual(SleepRecordRepair.affectedDays(context: context), [night])

        storeRawTransfer(SleepTransferFixtures.ringB0625, at: Self.date(9, 25, 6, 36), into: context)
        storeRawTransfer(SleepTransferFixtures.ringB1105, at: Self.date(9, 25, 11, 17), into: context)
        storeRawTransfer(SleepTransferFixtures.ringB1111, at: Self.date(9, 25, 11, 26), into: context)
        let result = SleepRecordRepair.run(context: context)
        XCTAssertEqual(result.found, 3)
        XCTAssertEqual(result.days, 1)

        let repaired = blocks(of: nil, in: context)
        XCTAssertEqual(repaired.reduce(0) { $0 + $1.durationMinutes }, 650)
        XCTAssertEqual(repaired.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes }, 612)
        XCTAssertTrue(zip(repaired, repaired.dropFirst()).allSatisfy { $0.endAt <= $1.startAt })
        let rows = sessions(of: nil, in: context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.startAt, Self.date(9, 25, 0, 21))
        XCTAssertEqual(rows.first?.endAt, Self.date(9, 25, 11, 11))
        XCTAssertNotNil(rows.first?.score)

        // A second run finds nothing to repair and changes nothing.
        let ids = repaired.map(\.id)
        XCTAssertTrue(SleepRecordRepair.affectedDays(context: context).isEmpty)
        XCTAssertEqual(SleepRecordRepair.run(context: context).applied, 0)
        XCTAssertEqual(blocks(of: nil, in: context).map(\.id), ids)
    }

    /// BUG-204 — Android drops an incoming record when a stored same-source record overlaps it and is
    /// *longer* (a ring record only grows while it is staged, so the short copy is the stale one). iOS had
    /// no such comparison: one page's worth of loss (BUG-201's 620-minute decode) shrank a 650-minute night.
    func testAShorterReSendDoesNotShrinkTheStoredNight() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let grown = record(SleepTransferFixtures.ringB1111)          // 00:21 → 11:11, 650 minutes
        let earlier = record(SleepTransferFixtures.ringB1105)        // 00:21 → 11:05, 644 minutes (a re-read)
        XCTAssertEqual([earlier.stages.count, grown.stages.count], [644, 650])

        // The grown record first, then the *shorter* one the ring served earlier in the same evening.
        subscriber.persist(.sleepTimeline(timestamp: grown.start, stages: grown.stages, source: ringB))
        subscriber.persist(.sleepTimeline(timestamp: earlier.start, stages: earlier.stages, source: ringB))
        subscriber.stop()

        var rows = sessions(of: ringB, in: context)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.startAt, Self.date(9, 25, 0, 21))
        XCTAssertEqual(rows.first?.endAt, Self.date(9, 25, 11, 11), "the stored 650-minute night wins")
        XCTAssertEqual(blocks(of: ringB, in: context).reduce(0) { $0 + $1.durationMinutes }, 650)

        // In the other order the night still lands on 650: a longer re-send replaces the shorter copy.
        let fresh = try TestSupport.makeContext()
        let subscriber2 = EventPersistenceSubscriber(context: fresh)
        subscriber2.persist(.sleepTimeline(timestamp: earlier.start, stages: earlier.stages, source: ringB))
        subscriber2.persist(.sleepTimeline(timestamp: grown.start, stages: grown.stages, source: ringB))
        subscriber2.stop()
        rows = sessions(of: ringB, in: fresh)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.endAt, Self.date(9, 25, 11, 11))
    }

    func testRepairLeavesHealthyNightsAlone() throws {
        let context = try TestSupport.makeContext()
        legacyAddOnly(SleepTransferFixtures.ringB1111, into: context)
        storeRawTransfer(SleepTransferFixtures.ringB0625, at: Self.date(9, 25, 6, 36), into: context)
        let before = shape(blocks(of: nil, in: context))
        XCTAssertEqual(SleepRecordRepair.run(context: context).applied, 0)
        XCTAssertEqual(shape(blocks(of: nil, in: context)), before)
    }
}
