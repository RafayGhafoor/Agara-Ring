import XCTest
import SwiftData
@testable import PulseLoop

/// Owner feedback before release (2026-09-26, `docs/process/plans/consistency-framework.md`), same rules as
/// Android: (1) one sleep-day rule — main sleep = the longest session, naps add to the day's total and show as
/// "+ nap 40 m"; (2) `SyncPlan` — skip closed past days already stored for this ring, resume today after its last
/// stored record.
@MainActor
final class SleepDayAndSyncPlanTests: XCTestCase {

    // MARK: - Sleep-day rule (pure)

    private struct Session { let name: String; let start: Date; let minutes: Int }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        let base = TestSupport.day(day)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    func testMainSleepIsTheLongestSessionWhateverTheOrder() {
        let night = Session(name: "night", start: at(23, day: -1), minutes: 420)
        let nap = Session(name: "nap", start: at(13), minutes: 40)
        let early = Session(name: "early", start: at(21, day: -1), minutes: 30)
        for order in [[night, nap, early], [nap, early, night], [early, night, nap]] {
            let split = SleepDayRule.split(order, minutes: \.minutes, start: \.start)
            XCTAssertEqual(split?.main.name, "night", "the longest session is the main sleep, not the first or the last")
            XCTAssertEqual(split?.naps.map(\.name), ["early", "nap"], "naps in time order")
        }
        XCTAssertNil(SleepDayRule.split([Session](), minutes: \.minutes, start: \.start))
    }

    func testEqualLengthGoesToTheEarlierSession() {
        let a = Session(name: "a", start: at(1), minutes: 60)
        let b = Session(name: "b", start: at(14), minutes: 60)
        XCTAssertEqual(SleepDayRule.split([b, a], minutes: \.minutes, start: \.start)?.main.name, "a")
    }

    func testNapCaption() {
        XCTAssertNil(SleepDayRule.napCaption(count: 0, minutes: 0))
        XCTAssertNil(SleepDayRule.napCaption(count: 1, minutes: 0))
        XCTAssertEqual(SleepDayRule.napCaption(count: 1, minutes: 40), "+ nap 40 m")
        XCTAssertEqual(SleepDayRule.napCaption(count: 1, minutes: 60), "+ nap 1h 0m")
        XCTAssertEqual(SleepDayRule.napCaption(count: 2, minutes: 65), "+ 2 naps 1h 5m")
    }

    // MARK: - Sleep-day rule (store consumers)

    /// A night (23:00 → 06:00) and a 40-minute nap at 13:00 on the same waking day.
    private func insertNightAndNap(_ context: ModelContext) {
        TestSupport.insertSleep(nightStart: at(23, day: -1),
                                stages: Array(repeating: .light, count: 300) + Array(repeating: .deep, count: 120),
                                into: context)
        TestSupport.insertSleep(nightStart: at(13), stages: Array(repeating: .light, count: 40), into: context)
    }

    func testTodayShowsTheNightWithTheNapAddedToTheTotal() throws {
        let context = try TestSupport.makeContext()
        insertNightAndNap(context)
        let day = try XCTUnwrap(SleepService.latestSleepDay(context: context))
        XCTAssertEqual(day.main.session.totalMinutes, 420, "the night, not the later nap")
        XCTAssertEqual(day.main.deepMinutes, 120)
        XCTAssertEqual(day.naps.count, 1)
        XCTAssertEqual(day.totalMinutes, 460)
        XCTAssertEqual(day.napCaption, "+ nap 40 m")

        let today = MetricsService.buildTodaySummary(context: context)
        XCTAssertEqual(today.sleepDay?.totalMinutes, 460)
        XCTAssertEqual(today.sleep?.session.totalMinutes, 420, "stages and score come from the main sleep")
    }

