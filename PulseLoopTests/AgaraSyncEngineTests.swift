import SwiftData
import XCTest
@testable import PulseLoop

/// Sync engine v2 (release 1.1, task 3) against the in-process fake server: batching by the catalog limits, per-block
/// results, `merged` → pull → union, the cursor, tombstones, resumability after a dropped connection, the 401 / 403 /
/// 429 / 5xx behaviour, and the rule that sample data and `mock` rows never leave the phone.
@MainActor
final class AgaraSyncEngineTests: XCTestCase {
    private var backend: FakeCloudBackend!
    private let email = "user@example.com"

    override func setUp() async throws {
        backend = FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
    }

    private func limits(blocks: Int = 500, days: Int = 400, bytes: Int = 4_194_304, page: Int = 200) -> AgaraSyncLimits {
        AgaraSyncLimits(maxBlocks: blocks, maxDayRows: days, maxBodyBytes: bytes, pullPageSize: page, maxRounds: 4)
    }

    /// Ten blocks: eight sealed days of heart rate + two open days (snapshots).
    private func populate(_ device: CloudDevice, sealedDays: Int = 8, openDays: Int = 2) throws {
        for i in 0..<sealedDays { device.addSeries(day: device.today - 12 - Int64(i)) }
        for i in 0..<openDays { device.addSeries(day: device.today - 1 - Int64(i), kind: .spo2, value: { _ in 97 }) }
        try device.compact()
    }

    // MARK: Guards

    func testRefusesWithoutConsentWithoutAVerifiedAccountAndWhileSampleDataShows() async throws {
        let noConsent = try await CloudDevice.make(backend: backend, consent: false)
        await assertRefusal(noConsent, .noConsent)

        let signedOut = try await CloudDevice.make(backend: backend, email: "b@example.com", signIn: false)
        await assertRefusal(signedOut, .notSignedIn)

        let unverified = try await CloudDevice.make(backend: backend, email: "c@example.com", verified: false)
        await assertRefusal(unverified, .emailNotVerified)

        let sample = try await CloudDevice.make(backend: backend, email: "d@example.com")
        sample.sampleDataActive = true
        await assertRefusal(sample, .sampleDataActive)
        XCTAssertEqual(backend.count(pathSuffix: "/sync"), 0, "a refused run never reaches the server")
        XCTAssertEqual(backend.count(pathSuffix: "/changes"), 0)
    }

    func testNotConfiguredRefusesBeforeTheNetwork() async throws {
        let device = try await CloudDevice.make(backend: backend)
        var config = backend.config
        config.baseURL = nil
        let api = AgaraCloudAPI(config: config, transport: backend, auth: device.auth)
        let engine = AgaraSyncEngine(api: api, auth: device.auth, container: device.container, state: device.state)
        let before = backend.requests.count
        do { _ = try await engine.run(); XCTFail("should refuse") } catch { XCTAssertEqual(error as? CloudSyncRefusal, .notConfigured) }
        XCTAssertEqual(backend.requests.count, before)
    }

    private func assertRefusal(_ device: CloudDevice, _ expected: CloudSyncRefusal, line: UInt = #line) async {
        do { _ = try await device.run(); XCTFail("should refuse", line: line) }
        catch { XCTAssertEqual(error as? CloudSyncRefusal, expected, line: line) }
    }

    // MARK: Push

