import XCTest
@testable import PulseLoop

/// BUG-211's deterministic trigger: a ring that comes back on different firmware has had its history rewritten
/// (a flash clears it), so the ledger that firmware wrote must not outlive it.
///
/// The record-1 probe that this replaces is impossible with this protocol, not merely expensive: `df` carries no
/// count selector, so the ring streams **from the requested position to the end of the day** and attaches the
/// count header only to records it sends. A resume past the end therefore answers the end marker alone — no
/// header, no count — and learning the count means re-reading the whole day. The emulator mirrors the ring
/// (`ring-emulator/emulator/server.py`, `send_day`: `serves 0 records, no header`).
@MainActor
final class SyncPlanFirmwareTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SyncPlanStore!
    /// One isolated defaults suite per engine, cleaned up in `tearDown` — `SyncPlanStore.shared` rides
    /// `UserDefaults.standard`, and a remembered firmware version leaking between tests makes the second test
    /// see a "change" that never happened (this bit BUG-213's author, in this very file).
    private var scratchSuites: [UserDefaults] = []

    /// An engine whose ledger store is this test's own, so nothing leaks in or out.
    private func isolatedEngine(_ writer: RecordingWriter, historyDays: Int = 1) -> VeepooSyncEngine {
        let suite = UserDefaults(suiteName: "firmware-engine-\(UUID().uuidString)")!
        scratchSuites.append(suite)
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: historyDays)
        engine.syncPlanStore = SyncPlanStore(defaults: suite)
        engine.now = { Self.fixtureDay }
        return engine
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "firmware-\(UUID().uuidString)")
        store = SyncPlanStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        for suite in scratchSuites { suite.removePersistentDomain(forName: suite.description) }
        scratchSuites = []
        store = nil
        defaults = nil
        super.tearDown()
    }

    private var day: SyncPlan.DayState {
        SyncPlan.DayState(storedThrough: 93, totalBlocks: 93, sleepStored: true, complete: false)
    }

    // MARK: the store's half

    func testTheFirstFirmwareSeenOnARingIsRememberedWithoutClearingAnything() {
        XCTAssertNil(store.firmware(ring: "ring-A"), "a ring never synced before has no remembered firmware")
        store.set(.init(storedThrough: 93, totalBlocks: 93), ring: "ring-A", date: "2026-10-29")

        store.setFirmware("00.12.09", ring: "ring-A")

        XCTAssertEqual(store.firmware(ring: "ring-A"), "00.12.09")
        XCTAssertEqual(store.ledger(ring: "ring-A").count, 1, "remembering a version must not touch the ledger")
    }

    func testForgettingAllDropsTheRememberedFirmwareToo() {
        store.setFirmware("00.12.09", ring: "ring-A")
        store.resetAll()
        XCTAssertNil(store.firmware(ring: "ring-A"), "a forgotten ring must not look like it is on the old firmware")
    }

    func testResettingOneRingKeepsTheRememberedVersionAndOtherRings() {
        store.set(day, ring: "ring-A", date: "2026-10-29")
        store.set(day, ring: "ring-B", date: "2026-10-29")
        store.setFirmware("00.12.09", ring: "ring-A")
        store.setFirmware("00.11.01", ring: "ring-B")

        store.reset(ring: "ring-A")

        XCTAssertEqual(store.ledger(ring: "ring-A").count, 0, "the flush ring's ledger is gone")
        XCTAssertEqual(store.ledger(ring: "ring-B").count, 1, "the other ring is untouched")
        XCTAssertEqual(store.firmware(ring: "ring-A"), "00.12.09", "the version stays: it says the change is handled")
        XCTAssertEqual(store.firmware(ring: "ring-B"), "00.11.01")
    }

    func testAWatermarkClearedByAResetAsksFromTheFirstRecordAgain() {
        store.set(day, ring: "ring-A", date: "2026-10-29")
        XCTAssertEqual(store.state(ring: "ring-A", date: "2026-10-29")?.nextPosition, 94,
                       "the stale watermark asks past a day the ring now holds 0 of")

        store.reset(ring: "ring-A")

        XCTAssertNil(store.state(ring: "ring-A", date: "2026-10-29"))
        let plan = SyncPlan.make(historyDays: 1, today: Date(), calendar: .current, ledger: store.ledger(ring: "ring-A"))
        XCTAssertEqual(plan.days.map(\.position), [1], "day 0 is asked from record 1 again")
    }

    // MARK: the engine's half

    /// The whole point: the same ring, a different firmware, and the day the app thought it had 93 records of is
    /// read again instead of resumed past.
    func testADifferentFirmwareOnTheSameRingClearsItsLedgerAndAnnouncesIt() {
        let writer = RecordingWriter()
        writer.source = "ring-A"
        let engine = isolatedEngine(writer)
        engine.connectionDidStart()

        // First connect: remember the firmware that wrote the ledger.
        engine.handle(.firmware(version: "00.12.09", deviceNumber: nil, testVersion: nil))
        engine.syncPlanStore.set(
            SyncPlan.DayState(storedThrough: 93, totalBlocks: 93, sleepStored: true),
            ring: "ring-A", date: SyncPlan.dateKey(offset: 0, today: Self.fixtureDay, calendar: .current)
        )

        // Same firmware again: nothing to do.
        engine.handle(.firmware(version: "00.12.09", deviceNumber: nil, testVersion: nil))
        XCTAssertEqual(engine.syncPlanStore.ledger(ring: "ring-A").count, 1, "an unchanged firmware keeps the ledger")
        XCTAssertFalse(writer.stages.contains { $0.contains("re-reading") })

        // Flashed: the ring's history is not what the app's watermark describes.
        engine.handle(.firmware(version: "00.13.01", deviceNumber: nil, testVersion: nil))

        XCTAssertEqual(engine.syncPlanStore.ledger(ring: "ring-A").count, 0, "the ledger is cleared")
        XCTAssertEqual(engine.syncPlanStore.firmware(ring: "ring-A"), "00.13.01")
        XCTAssertTrue(writer.stages.contains { $0.contains("firmware 00.12.09 → 00.13.01") && $0.contains("re-reading") },
                      "the pass says why it starts over: \(writer.stages)")
    }

    func testThePassAfterAFirmwareChangeAsksForDayZeroFromTheFirstRecord() {
        let writer = RecordingWriter()
        writer.source = "ring-A"
        let engine = isolatedEngine(writer)
        engine.connectionDidStart()
        // A stale ledger: the app believes all 93 of today's records are stored.
        engine.syncPlanStore.set(
            SyncPlan.DayState(storedThrough: 93, totalBlocks: 93, sleepStored: true),
            ring: "ring-A", date: SyncPlan.dateKey(offset: 0, today: Self.fixtureDay, calendar: .current)
        )
        engine.handle(.firmware(version: "00.12.09", deviceNumber: nil, testVersion: nil))
        engine.handle(.commandAck(commandId: 0xA1))
        engine.handle(.unknown(commandId: 0xE0, raw: sleepNoData))
        // The pass planned from that ledger resumes at 94 — the state BUG-211 describes. The ring answers the
        // end marker alone, so the watermark cannot move: this is why the empty answer cannot fix itself.
        XCTAssertTrue(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0, position: 94)),
                      "precondition: the stale watermark asks past the day")
        engine.handle(.unknown(commandId: 0xDF, raw: dailyEnd))
        XCTAssertEqual(engine.syncPlanStore.state(ring: "ring-A", date: Self.todayKey)?.storedThrough, 93,
                       "an end-marker-only answer leaves the watermark where it was")
        writer.commands.removeAll()

        // Flashed ring, then the next pass.
        engine.handle(.firmware(version: "00.13.01", deviceNumber: nil, testVersion: nil))
        engine.syncHistory()
        engine.handle(.unknown(commandId: 0xE0, raw: sleepNoData))

        XCTAssertTrue(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0, position: 1)),
                      "the new firmware's history is read from record 1; asked "
                          + "\(writer.commands.map { $0.hexString.prefix(8) })")
        XCTAssertFalse(writer.asked(VeepooEncoder.dailyHistory(dayOffset: 0, position: 94)),
                       "and the phantom position is never asked for again")
    }

    /// `df ff ff` — what the ring answers when a day has nothing left to serve (`frames.daily_end`).
    private let dailyEnd = Data([0xDF, 0xFF, 0xFF, 0x58])
    /// `e0 00 00 <day>` — the ring kept no sleep for the day, which completes the sleep phase.
    private let sleepNoData = Data([0xE0, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 16))

    private static var todayKey: String {
        SyncPlan.dateKey(offset: 0, today: fixtureDay, calendar: .current)
    }

    private static let fixtureDay =
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 23, minute: 30))!

    private final class RecordingWriter: RingCommandWriter {
        var deviceIdentifier: String? { nil }
        var source: String?
        var commands: [Data] = []
        var emitted: [RingDecodedEvent] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            commands.append(command)
            completion(.success(()))
        }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
        var connectionSource: String? { source }
        func asked(_ frame: Data) -> Bool { commands.contains(frame) }
        var stages: [String] {
            emitted.compactMap {
                if case let .historySyncProgress(stage) = $0 { return stage }
                return nil
            }
        }
    }
}