    func testCoachSleepContextsUseTheSameRule() throws {
        let context = try TestSupport.makeContext()
        insertNightAndNap(context)
        let noon = at(12)
        let packet = CoachContextBuilder.build(context: context, now: noon)
        XCTAssertEqual(packet.latestSleep?.totalMin, 460)
        XCTAssertEqual(packet.latestSleep?.napMin, 40)
        XCTAssertEqual(packet.latestSleep?.deepMin, 120, "stage minutes are the night's")

        let built = try XCTUnwrap(CoachSummaryContextBuilder.sleepDay(context: context, now: at(15)))
        XCTAssertTrue(built.json.contains("\"total_min\":460"), built.json)
        XCTAssertTrue(built.json.contains("\"nap_min\":40"), built.json)
        XCTAssertTrue(built.json.contains("\"deep_min\":120"), "the nap used to be taken as the night (\(built.json))")
    }

    func testCloudUploadTakesTheLongestSessionNotTheEarliest() throws {
        let context = try TestSupport.makeContext()
        // A short 01:00 wake-up doze, then the real sleep 02:00 → 09:00 — both on today's waking day.
        TestSupport.insertSleep(nightStart: at(1), stages: Array(repeating: .light, count: 30), into: context)
        let main = TestSupport.insertSleep(nightStart: at(2), stages: Array(repeating: .deep, count: 420), into: context)
        let summary = try XCTUnwrap(AgaraCloudDays.sleepSummary(for: TestSupport.day(0), context: context))
        XCTAssertEqual(summary.startAt, main.startAt)
        XCTAssertEqual(summary.endAt, main.endAt)
        XCTAssertEqual(summary.deep, 420)
        XCTAssertEqual(summary.light, 30, "the nap's minutes count toward the day's stage totals (as on Android)")
    }

    // MARK: - SyncPlan (pure)

