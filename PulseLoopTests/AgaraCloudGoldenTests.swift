import CryptoKit
import SwiftData
import XCTest
@testable import PulseLoop

/// Cross-platform golden test (release 1.1, task 5): for every valid AGB vector in `ring-emulator/testdata/agb/`, the bytes
/// the app uploads are exactly the vector's `.agb` container, under the expected key, hash and summary — so Android, fed the
/// same vectors, uploads the same thing. The envelope's own JSON is deterministic (sorted keys, no whitespace, unescaped
/// slashes), and the SHA-256 of one fixed envelope is pinned so Android can assert the same digest.
@MainActor
final class AgaraCloudGoldenTests: XCTestCase {
    private func json(_ name: String, _ ext: String = "json") throws -> [String: Any] {
        let data = try Data(contentsOf: AGBCodecTests.vectorDir.appendingPathComponent("\(name).\(ext)"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func validVectors() throws -> [String] {
        let data = try Data(contentsOf: AGBCodecTests.vectorDir.appendingPathComponent("index.json"))
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return rows.filter { ($0["status"] as? String) == "ok" }.map { $0["name"] as! String }
    }

    /// Store a vector's `.agb` bytes as if a device had written them, then let the app build its upload.
    private func pending(for name: String, in container: ModelContainer) async throws -> (PendingBlock, [String: Any])? {
        let expected = try json(name)
        let blob = try Data(contentsOf: AGBCodecTests.vectorDir.appendingPathComponent("\(name).agb"))
        let decoded = AGB.decode(blob)
        guard decoded.isOK, let key = expected["block_key"] as? String, (decoded.summary?.n ?? 0) > 0,
              let parsed = ParsedBlockKey.parse(key) else { return nil }
        let context = container.mainContext
        let enc = AGBEncoded(container: blob, payload: Data(decoded.payload ?? []), contentHash: decoded.contentHash!,
                             pointCount: decoded.timestamps.count, dropped: AGBDropped())
        let keyRow = BlockStore.Key(metric: parsed.metric, sourceRaw: BlockStore.rawSource(forKeySource: parsed.source), sensorId: parsed.sensorId, day: parsed.day)
        BlockStore.store(enc, key: keyRow, sealed: true, context: context, now: CloudDevice.now)
        try context.save()
        let store = AgaraSyncStore(modelContainer: container)
        let all = await store.pending(rejected: [:], limit: 1000, maxBytes: 100_000_000)
        return all.first { $0.wire.blockKey == key }.map { ($0, expected) }
    }

    func testEveryValidVectorUploadsTheReferenceBytesKeyHashAndSummary() async throws {
        var checked = 0
        for name in try validVectors() {
            let container = try ModelContainerFactory.make(inMemory: true)
            guard let (pending, expected) = try await pending(for: name, in: container) else { continue }
            let wire = pending.wire
            let blob = try Data(contentsOf: AGBCodecTests.vectorDir.appendingPathComponent("\(name).agb"))
            XCTAssertEqual(Data(base64Encoded: wire.data), blob, "\(name): the container is sent verbatim")
            XCTAssertEqual(wire.blockKey, expected["block_key"] as? String, name)
            XCTAssertEqual(wire.contentHash, expected["content_hash"] as? String, name)
            XCTAssertEqual(wire.fmt.codec, (expected["codec"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(wire.fmt.major, (expected["format_major"] as? NSNumber)?.intValue, name)
            let summary = try XCTUnwrap(expected["summary"] as? [String: Any])
            XCTAssertEqual(wire.summary.n, (summary["n"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(wire.summary.firstTs, (summary["first_ts"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(wire.summary.lastTs, (summary["last_ts"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(wire.summary.min ?? .nan, (summary["min"] as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-9, name)
            XCTAssertEqual(wire.summary.max ?? .nan, (summary["max"] as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-9, name)
            XCTAssertEqual(wire.summary.sum ?? .nan, (summary["sum"] as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-6 * max(1, abs(wire.summary.sum ?? 0)), name)
            XCTAssertEqual(wire.utcDay, (expected["utc_day"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(wire.sensorId, expected["sensor_id"] as? String, name)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 17, "the golden set has 19 valid blocks (empty and higher-minor included where they upload)")
    }

    /// The Android tree pins the SHA-256 of each vector's wire block in `wire_golden.txt`; the file is read in place (never copied).
    static let androidGolden: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("PulseLoopAndroid/app/src/test/resources/cloud/wire_golden.txt")
    }()

    func testWireBlocksHashToTheDigestsPinnedByTheAndroidTree() throws {
        guard let text = try? String(contentsOf: Self.androidGolden, encoding: .utf8) else {
            throw XCTSkip("PulseLoopAndroid/app/src/test/resources/cloud/wire_golden.txt not found next to this tree")
        }
        let expected = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").map { line -> (String, String) in
            let parts = line.split(separator: " ")
            return (String(parts[0]), String(parts[1]))
        })
        XCTAssertGreaterThanOrEqual(expected.count, 19)
        var checked = 0
        for name in try validVectors() {
            let vector = try json(name)
            guard let key = vector["block_key"] as? String else { continue }
            let blob = try Data(contentsOf: AGBCodecTests.vectorDir.appendingPathComponent("\(name).agb"))
            let decoded = AGB.decode(blob)
            let block = try XCTUnwrap(WireBlockBuilder.json(blockKey: key, revision: 1, sealed: true, decoded: decoded, tombstones: [], container: blob), name)
            let digest = SHA256.hash(data: Data(block.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expected[name], "\(name): same wire bytes as Android")
            checked += 1
        }
        XCTAssertEqual(checked, expected.count, "every pinned vector was checked")
    }

    func testExactDecimalFormattingOfScaledIntegersMatchesAndroid() {
        XCTAssertEqual(WireBlockBuilder.scaled(54, 0), "54")
        XCTAssertEqual(WireBlockBuilder.scaled(3665, 2), "36.65")
        XCTAssertEqual(WireBlockBuilder.scaled(1, 1), "0.1")
        XCTAssertEqual(WireBlockBuilder.scaled(-15, 1), "-1.5")
        XCTAssertEqual(WireBlockBuilder.scaled(285120, 0), "285120")
        XCTAssertEqual(WireBlockBuilder.scaled(0, 2), "0")
        XCTAssertEqual(WireBlockBuilder.scaled(1000, 0), "1000")
        XCTAssertEqual(WireBlockBuilder.scaled(10000, 2), "100")
        XCTAssertEqual(WireBlockBuilder.scaled(5, 2), "0.05")
    }

    func testTheEnvelopeHasAFixedKeyOrder() throws {
        let block = makeWireBlock(day: 20722, points: [AGBPoint(ts: 1_790_380_800_000, value: 70)])
        let body = String(decoding: try WireCodec.encode(SyncRequest(envelope: 1, clientId: "c", app: WireApp(platform: "ios", version: "1.1.0"),
                                                                     sentAt: 5, blocks: [block], days: [])), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("{\"envelope\":1,\"client_id\":\"c\",\"app\":{\"platform\":\"ios\",\"version\":\"1.1.0\"},\"sent_at\":5,\"blocks\":[{\"block_key\":\"v1/hr/live/a3a04cab4846d63c/20722\",\"metric\":\"hr\",\"source\":\"live\",\"sensor_id\":\"a3a04cab4846d63c\",\"utc_day\":20722,\"revision\":1,\"sealed\":true,\"fmt\":{\"major\":1,\"minor\":0,\"codec\":"), body)
        // The envelope gained a third array with cloud-v2 §2.1 ("Workout sessions") and a fourth with the EV40
        // tracker (§2.1, migration 0006): both ride beside blocks and days. The assertion still pins a fixed key
        // order and a fixed tail, which is the point of the golden — it just now asserts the 1.1 tail.
        XCTAssertTrue(body.hasSuffix("\"days\":[],\"sessions\":[],\"tracker\":[]}"), body)
        XCTAssertTrue(body.contains("\"summary\":{\"n\":1,\"min\":70,\"max\":70,\"sum\":70,\"first_ts\":1790380800000,\"last_ts\":1790380800000}"))
    }

    /// What another platform's writer would upload for the same points equals what this app uploads (payload hash and key).
    func testTheSamePointsGiveTheSameUploadAsTheReferenceWriter() async throws {
        for name in ["hrv_history", "spo2_history", "stress_grid"] {
            let input = try json(name, "input.json")
            let expected = try json(name)
            let metric = input["metric"] as! String
            let raw = try XCTUnwrap(input["points"] as? [[NSNumber]])
            let points = raw.map { AGBPoint(ts: $0[0].int64Value, value: $0[1].doubleValue) }
            let day = (input["utc_day"] as! NSNumber).int64Value
            let device = try await CloudDevice.make(backend: FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!))
            for p in points {
                device.context.insert(PulseLoop.Measurement(kind: MeasurementKind(rawValue: metric)!, value: p.value, unit: "", timestamp: BlockStore.date(ms: p.ts),
                                                            source: .history, sensorId: expected["sensor_id"] as! String))
            }
            try device.context.save()
            // Open-day snapshot relative to a "now" inside that day, as the maintenance job would write it.
            let now = BlockStore.date(ms: day * AGB.dayMs + 43_200_000)
            _ = try BlockStore.snapshotOpenDays(now: now, context: device.context)
            let pendingBlocks = await device.store.pending(rejected: [:], limit: 10, maxBytes: 10_000_000)
            let wire = try XCTUnwrap(pendingBlocks.first?.wire, name)
            XCTAssertEqual(wire.contentHash, expected["content_hash"] as? String, "\(name): identical canonical payload")
            XCTAssertEqual(wire.blockKey, expected["block_key"] as? String, name)
        }
    }
}

/// Pre-TestFlight wire audit (2026-10-22): sync carries numbers only (the upload bytes are pinned above); the one
/// device-derived field is `sensor_id`, which must never carry the ring's Bluetooth MAC.
final class SyncIdentityPrivacyTests: XCTestCase {
    func testSensorIdIsADigestNotTheMac() throws {
        let mac = "F8:2A:9C:11:4B:E0"
        let id = try XCTUnwrap(AGB.sensorId(ringMac: mac))
        XCTAssertEqual(id.count, 16, "8 bytes of SHA-256, hex")
        for fragment in ["F82A9C114BE0", "f82a9c114be0", "F8:2A", "9C:11", "4B:E0"] {
            XCTAssertFalse(id.contains(fragment), "the MAC leaks through sensor_id")
        }
        XCTAssertEqual(AGB.sensorId(ringMac: "f8-2a-9c-11-4b-e0"), id, "normalised: one ring, one id")
        XCTAssertNotEqual(AGB.sensorId(ringMac: "F8:2A:9C:11:4B:E1"), id)
    }

    func testAWireBlockSpellsOnlyTheContractsFields() throws {
        let day: Int64 = 20_383
        let points = (0..<10).map { AGBPoint(ts: day * AGB.dayMs + Int64($0) * 60_000, value: Double(70 + $0)) }
        let block = makeWireBlock(day: day, points: points)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(block)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: [
            "block_key", "metric", "source", "sensor_id", "utc_day", "revision", "sealed", "fmt",
            "content_hash", "summary", "tombstones", "data",
        ]), "unexpected field(s): \(Set(object.keys))")
    }
}