    func testFirstSyncUploadsEveryBlockInBatchesNewestFirst() async throws {
        let device = try await CloudDevice.make(backend: backend, limits: limits(blocks: 3))
        try populate(device)
        XCTAssertEqual(device.unsyncedCount, 10)

        let summary = try await device.run()

        XCTAssertEqual(summary.blocksSent, 10)
        XCTAssertEqual(summary.blocksAccepted, 10)
        XCTAssertEqual(backend.syncRequestCount, 4, "10 blocks at 3 per request")
        XCTAssertEqual(device.unsyncedCount, 0)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 10)
        for ledger in device.ledgers {
            XCTAssertEqual(ledger.syncedHash, ledger.contentHash)
            XCTAssertEqual(ledger.syncedRevision, ledger.revision)
            XCTAssertNotNil(ledger.syncedAt)
        }
        // Newest day first in the very first request.
        let first = try JSONDecoder().decode(SyncRequest.self, from: backend.syncBodies[0])
        let days = first.blocks.map(\.utcDay)
        XCTAssertEqual(days, days.sorted(by: >))
        XCTAssertEqual(first.blocks.first?.utcDay, Int(device.today - 1))
        XCTAssertEqual(first.envelope, 1); XCTAssertEqual(first.app, WireApp(platform: "ios", version: "1.1.0"))
        XCTAssertEqual(first.clientId, "00000000-0000-4000-8000-000000000001")
    }

    func testTheStoredContainerIsSentVerbatimWithoutReEncoding() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device, sealedDays: 2, openDays: 0)
        let stored = Dictionary(uniqueKeysWithValues: device.blocks.map { ($0.blockKey, $0.data) })
        _ = try await device.run()
        let request = try JSONDecoder().decode(SyncRequest.self, from: backend.syncBodies[0])
        XCTAssertEqual(request.blocks.count, 2)
        for wire in request.blocks {
            XCTAssertEqual(Data(base64Encoded: wire.data), stored[wire.blockKey], "bytes on the wire == bytes in measurement_blocks")
            let decoded = AGB.decode(Data(base64Encoded: wire.data)!)
            XCTAssertEqual(AGB.hex(decoded.contentHash!), wire.contentHash)
            XCTAssertEqual(decoded.summary?.n, wire.summary.n)
            XCTAssertNil(wire.tombstones)
        }
    }

    func testAnUpToDateStoreSendsNothingTheSecondTime() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device)
        _ = try await device.run()
        let sent = backend.syncRequestCount
        let second = try await device.run()
        XCTAssertEqual(second.blocksSent, 0)
        XCTAssertEqual(backend.syncRequestCount, sent, "sealed and unchanged blocks are never sent again")
    }

    func testTheBodyCapSplitsBatches() async throws {
        let cap = 3_000
        let device = try await CloudDevice.make(backend: backend, limits: limits(bytes: cap))
        try populate(device)
        _ = try await device.run()
        XCTAssertGreaterThanOrEqual(backend.syncRequestCount, 3, "an unbounded run would be one request")
        XCTAssertTrue(backend.syncBodies.allSatisfy { $0.count <= cap }, "no request over the cap")
        XCTAssertEqual(device.unsyncedCount, 0)
    }

    func testProgressIsReportedPerMetric() async throws {
        let device = try await CloudDevice.make(backend: backend, limits: limits(blocks: 4))
        try populate(device)
        var updates: [CloudSyncProgress] = []
        _ = try await device.engine.run { updates.append($0) }
        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.stage, .finished)
        XCTAssertEqual(last.total, ["hr": 8, "spo2": 2])
        XCTAssertEqual(last.done, ["hr": 8, "spo2": 2])
        XCTAssertEqual(last.fraction, 1)
        XCTAssertTrue(updates.contains { $0.stage == .uploading && $0.doneBlocks > 0 && $0.doneBlocks < 10 }, "progress moves between batches")
        XCTAssertEqual(updates.first?.stage, .preparing)
    }

    // MARK: Server verdicts

    func testARejectedBlockStaysUnsyncedIsNotRetriedAndGoesOnceItChanges() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device, sealedDays: 3, openDays: 0)
        let victim = try XCTUnwrap(device.ledgers.first)
        backend.rejectBlockKeys = [victim.blockKey]              // the server refuses this block (bad_summary)

        let summary = try await device.run()
        XCTAssertEqual(summary.blocksRejected, 1)
        XCTAssertEqual(summary.blocksAccepted, 2)
        XCTAssertEqual(device.unsyncedCount, 1)

        let requests = backend.syncRequestCount
        _ = try await device.run()
        XCTAssertEqual(backend.syncRequestCount, requests, "the same bytes are not sent again")

        backend.rejectBlockKeys = []
        victim.contentHash = Data(repeating: 7, count: 32)       // the block "changed": a new hash, so the refusal no longer applies
        victim.revision += 1
        try device.context.save()
        let third = try await device.run()
        XCTAssertEqual(third.blocksAccepted, 1)
        XCTAssertEqual(device.unsyncedCount, 0)
    }

    func testMergedResultPullsTheUnionAndBothSidesConverge() async throws {
        let device = try await CloudDevice.make(backend: backend)
        let day = device.today - 15
        device.addSeries(day: day, count: 40, stepMs: 60_000, startMs: 3_600_000)
        try device.compact()
        // Another phone already uploaded different readings of the same block key.
        let other = (0..<30).map { AGBPoint(ts: day * AGB.dayMs + 50_000_000 + Int64($0) * 60_000, value: Double(70 + $0 % 5)) }
        backend.seed(email: email, block: makeWireBlock(day: day, points: other))

        let summary = try await device.run()

        XCTAssertEqual(summary.blocksAccepted, 1)
        let key = AGB.blockKey(metric: "hr", source: "live", sensorId: "a3a04cab4846d63c", utcDay: day)
        let server = try XCTUnwrap(backend.serverBlocks(email: email)[key])
        XCTAssertEqual(AGB.decode(server.container).timestamps.count, 70, "server holds the union")
        XCTAssertEqual(device.points(key).count, 70, "the client pulled and merged it locally")
        let ledger = try XCTUnwrap(device.ledgers.first { $0.blockKey == key })
        XCTAssertEqual(ledger.contentHash, server.hash, "same canonical bytes on both sides")
        XCTAssertTrue(ledger.isSynced)
        XCTAssertGreaterThanOrEqual(ledger.revision, 2, "the local merge bumped the revision")
        let before = backend.syncRequestCount
        let again = try await device.run()
        XCTAssertEqual(again.blocksSent, 0)
        XCTAssertEqual(backend.syncRequestCount, before, "converged: nothing left to send")
    }

    func testAFreshPhoneStoresSealedBlocksAndDoesNotUploadThemBack() async throws {
        let a = try await CloudDevice.make(backend: backend)
        try populate(a, sealedDays: 4, openDays: 0)
        _ = try await a.run()
        let uploaded = backend.syncRequestCount

        let b = try await CloudDevice.make(backend: backend, createUser: false)
        let summary = try await b.run()

        XCTAssertEqual(summary.pull.storedNew, 4)
        XCTAssertEqual(b.blocks.count, 4)
        XCTAssertTrue(b.blocks.allSatisfy { $0.sealed && $0.state == 0 })
        XCTAssertEqual(b.unsyncedCount, 0, "pulled blocks are marked synced")
        XCTAssertEqual(backend.syncRequestCount, uploaded, "the second phone uploaded nothing")
        for block in a.blocks {
            XCTAssertEqual(b.points(block.blockKey), a.points(block.blockKey))
        }
        XCTAssertFalse(b.state.cursor.isEmpty, "the cursor was persisted")
        // A reading of the pulled block goes through the normal reader.
        let d = a.today - 12
        let read = MeasurementSeries.points(metric: "hr", from: BlockStore.dayStart(d), to: BlockStore.dayStart(d + 1), context: b.context, now: CloudDevice.now)
        XCTAssertEqual(read.count, 60)
    }

    func testAnOpenDayComesDownAsRowsAndItsSnapshotMatchesTheServer() async throws {
        let a = try await CloudDevice.make(backend: backend)
        a.addSeries(day: a.today - 2)
        try a.compact()
        _ = try await a.run()

        let b = try await CloudDevice.make(backend: backend, createUser: false)
        let summary = try await b.run()

        XCTAssertEqual(summary.pull.rowsInserted, 60)
        XCTAssertEqual(b.rows.count, 60, "rows stay the source of truth for open days")
        XCTAssertEqual(b.unsyncedCount, 0, "the rebuilt snapshot hashes equal to the server's block")
        XCTAssertEqual(b.ledgers.first?.contentHash, a.ledgers.first?.contentHash)
    }

    func testPulledRowsKeepTheirSourceAndSensor() async throws {
        let a = try await CloudDevice.make(backend: backend)
        a.addSeries(day: a.today - 1, kind: .hrv, source: .history, sensor: "1111111111111111", count: 5, value: { _ in 42.5 })
        try a.compact()
        _ = try await a.run()
        let b = try await CloudDevice.make(backend: backend, createUser: false)
        _ = try await b.run()
        let row = try XCTUnwrap(b.rows.first)
        XCTAssertEqual(row.kindRaw, "hrv"); XCTAssertEqual(row.sourceRaw, "history"); XCTAssertEqual(row.sensorId, "1111111111111111")
        XCTAssertEqual(row.value, 42.5); XCTAssertEqual(row.unit, MeasurementKind.hrv.unit)
    }

    // MARK: Tombstones

    func testADeletedPointTravelsAsATombstoneAndIsNotResurrectedByAStaleDevice() async throws {
        let a = try await CloudDevice.make(backend: backend)
        let day = a.today - 14
        a.addSeries(day: day, count: 20)
        try a.compact()
        let key = AGB.blockKey(metric: "hr", source: "live", sensorId: "a3a04cab4846d63c", utcDay: day)
        let original = a.points(key)
        _ = try await a.run()

        // The user deletes one reading of the sealed block.
        let doomed = original[5].ts
        let ref = BlockStore.PointRef(metric: "hr", sourceRaw: "live", sensorId: "a3a04cab4846d63c", ts: doomed)
        XCTAssertEqual(BlockStore.removePoints([ref], now: CloudDevice.now, context: a.context).count, 1)
        a.context.insert(MeasurementDeletion(measurementId: "block:hr:live:\(doomed)", kindRaw: "hr", timestamp: BlockStore.date(ms: doomed)))
        try a.context.save()
        _ = try await a.run()

        let request = try JSONDecoder().decode(SyncRequest.self, from: backend.syncBodies.last!)
        XCTAssertEqual(request.blocks.first?.tombstones, [doomed])
        let serverPoints = AGB.decode(try XCTUnwrap(backend.serverBlocks(email: email)[key]).container).timestamps
        XCTAssertFalse(serverPoints.contains(doomed))
        XCTAssertEqual(serverPoints.count, 19)

        // A second phone pulls it without the point…
        let b = try await CloudDevice.make(backend: backend, createUser: false)
        _ = try await b.run()
        XCTAssertFalse(b.points(key).map(\.ts).contains(doomed))

        // …and a stale device re-uploading the old bytes cannot bring it back.
        let stale = makeWireBlock(day: day, points: original)
        let response = try await a.api.sync(SyncRequest(envelope: 1, clientId: "stale", app: WireApp(platform: "android", version: "1.0.0"),
                                                        sentAt: 0, blocks: [stale], days: []))
        XCTAssertNotEqual(response.blocks.first?.status, "rejected")
        let after = AGB.decode(try XCTUnwrap(backend.serverBlocks(email: email)[key]).container).timestamps
        XCTAssertFalse(after.contains(doomed), "the server's tombstone set is unioned, never resurrected")
    }

    func testTombstonesFromAnotherDeviceRemoveTheLocalRowsOfAnOpenDay() async throws {
        let b = try await CloudDevice.make(backend: backend)
        let day = b.today - 1
        b.addSeries(day: day, count: 10)
        try b.compact()
        let doomedRow = b.rows[3]
        let doomed = BlockStore.ms(doomedRow.timestamp)
        // The server's copy of this key carries a tombstone for that reading.
        var pts = b.rows.map { AGBPoint(ts: BlockStore.ms($0.timestamp), value: $0.value) }
        pts.removeAll { $0.ts == doomed }
        var wire = makeWireBlock(day: day, points: pts, sealed: false)
        wire.tombstones = [doomed]
        backend.seed(email: email, block: wire, tombstones: [doomed])

        _ = try await b.run()

        XCTAssertEqual(b.rows.count, 9)
        XCTAssertFalse(b.rows.contains { BlockStore.ms($0.timestamp) == doomed })
        let marker = try b.context.fetch(FetchDescriptor<MeasurementDeletion>()).map(\.measurementId)
        XCTAssertTrue(marker.contains("block:hr:live:\(doomed)"), "kept as a local tombstone so compaction cannot resurrect it")
    }

    // MARK: Failures and resume

    func testADroppedConnectionResumesWhereItStopped() async throws {
        let device = try await CloudDevice.make(backend: backend, limits: limits(blocks: 3))
        try populate(device)
        backend.inject(.init(pathContains: "/sync", status: 503, code: "auth_unavailable", skip: 1))   // batch 1 ok, batch 2 fails

        do { _ = try await device.run(); XCTFail("should fail") }
        catch let error as CloudServerError { XCTAssertEqual(error.status, 503) }
        XCTAssertEqual(device.unsyncedCount, 7, "the first batch of 3 was recorded before the failure")
        XCTAssertEqual(backend.serverBlocks(email: email).count, 3)

        let before = backend.syncRequestCount
        let summary = try await device.run()
        XCTAssertEqual(summary.blocksSent, 7)
        XCTAssertEqual(backend.syncRequestCount - before, 3, "only the remaining 7 blocks: batches of 3, 3, 1")
        XCTAssertEqual(device.unsyncedCount, 0)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 10)
    }

    func testACrashAfterTheServerAnsweredButBeforeTheLedgerWasWrittenIsAnsweredDuplicate() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device, sealedDays: 2, openDays: 0)
        // Play the server's part by hand: it stored the blocks, the app "crashed" before recording them.
        let pending = await device.store.pending(rejected: [:], limit: 10, maxBytes: 4_000_000)
        let first = try await device.api.sync(SyncRequest(envelope: 1, clientId: "c", app: WireApp(platform: "ios", version: "1"),
                                                          sentAt: 0, blocks: pending.map(\.wire), days: []))
        XCTAssertEqual(first.blocks.map(\.status), ["accepted", "accepted"])
        XCTAssertEqual(device.unsyncedCount, 2)

        let summary = try await device.run()
        XCTAssertEqual(summary.blocksAccepted, 2)
        XCTAssertEqual(device.unsyncedCount, 0)
        XCTAssertEqual(backend.serverBlocks(email: email).count, 2, "no duplicates: idempotent on (block_key, content_hash)")
    }

    func testAnExpiredTokenIsRefreshedMidSync() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device, sealedDays: 2, openDays: 0)
        backend.expireAllTokens()
        _ = try await device.run()
        XCTAssertEqual(device.unsyncedCount, 0)
        XCTAssertEqual(backend.refreshCount, 1)
    }

    func testAStaleVerifiedClaimSurfacesAs403EmailNotVerified() async throws {
        let device = try await CloudDevice.make(backend: backend, verified: false)
        var session = try XCTUnwrap(device.sessionStore.load())
        session.emailVerified = true          // the app believes it; the token's claim says otherwise
        device.sessionStore.save(session)
        try populate(device, sealedDays: 1, openDays: 0)
        do { _ = try await device.run(); XCTFail("should fail") }
        catch let error as CloudServerError {
            XCTAssertEqual(error.status, 403); XCTAssertEqual(error.code, "email_not_verified")
        }
        XCTAssertEqual(device.unsyncedCount, 1, "nothing lost")
    }

    func testRateLimitCarriesRetryAfterAndLeavesDataUntouched() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device, sealedDays: 2, openDays: 0)
        backend.inject(.init(pathContains: "/sync", status: 429, code: "rate_limited", retryAfter: 42))
        do { _ = try await device.run(); XCTFail("should fail") }
        catch let error as CloudServerError {
            XCTAssertTrue(error.isRateLimited); XCTAssertEqual(error.retryAfter, 42)
        }
        XCTAssertEqual(device.unsyncedCount, 2)
    }

    func testAccountDeletedIsSurfaced() async throws {
        let device = try await CloudDevice.make(backend: backend)
        _ = try await device.api.deleteMe()
        do { _ = try await device.run(); XCTFail("should fail") }
        catch let error as CloudServerError { XCTAssertEqual(error.code, "account_deleted") }
    }

    func testAPageThatFailsMidPullKeepsTheCursorOfTheLastAppliedPage() async throws {
        let a = try await CloudDevice.make(backend: backend)
        try populate(a, sealedDays: 6, openDays: 0)
        _ = try await a.run()

        let b = try await CloudDevice.make(backend: backend, createUser: false, limits: limits(page: 2))
        backend.inject(.init(pathContains: "/changes", status: 500, code: "server_error", skip: 1))   // page 1 ok, page 2 fails
        do { _ = try await b.run(); XCTFail("should fail") } catch {}
        XCTAssertEqual(b.blocks.count, 2)
        let cursor = b.state.cursor
        XCTAssertFalse(cursor.isEmpty)

        let summary = try await b.run()
        XCTAssertEqual(b.blocks.count, 6)
        XCTAssertEqual(summary.pullPages, 2, "resumed after the stored cursor: pages 2 and 3 only")
        XCTAssertNotEqual(b.state.cursor, cursor)
        // Idempotent: a third run changes nothing and sees nothing new.
        let third = try await b.run()
        XCTAssertEqual(third.pull.seen, 0)
    }

    // MARK: What must never leave the phone

    func testMockAndUnknownSourcesAreNeverUploaded() async throws {
        let device = try await CloudDevice.make(backend: backend)
        // Sample-data rows are `mock` and never become blocks.
        device.addSeries(day: device.today - 20, source: .mock)
        try device.compact()
        XCTAssertTrue(device.blocks.isEmpty)
        // Even a block a bug wrote under an unknown source is filtered out.
        let ghost = AGB.encodeBlock(points: [AGBPoint(ts: (device.today - 30) * AGB.dayMs + 1000, value: 70)], metric: "hr", utcDay: device.today - 30)!
        let key = "v1/hr/mock/a3a04cab4846d63c/\(device.today - 30)"
        device.context.insert(MeasurementBlock(blockKey: key, metric: "hr", source: "mock", sensorId: "a3a04cab4846d63c",
                                               utcDay: Int(device.today - 30), sealed: true, data: ghost.container, now: 0))
        device.context.insert(BlockSync(blockKey: key, revision: 1, contentHash: ghost.contentHash, now: 0))
        try device.context.save()
        let summary = try await device.run()
        XCTAssertEqual(summary.blocksSent, 0)
        XCTAssertTrue(backend.serverBlocks(email: email).isEmpty)
    }

    func testUnreadableBlocksAreNeverUploaded() async throws {
        let device = try await CloudDevice.make(backend: backend)
        try populate(device, sealedDays: 2, openDays: 0)
        let block = try XCTUnwrap(device.blocks.first)
        block.state = 2; block.reason = "crc_mismatch"
        try device.context.save()
        let summary = try await device.run()
        XCTAssertEqual(summary.blocksSent, 1)
        XCTAssertNil(backend.serverBlocks(email: email)[block.blockKey])
    }

    func testChangingAccountsStartsFromScratch() async throws {
        let device = try await CloudDevice.make(backend: backend, limits: limits())
        try populate(device, sealedDays: 3, openDays: 0)
        _ = try await device.run()
        XCTAssertEqual(device.unsyncedCount, 0)

        await device.auth.signOut()
        backend.createUser(email: "second@example.com", password: CloudDevice.password, verified: true)
        _ = try await device.auth.signIn(email: "second@example.com", password: CloudDevice.password)
        _ = try await device.run()

        XCTAssertEqual(backend.serverBlocks(email: "second@example.com").count, 3, "the other account gets the history too")
        XCTAssertEqual(device.state.ledgerOwner, AgaraCloudState.ownerDigest(try XCTUnwrap(device.sessionStore.load()).uid))
        XCTAssertNotEqual(device.state.ledgerOwner, device.sessionStore.load()?.uid, "the uid itself is never stored")
    }

    // MARK: Day rows

    func testDayRowsAreSentOnceAndAgainWhenTheyChange() async throws {
        let device = try await CloudDevice.make(backend: backend)
        TestSupport.insertActivity(date: Calendar.current.startOfDay(for: CloudDevice.now), steps: 5000, calories: 210, distanceMeters: 3900, into: device.context)
        _ = try await device.run()
        let key = AgaraCloudDays.dayString(CloudDevice.now)
        XCTAssertEqual(backend.serverDays(email: email)[key]?.steps, 5000)
        XCTAssertEqual(backend.serverDays(email: email)[key]?.distanceKm ?? 0, 3.9, accuracy: 0.0001)
        let sent = backend.syncRequestCount

        _ = try await device.run()
        XCTAssertEqual(backend.syncRequestCount, sent, "an unchanged day is not sent again")

        let row = try XCTUnwrap(try device.context.fetch(FetchDescriptor<ActivityDaily>()).first)
        row.steps = 7200
        try device.context.save()
        _ = try await device.run()
        XCTAssertEqual(backend.serverDays(email: email)[key]?.steps, 7200)
    }

    func testDayRowsBatchByTheCatalogLimit() async throws {
        let device = try await CloudDevice.make(backend: backend, limits: limits(days: 2))
        for i in 0..<5 {
            TestSupport.insertActivity(date: TestSupport.day(-i, from: CloudDevice.now), steps: 1000 + i, into: device.context)
        }
        let summary = try await device.run()
        XCTAssertEqual(summary.daysSent, 5)
        XCTAssertEqual(backend.count(pathSuffix: "/sync"), 3, "5 day rows at 2 per request")
        XCTAssertEqual(backend.serverDays(email: email).count, 5)
    }

    func testPulledDaysBecomeEventsOnlyWhereTheServerKnowsMore() async throws {
        let a = try await CloudDevice.make(backend: backend)
        TestSupport.insertActivity(date: Calendar.current.startOfDay(for: CloudDevice.now), steps: 8000, calories: 300, distanceMeters: 6000, into: a.context)
        _ = try await a.run()

        let b = try await CloudDevice.make(backend: backend, createUser: false)
        _ = try await b.run()
        let activity = b.events.compactMap { event -> Int? in
            if case let .activityUpdate(_, steps, _, _) = event { return steps }
            return nil
        }
        XCTAssertEqual(activity, [8000])
    }

    // MARK: Clock and time zone

    func testBlockKeysAreUTCWhateverTheLocalZoneAndDayStringsFollowTheCalendar() {
        let instant = Date(timeIntervalSince1970: 1_790_625_600)   // 2026-09-28T20:00:00Z (UTC day 20724)
        var west = Calendar(identifier: .gregorian); west.timeZone = TimeZone(secondsFromGMT: -12 * 3600)!
        var east = Calendar(identifier: .gregorian); east.timeZone = TimeZone(secondsFromGMT: 14 * 3600)!
        XCTAssertEqual(AgaraCloudDays.dayString(instant, calendar: west), "2026-09-28")
        XCTAssertEqual(AgaraCloudDays.dayString(instant, calendar: east), "2026-09-29")
        XCTAssertEqual(BlockStore.utcDay(ms: BlockStore.ms(instant)), 20724, "the block day is UTC, in every zone")
        let d = AgaraCloudDays.parseDay("2026-09-29", calendar: east)!
        XCTAssertEqual(AgaraCloudDays.dayString(d, calendar: east), "2026-09-29")
        XCTAssertNil(AgaraCloudDays.parseDay("2026-09", calendar: east))
        XCTAssertNil(AgaraCloudDays.parseDay("not a date", calendar: east))
    }

    func testCanonicalBytesDoNotDependOnTheLocalTimeZone() async throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        var hashes: [String] = []
        for offset in [-12, 0, 14] {
            NSTimeZone.default = TimeZone(secondsFromGMT: offset * 3600)!
            let device = try await CloudDevice.make(backend: FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!))
            device.addSeries(day: device.today - 12)
            try device.compact()
            hashes.append(AGB.hex(try XCTUnwrap(device.ledgers.first).contentHash))
        }
        XCTAssertEqual(Set(hashes).count, 1)
    }

    func testPulledDayEventsClampAndSkipBadInput() {
        let good = WireDay(date: "2026-09-26", steps: 9000, distanceKm: 6.5, calories: 300,
                           sleepStart: "2026-09-25T22:10:00Z", sleepEnd: "2026-09-26T06:02:00Z", deep: 71, light: 250, awake: 9, other: -5,
                           sleepMinutes: 472, sleepScore: 81)
        let bad = WireDay(date: "garbage", steps: 1, distanceKm: 0, calories: 0)
        let events = AgaraCloudDays.events(days: [good, bad], localSteps: ["2026-09-26": 100], localSleepDays: [])
        XCTAssertEqual(events.count, 2, "one activity and one night; the unparseable date is skipped")
        if case let .sleepTimeline(_, stages, source) = events[1] {
            XCTAssertEqual(stages.count, 71 + 250 + 9, "a negative count is clamped to zero")
            XCTAssertEqual(source, SleepSource.cloud)
        } else { XCTFail("expected a sleep timeline") }
        // The local night wins; fewer server steps change nothing.
        let none = AgaraCloudDays.events(days: [good], localSteps: ["2026-09-26": 9500], localSleepDays: ["2026-09-26"])
        XCTAssertTrue(none.isEmpty)
    }
}

