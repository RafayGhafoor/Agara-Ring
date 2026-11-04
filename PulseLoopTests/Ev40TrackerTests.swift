import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// The EV40 Daily Tracker (1.1): the discipline bit map, the mask arithmetic, the local day key, the store, the wire
/// row and the sync rules (cloud-v2 §2.1/§3.2).
///
/// The cases that earn their place here (Rule 20): the boundary values of the mask (0, 255, an unknown bit), the
/// first/last day of a list, a new local day starting empty while yesterday keeps its ticks, the second occurrence
/// (a day the server already acknowledged is not sent again), and a pulled row that must not overwrite an unsent
/// local tick.
@MainActor
final class Ev40TrackerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    /// 2026-11-04T09:00:00Z — a Wednesday, the day the reference design shows.
    private static let now = Date(timeIntervalSince1970: 1_793_782_800)

    override func setUp() async throws {
        container = try ModelContainerFactory.make(inMemory: true)
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - The bit map is a wire format

    func testBitOrderIsPinnedAndAppendOnly() {
        // The server stores the number, Android reads the same bits: renumbering a discipline would silently move a
        // tick to a different discipline on the other platform (cloud-v2 §3.2).
        XCTAssertEqual(Ev40Discipline.hydrate.rawValue, 0)
        XCTAssertEqual(Ev40Discipline.move.rawValue, 1)
        XCTAssertEqual(Ev40Discipline.grow.rawValue, 2)
        XCTAssertEqual(Ev40Discipline.fuel.rawValue, 3)
        XCTAssertEqual(Ev40Discipline.energize.rawValue, 4)
        XCTAssertEqual(Ev40Discipline.fastRelease.rawValue, 5)
        XCTAssertEqual(Ev40Discipline.documentShare.rawValue, 6)
        XCTAssertEqual(Ev40Discipline.rest.rawValue, 7)
        XCTAssertEqual(Ev40Discipline.hydrate.bit, 1)
        XCTAssertEqual(Ev40Discipline.rest.bit, 128)
        XCTAssertEqual(Ev40Disciplines.fullMask, 255)
        XCTAssertEqual(Ev40Disciplines.all.map(\.title), [
            AgaraCopy.ev40DisciplineHydrate, AgaraCopy.ev40DisciplineMove, AgaraCopy.ev40DisciplineGrow,
            AgaraCopy.ev40DisciplineFuel, AgaraCopy.ev40DisciplineEnergize, AgaraCopy.ev40DisciplineFastRelease,
            AgaraCopy.ev40DisciplineDocumentShare, AgaraCopy.ev40DisciplineRest,
        ])
    }

    func testMaskArithmetic() {
        XCTAssertEqual(Ev40Disciplines.count(0), 0)
        XCTAssertEqual(Ev40Disciplines.count(255), 8)
        XCTAssertEqual(Ev40Disciplines.count(1 | 4 | 16), 3)
        XCTAssertFalse(Ev40Disciplines.isOn(0, .rest))
        XCTAssertTrue(Ev40Disciplines.isOn(255, .rest))

        // toggle flips exactly one bit, and toggling twice is the identity (the boundary case: on and off again)
        let one = Ev40Disciplines.toggle(0, .hydrate)
        XCTAssertEqual(one, 1)
        XCTAssertEqual(Ev40Disciplines.toggle(one, .hydrate), 0)

        // an unknown bit can never be reached through the app, and is dropped on the way in (the server allows 0…255)
        XCTAssertEqual(Ev40Disciplines.normalised(0b1_0110_0101), 0b0110_0101)
        XCTAssertEqual(Ev40Disciplines.normalised(255), 255)
        XCTAssertEqual(Ev40Disciplines.normalised(-1), 255)   // masked, never a crash

        XCTAssertFalse(Ev40Disciplines.isComplete(254))
        XCTAssertTrue(Ev40Disciplines.isComplete(255))
    }

    // MARK: - The local day key

    func testDayKeyFollowsTheLocalDateNotUTC() {
        // 23:30 on the 3rd in UTC+14 is already the 4th locally; 00:30 UTC on the 4th in UTC-8 is still the 3rd.
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let utcLate = Date(timeIntervalSince1970: 1_793_755_800)   // 2026-11-03T23:30:00Z
        XCTAssertEqual(Ev40Repo.dayKey(utcLate, calendar: kiritimati), "2026-11-04")
        XCTAssertEqual(Ev40Repo.dayKey(utcLate, calendar: losAngeles), "2026-11-03")

        // A DST change does not shift the key: 2026-11-01 in Los Angeles is the fall-back day.
        let around = Date(timeIntervalSince1970: 1_793_571_600)   // 2026-11-01T14:00:00Z
        XCTAssertEqual(Ev40Repo.dayKey(around, calendar: losAngeles), "2026-11-01")
        XCTAssertEqual(Ev40Repo.dayKey(around.addingTimeInterval(12 * 3600), calendar: losAngeles), "2026-11-02")
    }

    func testDisplayDateIsLocalisedWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let text = Ev40Repo.displayDate("2026-11-04", calendar: calendar)
        XCTAssertTrue(text.contains("Nov") || text.contains("11"), text)
        XCTAssertEqual(Ev40Repo.displayDate("not-a-date", calendar: calendar), "not-a-date")
    }

    // MARK: - Store

    func testTodayStartsEmptyAndYesterdayKeepsItsTicks() {
        // A new local day is simply a key with no row: there is no reset job to get wrong.
        XCTAssertEqual(Ev40Repo.todayMask(context: context, now: Self.now), 0)

        Ev40Repo.toggle(.hydrate, context: context, now: Self.now)
        Ev40Repo.toggle(.move, context: context, now: Self.now)
        XCTAssertEqual(Ev40Repo.todayMask(context: context, now: Self.now), 3)

        let tomorrow = Self.now.addingTimeInterval(24 * 3600)
        XCTAssertEqual(Ev40Repo.todayMask(context: context, now: tomorrow), 0)
        Ev40Repo.toggle(.rest, context: context, now: tomorrow)
        XCTAssertEqual(Ev40Repo.todayMask(context: context, now: tomorrow), 128)
        XCTAssertEqual(Ev40Repo.todayMask(context: context, now: Self.now), 3)   // yesterday is untouched

        // one row per day, newest first
        let rows = Ev40Repo.history(context: context)
        XCTAssertEqual(rows.count, 2)
        XCTAssertGreaterThan(rows[0].dateKey, rows[1].dateKey)
    }

    func testAnAllZeroDayIsNotAHistoryEntry() {
        _ = Ev40Repo.row("2026-11-02", creating: context)   // a day the screen was opened on, nothing ticked
        Ev40Repo.toggle(.fuel, context: context, now: Self.now)
        try? context.save()
        XCTAssertEqual(Ev40Repo.history(context: context).count, 2)
        XCTAssertEqual(Ev40Repo.log(context: context).map(\.dateKey), [Ev40Repo.dayKey(Self.now)])
    }

    func testToggleMarksTheRowUnsent() {
        Ev40Repo.toggle(.energize, context: context, now: Self.now)
        let day = try? XCTUnwrap(Ev40Repo.today(context: context, now: Self.now))
        XCTAssertEqual(day?.mask, 16)
        XCTAssertEqual(day?.ackedMask, 0)
        XCTAssertTrue(day?.hasUnsentChange == true)
        XCTAssertEqual(day?.completedCount, 1)
        XCTAssertFalse(day?.isComplete == true)
    }

    // MARK: - Wire

    func testUploadRowCarriesDateAndMaskOnly() {
        let day = Ev40Day(dateKey: "2026-11-04", mask: 165)
        XCTAssertEqual(WireBlockBuilder.json(dateKey: day.dateKey, mask: day.mask), #"{"date":"2026-11-04","mask":165}"#)
        // an out-of-range mask cannot reach the wire
        XCTAssertEqual(WireBlockBuilder.json(dateKey: "2026-11-04", mask: 0x1FF), #"{"date":"2026-11-04","mask":255}"#)
    }

    func testPulledRowDecodesTolerantly() throws {
        let json = #"{"date":"2026-11-04","mask":165,"updated_at":1790400000000}"#
        let row = try JSONDecoder().decode(WireEv40Day.self, from: Data(json.utf8))
        XCTAssertEqual(row, WireEv40Day(date: "2026-11-04", mask: 165, updatedAt: 1_790_400_000_000))

        // a mask beyond the eight bits and a missing stamp read safely
        let loose = try JSONDecoder().decode(WireEv40Day.self, from: Data(#"{"date":"2026-11-04","mask":511}"#.utf8))
        XCTAssertEqual(loose.mask, 255)
        XCTAssertEqual(loose.updatedAt, 0)
    }

    // MARK: - Sync rules (fake cloud, one account)

    func testPendingSelectsOnlyUnsentRowsOldestFirst() throws {
        let sent = Ev40Day(dateKey: "2026-11-01", mask: 3, ackedMask: 3, serverUpdatedAt: Self.now)
        let a = Ev40Day(dateKey: "2026-11-02", mask: 4)
        let b = Ev40Day(dateKey: "2026-11-03", mask: 8)
        [b, sent, a].forEach { context.insert($0) }
        try context.save()

        let pending = AgaraCloudTracker.pending(context: context)
        XCTAssertEqual(pending.map(\.dateKey), ["2026-11-02", "2026-11-03"])
        XCTAssertEqual(AgaraCloudTracker.payload(pending),
                       [#"{"date":"2026-11-02","mask":4}"#, #"{"date":"2026-11-03","mask":8}"#])
        // the cap is the server's per-request limit
        XCTAssertEqual(AgaraCloudTracker.pending(context: context, limit: 1).count, 1)
    }

    func testMarkSyncedKeepsTheServersStamp() throws {
        let day = Ev40Day(dateKey: "2026-11-04", mask: 5)
        context.insert(day)
        try context.save()
        let stamp = Date(timeIntervalSince1970: 1_790_400_000)
        AgaraCloudTracker.mark(synced: [(day, 5, stamp)], context: context)
        XCTAssertEqual(day.ackedMask, 5)
        XCTAssertEqual(day.serverUpdatedAt, stamp)
        XCTAssertFalse(day.hasUnsentChange)
    }

    func testPulledRowWinsOnlyWhenNewer() throws {
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let local = Ev40Day(dateKey: "2026-11-02", mask: 3, ackedMask: 3, serverUpdatedAt: stamp)
        context.insert(local)
        try context.save()

        // older → ignored
        var result = AgaraCloudTracker.applyPulled(
            [WireEv40Day(date: "2026-11-02", mask: 255, updatedAt: Int64(stamp.timeIntervalSince1970 * 1000) - 1)],
            context: context)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(local.mask, 3)

        // newer → applied, and the row is acknowledged at the server's stamp
        let newer = Date(timeIntervalSince1970: stamp.timeIntervalSince1970 + 60)
        result = AgaraCloudTracker.applyPulled(
            [WireEv40Day(date: "2026-11-02", mask: 9, updatedAt: Int64(newer.timeIntervalSince1970 * 1000))],
            context: context)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(local.mask, 9)
        XCTAssertEqual(local.ackedMask, 9)
        XCTAssertEqual(local.serverUpdatedAt, newer)
    }

    func testPulledRowNeverOverwritesAnUnsentTick() throws {
        let local = Ev40Day(dateKey: "2026-11-02", mask: 4, ackedMask: 0)   // ticked here, never uploaded
        context.insert(local)
        try context.save()

        let result = AgaraCloudTracker.applyPulled(
            [WireEv40Day(date: "2026-11-02", mask: 255, updatedAt: 1_790_400_000_000)], context: context)
        XCTAssertEqual(local.mask, 4)         // the tick is not lost to a pull
        XCTAssertTrue(result.needsUpload)     // … and the engine runs another round to send it
    }

    func testPulledRowForAnUnknownDayIsInsertedAcknowledged() throws {
        let result = AgaraCloudTracker.applyPulled(
            [WireEv40Day(date: "2026-10-30", mask: 200, updatedAt: 1_790_400_000_000)], context: context)
        XCTAssertTrue(result.changed)
        let row = try XCTUnwrap(Ev40Repo.row("2026-10-30", context: context))
        XCTAssertEqual(row.mask, 200)
        XCTAssertEqual(row.ackedMask, 200)
        XCTAssertFalse(row.hasUnsentChange)   // nothing to send back
    }

    // MARK: - End to end through the sync engine and the fake cloud

    @MainActor
    func testATickReachesTheServerAndTheSecondRunSendsNothing() async throws {
        let device = try await CloudDevice.make(email: "ev40a@example.com")
        Ev40Repo.toggle(.hydrate, context: device.context, now: CloudDevice.now)
        Ev40Repo.toggle(.fuel, context: device.context, now: CloudDevice.now)

        let first = try await device.engine.run()
        XCTAssertEqual(first.trackerSent, 1)
        let stored = device.backend.serverTracker(email: "ev40a@example.com")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.values.first?.mask, 1 | 8)
        let row = try XCTUnwrap(Ev40Repo.today(context: device.context, now: CloudDevice.now))
        XCTAssertFalse(row.hasUnsentChange)
        XCTAssertNotNil(row.serverUpdatedAt)

        // Second occurrence: an acknowledged day is not sent again (the request would be an empty one).
        let second = try await device.engine.run()
        XCTAssertEqual(second.trackerSent, 0)
    }

    @MainActor
    func testAnUnchangedMaskIsAnsweredDuplicate() async throws {
        let device = try await CloudDevice.make(email: "ev40b@example.com")
        Ev40Repo.toggle(.rest, context: device.context, now: CloudDevice.now)
        _ = try await device.engine.run()

        // The same mask re-queued (as an import or a restored backup would) is accepted as already held.
        let row = try XCTUnwrap(Ev40Repo.today(context: device.context, now: CloudDevice.now))
        row.ackedMask = 0
        try device.context.save()
        let again = try await device.engine.run()
        XCTAssertEqual(again.trackerSent, 1)
        XCTAssertEqual(device.backend.serverTracker(email: "ev40b@example.com").values.first?.mask, 128)
    }

    @MainActor
    func testAnotherDevicesTicksArriveOnThePull() async throws {
        let backend = FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let a = try await CloudDevice.make(backend: backend, email: "ev40c@example.com")
        let b = try await CloudDevice.make(backend: backend, email: "ev40c@example.com", createUser: false, signIn: true)

        Ev40Repo.toggle(.grow, context: a.context, now: CloudDevice.now)
        Ev40Repo.toggle(.move, context: a.context, now: CloudDevice.now)
        _ = try await a.engine.run()

        _ = try await b.engine.run()   // B's pull brings A's day
        let onB = try XCTUnwrap(Ev40Repo.today(context: b.context, now: CloudDevice.now))
        XCTAssertEqual(onB.mask, Ev40Discipline.move.bit | Ev40Discipline.grow.bit)   // 2 | 4
        XCTAssertFalse(onB.hasUnsentChange)

        // B ticks a third discipline; A sees it after its own pass.
        Ev40Repo.toggle(.rest, context: b.context, now: CloudDevice.now)
        _ = try await b.engine.run()
        _ = try await a.engine.run()
        XCTAssertEqual(Ev40Repo.todayMask(context: a.context, now: CloudDevice.now),
                       Ev40Discipline.move.bit | Ev40Discipline.grow.bit | Ev40Discipline.rest.bit)
    }

    @MainActor
    func testDeleteAllDataRemovesTheLog() async throws {
        Ev40Repo.toggle(.hydrate, context: context, now: Self.now)
        try context.save()
        XCTAssertEqual(Ev40Repo.history(context: context).count, 1)
        SeedData.clearAll(context)
        XCTAssertTrue(Ev40Repo.history(context: context).isEmpty)
    }

    func testArchiveRoundTripCarriesTheLog() throws {
        Ev40Repo.toggle(.fuel, context: context, now: Self.now)
        Ev40Repo.toggle(.rest, context: context, now: Self.now)
        let row = try XCTUnwrap(Ev40Repo.today(context: context, now: Self.now))
        let archived = ArchiveEv40Day(row)
        XCTAssertEqual(archived.dateKey, Ev40Repo.dayKey(Self.now))
        XCTAssertEqual(archived.mask, Ev40Discipline.fuel.bit | Ev40Discipline.rest.bit)   // 8 | 128

        let restored = try ModelContainerFactory.make(inMemory: true)
        archived.insert(into: restored.mainContext)
        XCTAssertEqual(Ev40Repo.history(context: restored.mainContext).map(\.mask),
                       [Ev40Discipline.fuel.bit | Ev40Discipline.rest.bit])
        // the sync bookkeeping is per device: a restored row uploads once (the server answers duplicate if unchanged)
        XCTAssertTrue(Ev40Repo.history(context: restored.mainContext)[0].hasUnsentChange)
    }
}