    private let calendar = Calendar.current
    private let today = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 14))!

    private func key(_ offset: Int) -> String { SyncPlan.dateKey(offset: offset, today: today, calendar: calendar) }

    private func done(_ total: Int) -> SyncPlan.DayState {
        SyncPlan.DayState(storedThrough: total, totalBlocks: total, complete: true)
    }

    func testDateKeysCountBackFromToday() {
        XCTAssertEqual(key(0), "2026-09-26")
        XCTAssertEqual(key(1), "2026-09-25")
        XCTAssertEqual(key(26), "2026-08-31")
    }

    func testNoLedgerOrANewRingDownloadsEveryDayInFull() {
        let full = (0..<7).map { SyncPlan.Day(offset: $0, position: 1) }
        XCTAssertEqual(SyncPlan.make(historyDays: 7, today: today, calendar: calendar, ledger: nil).days, full)
        XCTAssertEqual(SyncPlan.make(historyDays: 7, today: today, calendar: calendar, ledger: [:]).days, full)
    }

    func testNormalRefreshAsksOnlyForTodayFromTheResumePosition() {
        var ledger = Dictionary(uniqueKeysWithValues: (1..<7).map { (key($0), done(288)) })
        ledger[key(0)] = SyncPlan.DayState(storedThrough: 56, totalBlocks: 56)
        let plan = SyncPlan.make(historyDays: 7, today: today, calendar: calendar, ledger: ledger)
        XCTAssertEqual(plan.days, [SyncPlan.Day(offset: 0, position: 57)])
    }

    func testIncompletePastDayIsFetchedInFullAndTodayFromOneWhenNothingStored() {
        var ledger = Dictionary(uniqueKeysWithValues: (1..<7).map { (key($0), done(100)) })
        ledger[key(3)] = SyncPlan.DayState(storedThrough: 40, totalBlocks: 100)   // cut off
        let plan = SyncPlan.make(historyDays: 7, today: today, calendar: calendar, ledger: ledger)
        XCTAssertEqual(plan.days, [SyncPlan.Day(offset: 0, position: 1), SyncPlan.Day(offset: 3, position: 1)])
    }

    func testYesterdayIsFetchedInFullOnceTheDateRollsOver() {
        // Yesterday's date was "today" last time (never complete): the first pass of the new day takes it in full.
        let ledger = [key(1): SyncPlan.DayState(storedThrough: 200, totalBlocks: 200)]
        let plan = SyncPlan.make(historyDays: 3, today: today, calendar: calendar, ledger: ledger)
        XCTAssertEqual(plan.days, [SyncPlan.Day(offset: 0, position: 1), SyncPlan.Day(offset: 1, position: 1),
                                   SyncPlan.Day(offset: 2, position: 1)])
    }

    func testRecordCompletesAPastDayOnlyWithTheEndMarkerAndEveryBlock() {
        let all = Set(1...28)
        XCTAssertTrue(SyncPlan.record(nil, offset: 1, position: 1, records: all, totalBlocks: 28, endMarker: true).complete)
        XCTAssertFalse(SyncPlan.record(nil, offset: 1, position: 1, records: Set(1...27), totalBlocks: 28, endMarker: true).complete,
                       "a record lost to a CRC failure keeps the day open")
        XCTAssertFalse(SyncPlan.record(nil, offset: 1, position: 1, records: all, totalBlocks: 28, endMarker: false).complete,
                       "the stall watchdog closing the day is not a complete transfer")
        XCTAssertFalse(SyncPlan.record(nil, offset: 0, position: 1, records: all, totalBlocks: 28, endMarker: true).complete,
                       "today is never complete — it keeps growing")
        XCTAssertTrue(SyncPlan.record(nil, offset: 4, position: 1, records: [], totalBlocks: nil, endMarker: true).complete,
                      "a day the ring holds nothing for (end marker at once) is done")
    }

    func testRecordResumeContinuesTheUnbrokenRun() {
        let first = SyncPlan.record(nil, offset: 0, position: 1, records: Set(1...56), totalBlocks: 56, endMarker: true)
        XCTAssertEqual(first, SyncPlan.DayState(storedThrough: 56, totalBlocks: 56, complete: false))
        // The resume from 57 brought 57–60.
        let second = SyncPlan.record(first, offset: 0, position: 57, records: Set(57...60), totalBlocks: 60, endMarker: true)
        XCTAssertEqual(second, SyncPlan.DayState(storedThrough: 60, totalBlocks: 60, complete: false))
        // A resume past the last record answers only the end marker: nothing changes.
        let third = SyncPlan.record(second, offset: 0, position: 61, records: [], totalBlocks: nil, endMarker: true)
        XCTAssertEqual(third, second)
    }

    /// Records 1–10 and 12–20 stored (11 lost to a checksum failure): today resumes at 11, so the gap is asked
    /// for again instead of being skipped over (Android's rule).
    func testAMissingRecordMidDayIsAskedForAgain() {
        let records = Set(1...10).union(12...20)
        let today0 = SyncPlan.record(nil, offset: 0, position: 1, records: records, totalBlocks: 20, endMarker: true)
        XCTAssertEqual(today0.storedThrough, 10)
        let plan = SyncPlan.make(historyDays: 7, today: today, calendar: calendar, ledger: [key(0): today0])
        XCTAssertEqual(plan.days.first, SyncPlan.Day(offset: 0, position: 11))
        // The re-ask brings 11–20 and closes the gap.
        let after = SyncPlan.record(today0, offset: 0, position: 11, records: Set(11...20), totalBlocks: 20, endMarker: true)
        XCTAssertEqual(after.storedThrough, 20)
        // The same gap on a past day keeps it open (the run is 10 < total 20).
        XCTAssertFalse(SyncPlan.record(nil, offset: 1, position: 1, records: records, totalBlocks: 20, endMarker: true).complete)
        XCTAssertTrue(SyncPlan.record(nil, offset: 1, position: 1, records: Set(1...20), totalBlocks: 20, endMarker: true).complete)
    }

    func testStoreKeepsLedgersPerRingAndResets() {
        let store = SyncPlanStore(defaults: freshDefaults())
        store.set(done(10), ring: "A", date: key(1), today: today, calendar: calendar)
        store.set(done(12), ring: "B", date: key(1), today: today, calendar: calendar)
        XCTAssertEqual(store.state(ring: "A", date: key(1))?.totalBlocks, 10)
        XCTAssertEqual(store.state(ring: "B", date: key(1))?.totalBlocks, 12)
        store.reset(ring: "A")
        XCTAssertTrue(store.ledger(ring: "A").isEmpty, "a new pairing of A starts over")
        XCTAssertFalse(store.ledger(ring: "B").isEmpty)
        store.resetAll()
        XCTAssertTrue(store.ledger(ring: "B").isEmpty)
    }

    // MARK: - SyncPlan in the day loop

    private final class RingWriter: RingCommandWriter {
        var ring: String?
        init(ring: String?) { self.ring = ring }
        var historyRingID: String? { ring }
        var commands: [Data] = []
        var emitted: [RingDecodedEvent] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
        var historyRequests: [[UInt8]] {
            commands.filter { $0.first == 0xE0 || $0.first == 0xDF }.map { Array([UInt8]($0).prefix(4)) }
        }
        var progress: [SyncDayProgress] {
            emitted.compactMap { if case let .historyDayProgress(p) = $0 { return p }; return nil }
        }
    }

    private var writer = RingWriter(ring: nil)
    private var suites: [String] = []

    private func freshDefaults() -> UserDefaults {
        let name = "SyncPlanTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        super.tearDown()
    }

    private func hex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            data.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func pad(_ data: Data) -> Data { data + Data(count: max(0, 20 - data.count)) }

    /// One DF record numbered `number` (the decoder test's fixture) with a part-00 header saying the day has
    /// `total` records in 2 parts (valid count 0 = no CRC check).
    private func record(_ number: Int, total: Int) -> [Data] {
        let slot = String(format: "%02x", number)
        let header = pad(hex("df\(slot)0000" + String(format: "%02x%02x", total & 0xFF, total >> 8) + "02000000"))
        return [header,
                hex("df\(slot)0001" + "b104090b0a05b20a0343000002c2019b0000b4053c4b605550"),
                hex("df\(slot)0002" + "b7042c5b6dffb8027453b907606162636400ffbe02b601c10114")]
    }

    private func feed(_ engine: VeepooSyncEngine, _ frames: [Data]) {
        for data in frames { engine.handle(.unknown(commandId: data[0], raw: data)) }
    }

    private let end = Data([0xDF, 0xFF, 0xFF, 0x58]) + Data(count: 16)
    private func noSleep(_ day: Int) -> Data { Data([0xE0, 0x00, 0x00, UInt8(day)]) + Data(count: 16) }

    /// Serve the pass the engine asks for: each requested day answers no sleep, then records from the DF
    /// position up to `recordsPerDay[day]`, then the end marker. Returns the (day, position) pairs asked.
    @discardableResult
    private func servePass(_ engine: VeepooSyncEngine, recordsPerDay: [Int: Int]) -> [[Int]] {
        var asked: [[Int]] = []
        var served = 0
        while served < writer.historyRequests.count {
            let request = writer.historyRequests[served]
            served += 1
            if request[0] == 0xE0 {
                feed(engine, [noSleep(Int(request[1]))])
            } else {
                let day = Int(request[3]), position = Int(request[1]) | Int(request[2]) << 8
                asked.append([day, position])
                let total = recordsPerDay[day] ?? 0
                if position <= total {
                    for number in position...total { feed(engine, record(number, total: total)) }
                }
                feed(engine, [end])
            }
        }
        return asked
    }

    private func makeEngine(ring: String?, store: SyncPlanStore, days: Int = 7) -> VeepooSyncEngine {
        writer = RingWriter(ring: ring)
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: days)
        engine.syncPlanStore = store
        engine.now = { self.today }
        engine.connectionDidStart()
        return engine
    }

    func testFirstPassIsFullThenARefreshAsksOnlyForTodayFromTheResumePosition() {
        let store = SyncPlanStore(defaults: freshDefaults())
        let data = [0: 20, 1: 30, 2: 25]            // days 3–6 are past the ring's retention
        let engine = makeEngine(ring: "ring-A", store: store)
        engine.handle(.commandAck(commandId: 0xA1))
        let first = servePass(engine, recordsPerDay: data)
        XCTAssertEqual(first, (0..<7).map { [$0, 1] }, "a new ring: every day from position 1")
        XCTAssertTrue(writer.progress.allSatisfy { $0.totalDays == 7 })
        XCTAssertTrue(store.state(ring: "ring-A", date: key(1))?.complete == true)
        XCTAssertTrue(store.state(ring: "ring-A", date: key(5))?.complete == true, "an empty past day is done too")
        XCTAssertEqual(store.state(ring: "ring-A", date: key(0))?.storedThrough, 20)

        // Today grew by four records; a refresh on the same link (`syncHistory`, the periodic top-up):
        writer.commands.removeAll()
        writer.emitted.removeAll()
        engine.syncHistory()
        let second = servePass(engine, recordsPerDay: [0: 24, 1: 30, 2: 25])
        XCTAssertEqual(second, [[0, 21]], "only today, from last stored + 1")
        XCTAssertEqual(writer.progress.map(\.totalDays), [1, 1])
        XCTAssertEqual(store.state(ring: "ring-A", date: key(0))?.storedThrough, 24)
        engine.connectionDidEnd()
    }

    func testReconnectRequestsOnlyDayZeroFromTheResumePosition() {
        let store = SyncPlanStore(defaults: freshDefaults())
        var engine = makeEngine(ring: "ring-A", store: store)
        engine.handle(.commandAck(commandId: 0xA1))
        servePass(engine, recordsPerDay: [0: 20, 1: 30, 2: 25])

        // A new connection to the same ring, later the same day: today has 24 records now.
        engine = makeEngine(ring: "ring-A", store: store)
        engine.handle(.commandAck(commandId: 0xA1))
        let asked = servePass(engine, recordsPerDay: [0: 24, 1: 30, 2: 25])
        XCTAssertEqual(asked, [[0, 21]], "only day 0, from the record after the last stored one")
        XCTAssertEqual(writer.historyRequests, [[0xE0, 0x00, 0x00, 0x00], [0xDF, 21, 0x00, 0x00]])
        XCTAssertEqual(writer.progress.map(\.totalDays), [1, 1], "SyncProgress: Day 1 of 1")
        XCTAssertEqual(writer.progress.first?.days, [0])
        XCTAssertEqual(store.state(ring: "ring-A", date: key(0))?.storedThrough, 24)
        XCTAssertTrue(writer.emitted.contains { if case .historySyncFinished = $0 { return true }; return false })

        // The progress model shows it as one day.
        let progress = SyncProgress(notifications: AgaraNotifications(isAppInBackground: false, deliver: { _ in }, removeDelivered: { _ in }))
        for p in writer.progress.prefix(1) { progress.apply(p) }
        XCTAssertEqual(progress.totalDays, 1)
        XCTAssertEqual(progress.progressSummary, "Day 1 of 1")
    }

    func testAnotherRingOrAnInterruptedDayIsFetchedInFull() {
        let store = SyncPlanStore(defaults: freshDefaults())
        var engine = makeEngine(ring: "ring-A", store: store, days: 3)
        engine.handle(.commandAck(commandId: 0xA1))
        servePass(engine, recordsPerDay: [0: 5, 1: 6, 2: 7])

        engine = makeEngine(ring: "ring-B", store: store, days: 3)
        engine.handle(.commandAck(commandId: 0xA1))
        XCTAssertEqual(servePass(engine, recordsPerDay: [0: 5, 1: 6, 2: 7]), [[0, 1], [1, 1], [2, 1]],
                       "a different ring has no ledger")

        // Day 1 of ring A lost a record (CRC): it stays open and comes back in full next time.
        var state = store.state(ring: "ring-A", date: key(1))!
        state.storedThrough = 5
        state.complete = false
        store.set(state, ring: "ring-A", date: key(1), today: today, calendar: calendar)
        engine = makeEngine(ring: "ring-A", store: store, days: 3)
        engine.handle(.commandAck(commandId: 0xA1))
        XCTAssertEqual(servePass(engine, recordsPerDay: [0: 5, 1: 6, 2: 7]), [[0, 6], [1, 1]])
        XCTAssertTrue(store.state(ring: "ring-A", date: key(1))?.complete == true)
    }

    func testNoRingIdentityKeepsTheFullSevenDayWalk() {
        let store = SyncPlanStore(defaults: freshDefaults())
        for _ in 0..<2 {
            let engine = makeEngine(ring: nil, store: store)
            engine.handle(.commandAck(commandId: 0xA1))
            XCTAssertEqual(servePass(engine, recordsPerDay: [0: 3]), (0..<7).map { [$0, 1] })
        }
        XCTAssertTrue(store.ledger(ring: "").isEmpty)
    }
}