@MainActor
final class AgaraCloudDemoDataTests: XCTestCase {
    func testMockDaysAreNeverUploadedNorTheirNights() async throws {
        let backend = FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let device = try await CloudDevice.make(backend: backend)
        let today = Calendar.current.startOfDay(for: CloudDevice.now)
        TestSupport.insertActivity(date: today, steps: 4000, source: "mock", into: device.context)                       // demo seed
        TestSupport.insertActivity(date: TestSupport.day(-1, from: today), steps: 6000, source: "live", into: device.context)
        TestSupport.insertSleep(nightStart: today.addingTimeInterval(-3 * 3600), stages: [SleepStage](repeating: .light, count: 60), into: device.context)
        _ = try await device.run()
        let days = backend.serverDays(email: device.email)
        XCTAssertEqual(days.count, 1, "only the real day")
        XCTAssertEqual(days.values.first?.steps, 6000)
        XCTAssertTrue(AgaraCloudDays.isMockSource("MOCK")); XCTAssertTrue(AgaraCloudDays.isMockSource("demo"))
        XCTAssertFalse(AgaraCloudDays.isMockSource("ring_history"))
    }
}

// MARK: - Workout sessions on the wire (cloud-v2 §2.1)

/// Both apps recorded sessions locally and uploaded none of it, so a `source=workout` filter over block metrics could
/// never match. These pin the upload half: what counts as uploadable, how a session becomes wire JSON, and that an
/// acknowledged session is not sent again (the second-occurrence rule).
@MainActor
final class CloudSessionUploadTests: XCTestCase {

    private func session(started: Date, ended: Date?, pause: Double = 0, type: String = "run",
                         calories: Double? = 160, distance: Double? = 2_400) -> ActivitySession {
        ActivitySession(id: UUID(), type: type, status: ended == nil ? .recording : .finished,
                        startedAt: started, endedAt: ended, totalPauseSeconds: pause,
                        calories: calories, distanceMeters: distance, notes: nil, useGps: true)
    }

    private var start: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 7, minute: 30))!
    }

    // MARK: duration

    func testTheNetDurationSubtractsPauses() {
        let s = session(started: start, ended: start.addingTimeInterval(3600), pause: 600)
        XCTAssertEqual(AgaraCloudSessions.durationMinutes(s), 50, accuracy: 0.001,
                       "60 minutes of wall time minus 10 paused")
    }

    func testAClockThatWentBackwardsYieldsNoDurationRatherThanANegativeOne() {
        let s = session(started: start, ended: start.addingTimeInterval(-60))
        XCTAssertEqual(AgaraCloudSessions.durationMinutes(s), 0, "never negative")
        XCTAssertFalse(AgaraCloudSessions.uploadable(s), "and never uploaded")
    }

    func testASessionStillRecordingIsNotUploadable() {
        let s = session(started: start, ended: nil)
        XCTAssertFalse(AgaraCloudSessions.uploadable(s), "its duration is still growing; uploading would freeze it")
        XCTAssertNil(AgaraCloudSessions.wire(s), "and it maps to nothing")
    }

    func testASessionShorterThanTheFloorIsNotUploaded() {
        let s = session(started: start, ended: start.addingTimeInterval(20))   // 20 s
        XCTAssertFalse(AgaraCloudSessions.uploadable(s), "a started-then-abandoned recording is not a workout")
    }

    func testTheFloorItselfIsUploaded() {
        let s = session(started: start, ended: start.addingTimeInterval(30))   // exactly 0.5 min
        XCTAssertTrue(AgaraCloudSessions.uploadable(s), "the boundary is inclusive")
    }

    // MARK: mapping

    func testASessionMapsToTheWireShapeWithNetMinutesAndLocalDate() throws {
        let s = session(started: start, ended: start.addingTimeInterval(3_600), pause: 300)
        let wire = try XCTUnwrap(AgaraCloudSessions.wire(s))
        XCTAssertEqual(wire.sessionKey, s.id.uuidString, "the model id is the idempotency key")
        XCTAssertEqual(wire.date, AgaraCloudDays.dayString(start), "dated by the local day it started")
        XCTAssertEqual(wire.type, "run")
        XCTAssertEqual(wire.durationMin, 55, accuracy: 0.001)
        XCTAssertEqual(wire.startedAt, Int64(start.timeIntervalSince1970 * 1000))
        XCTAssertEqual(wire.calories, 160)
        XCTAssertEqual(wire.distanceM, 2_400)
        XCTAssertFalse(wire.deleted)
        XCTAssertNil(wire.avgHr, "no heart-rate summary recorded means no value, not zero")
    }

    func testTheWireJsonOmitsAbsentOptionalsInsteadOfSendingNulls() {
        let s = session(started: start, ended: start.addingTimeInterval(600), calories: nil, distance: nil)
        let json = WireBlockBuilder.json(AgaraCloudSessions.wire(s)!)
        XCTAssertTrue(json.contains("\"session_key\":"), json)
        XCTAssertTrue(json.contains("\"duration_min\":10"), json)
        XCTAssertFalse(json.contains("calories"), "absent stays absent so a later write cannot blank it: \(json)")
        XCTAssertFalse(json.contains("null"), "no nulls: \(json)")
        XCTAssertFalse(json.contains("\"deleted\""), "false is omitted, the server defaults it: \(json)")
    }

    func testATypeWithQuotesCannotBreakTheEnvelope() {
        let s = session(started: start, ended: start.addingTimeInterval(600), type: "run \"fast\"\\x")
        let json = WireBlockBuilder.json(AgaraCloudSessions.wire(s)!)
        XCTAssertTrue(json.contains(#""type":"run \"fast\"\\x""#), "escaped, not injected: \(json)")
    }

    // MARK: envelope

    func testTheEnvelopeCarriesSessionsAlongsideBlocksAndDays() {
        let s = session(started: start, ended: start.addingTimeInterval(600))
        let body = WireBlockBuilder.envelope(clientId: "c1", platform: "ios", version: "1.1", sentAt: 1,
                                             blocks: [], days: [], sessions: AgaraCloudSessions.payload([s]))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"sessions\":[{"), text)
        XCTAssertTrue(text.contains("\"days\":[]"), text)
        XCTAssertTrue(text.contains("\"blocks\":[]"), text)
    }

    func testAnEnvelopeWithoutSessionsStillCarriesTheEmptyArray() {
        let body = WireBlockBuilder.envelope(clientId: "c1", platform: "ios", version: "1.1", sentAt: 1,
                                             blocks: [], days: [])
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"sessions\":[]"),
                      "the shape does not depend on the caller")
    }

    // MARK: pending + acknowledgement

    func testPendingSelectsOnlyFinishedUnsentSessionsOldestFirstUpToTheLimit() throws {
        let context = try TestSupport.makeContext()
        let sent = session(started: start, ended: start.addingTimeInterval(600))
        sent.syncedAt = start
        let late = session(started: start.addingTimeInterval(7_200), ended: start.addingTimeInterval(7_800))
        let early = session(started: start, ended: start.addingTimeInterval(600))
        let recording = session(started: start.addingTimeInterval(9_000), ended: nil)
        for s in [sent, late, early, recording] { context.insert(s) }
        try context.save()

        let pending = AgaraCloudSessions.pending(context: context, limit: 200)
        XCTAssertEqual(pending.map(\.id), [early.id, late.id], "oldest first, no acknowledged and no recording session")

        XCTAssertEqual(AgaraCloudSessions.pending(context: context, limit: 1).map(\.id), [early.id],
                       "the limit is respected")
    }

    func testAnAcknowledgedSessionIsNotSentAgain() throws {
        let context = try TestSupport.makeContext()
        let s = session(started: start, ended: start.addingTimeInterval(600))
        context.insert(s)
        try context.save()
        XCTAssertEqual(AgaraCloudSessions.pending(context: context).count, 1, "precondition: it is pending")

        AgaraCloudSessions.mark(synced: [s], at: start.addingTimeInterval(3_600), context: context)

        XCTAssertNotNil(s.syncedAt)
        XCTAssertTrue(AgaraCloudSessions.pending(context: context).isEmpty, "the second pass sends nothing")
    }
}

// MARK: - A confirmed quiet day vs a day that never synced (G3)

/// `dayRows` used to drop any day whose activity was all zeros *and* whose night was empty — which made two different
/// facts look identical downstream: "the ring confirmed this day and nothing happened" and "this day was never synced".
/// Any consistency metric reading the second as a zero is wrong, so the confirmation stamp now travels with the row
/// (`ActivityDaily.syncedAt` has always been on the device; it just never left it).
@MainActor
final class CloudDayConfirmationTests: XCTestCase {

    private var day: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    }

    func testAConfirmedQuietDayIsUploadedWithItsConfirmationStamp() throws {
        let context = try TestSupport.makeContext()
        context.insert(ActivityDaily(date: day, steps: 0, calories: 0, distanceMeters: 0, activeMinutes: 0, source: "ring"))
        let row = (try context.fetch(FetchDescriptor<ActivityDaily>())).first
        row?.syncedAt = day.addingTimeInterval(600)
        try context.save()

        let rows = AgaraCloudDays.dayRows(context: context)
        let mine = try XCTUnwrap(rows.first { $0.date == AgaraCloudDays.dayString(day) },
                                 "a confirmed day must be sent even with nothing in it")
        XCTAssertEqual(mine.steps, 0)
        XCTAssertEqual(mine.syncedAt, Int64(day.addingTimeInterval(600).timeIntervalSince1970 * 1000),
                       "the confirmation time is what distinguishes it from a missing day")
    }

    func testAZeroDayWithNoConfirmationIsNotUploaded() throws {
        let context = try TestSupport.makeContext()
        context.insert(ActivityDaily(date: day, steps: 0, calories: 0, distanceMeters: 0, activeMinutes: 0, source: "ring"))
        try context.save()

        XCTAssertTrue(AgaraCloudDays.dayRows(context: context).isEmpty,
                      "unconfirmed and empty is unknown, not zero — sending it would invent a quiet day")
    }

    func testADayWithNoRowAtAllIsNotUploaded() throws {
        let context = try TestSupport.makeContext()
        XCTAssertTrue(AgaraCloudDays.dayRows(context: context).isEmpty)
    }

    func testTheConfirmationStampReachesTheWireJson() {
        let wire = WireDay(date: "2026-10-28", steps: 0, distanceKm: 0, calories: 0,
                           syncedAt: 1_790_000_000_000)
        XCTAssertTrue(WireBlockBuilder.json(wire).contains("\"synced_at\":1790000000000"), WireBlockBuilder.json(wire))
    }

    func testADayPulledFromTheCloudWithoutAStampStaysUnstamped() throws {
        let payload = #"{"date":"2026-10-28","steps":10,"distance_km":0.01,"calories":3}"#
        let wire = try JSONDecoder().decode(WireDay.self, from: Data(payload.utf8))
        XCTAssertNil(wire.syncedAt, "absent means unknown; it must not read back as the epoch")
    }

    func testTheDayFingerprintChangesWhenOnlyTheConfirmationMoves() {
        let before = WireDay(date: "2026-10-28", steps: 500, distanceKm: 0.4, calories: 20)
        let after = WireDay(date: "2026-10-28", steps: 500, distanceKm: 0.4, calories: 20, syncedAt: 1_790_000_000_000)
        XCTAssertNotEqual(AgaraCloudDays.fingerprint(before), AgaraCloudDays.fingerprint(after),
                          "a day whose only change is its confirmation must still be re-sent")
    }
}
