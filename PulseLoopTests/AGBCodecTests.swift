import XCTest
@testable import PulseLoop

/// AGB v1 conformance (docs/ring/storage-format.md §14): every golden vector in `ring-emulator/testdata/agb/` is
/// decoded and re-encoded here — the files are read in place (never copied or forked), so a change to the
/// vectors is a change to both apps. Compares the **payload**, never the compressed body.
final class AGBCodecTests: XCTestCase {
    // MARK: Vector access

    static let vectorDir: URL = {
        // …/PulseLoopiOS/PulseLoopTests/AGBCodecTests.swift → repo root is two levels above `PulseLoopiOS`.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("ring-emulator/testdata/agb", isDirectory: true)
    }()

    private func json(_ name: String, _ ext: String = "json") throws -> [String: Any] {
        let data = try Data(contentsOf: Self.vectorDir.appendingPathComponent("\(name).\(ext)"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func vectorNames() throws -> [(name: String, status: String)] {
        let data = try Data(contentsOf: Self.vectorDir.appendingPathComponent("index.json"))
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return rows.map { ($0["name"] as! String, $0["status"] as! String) }
    }

    /// LCG from §14: `x = (x·1103515245 + 12345) & 0x7fffffff`, `r = x >> 16`.
    private func generatedPoints(_ g: [String: Any]) -> [AGBPoint] {
        var x = (g["seed"] as! NSNumber).int64Value
        func draw() -> Int64 { x = (x &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff; return x >> 16 }
        var v = (g["start"] as? NSNumber)?.int64Value ?? 70
        var t = (g["t0"] as! NSNumber).int64Value
        let step = (g["step_ms"] as! NSNumber).int64Value
        let lo = (g["lo"] as! NSNumber).int64Value, hi = (g["hi"] as! NSNumber).int64Value
        let jitter = (g["jitter_ms"] as? NSNumber)?.int64Value ?? 0
        var out: [AGBPoint] = []
        for _ in 0..<(g["count"] as! NSNumber).intValue {
            let ts = jitter != 0 ? t + (draw() % (2 * jitter + 1)) - jitter : t
            out.append(AGBPoint(ts: ts, value: Double(v)))
            v = min(hi, max(lo, v + (draw() % 3) - 1))
            t += step
        }
        return out
    }

    private func inputPoints(_ input: [String: Any]) -> [AGBPoint]? {
        if let g = input["points_gen"] as? [String: Any] { return generatedPoints(g) }
        guard let raw = input["points"] as? [[NSNumber]] else { return nil }
        return raw.map { AGBPoint(ts: $0[0].int64Value, value: $0[1].doubleValue) }
    }

    private func sensorId(_ s: [String: Any]) -> String {
        if let mac = s["ring_mac"] as? String { return AGB.sensorId(ringMac: mac)! }
        if let uuid = s["install_uuid"] as? String { return AGB.sensorId(installUUID: uuid) }
        return AGB.unknownSensor
    }

    // MARK: The golden vectors

    func testVectorDirectoryIsReadableAndComplete() throws {
        let names = try vectorNames()
        XCTAssertEqual(names.count, 25, "19 valid + 5 failure + 1 higher-minor vector")
        XCTAssertEqual(names.filter { $0.status == "ok" }.count, 20)
    }

    func testEveryValidVectorDecodesToTheExpectedPointsSummaryAndHash() throws {
        var checked = 0
        for (name, status) in try vectorNames() where status == "ok" {
            let expected = try json(name)
            let blob = try Data(contentsOf: Self.vectorDir.appendingPathComponent("\(name).agb"))
            let d = AGB.decode(blob)
            XCTAssertEqual(d.status, .ok, name)
            XCTAssertEqual(AGB.hex(try XCTUnwrap(d.contentHash, name)), expected["content_hash"] as? String, "\(name) content_hash")
            XCTAssertEqual(d.major, expected["format_major"] as? Int, name)
            XCTAssertEqual(d.minor, expected["format_minor"] as? Int, name)
            XCTAssertEqual(d.codec, expected["codec"] as? Int, "\(name) codec")
            XCTAssertEqual(d.payloadLen, expected["payload_len"] as? Int, name)
            XCTAssertEqual(d.tsUnit, expected["ts_unit"] as? Int, name)   // multiplier: 1 = ms, 1000 = seconds
            XCTAssertEqual(d.valueMode, expected["value_mode"] as? Int, name)
            XCTAssertEqual(d.scaleE, expected["scale_e"] as? Int, name)
            XCTAssertEqual(String(format: "%08x", d.crc32 ?? 0), expected["crc32"] as? String, name)
            let s = try XCTUnwrap(expected["summary"] as? [String: Any])
            let sum = try XCTUnwrap(d.summary, name)
            XCTAssertEqual(sum.n, s["n"] as? Int, "\(name) n")
            XCTAssertEqual(sum.min, (s["min"] as? NSNumber)?.doubleValue, "\(name) min")
            XCTAssertEqual(sum.max, (s["max"] as? NSNumber)?.doubleValue, "\(name) max")
            XCTAssertEqual(sum.sum, (s["sum"] as? NSNumber)?.doubleValue, "\(name) sum")
            XCTAssertEqual(sum.firstTs, (s["first_ts"] as? NSNumber)?.int64Value, "\(name) first_ts")
            XCTAssertEqual(sum.lastTs, (s["last_ts"] as? NSNumber)?.int64Value, "\(name) last_ts")
            if let pts = expected["points"] as? [[NSNumber]] {
                XCTAssertEqual(d.points.count, pts.count, "\(name) point count")
                for (a, b) in zip(d.points, pts) {
                    XCTAssertEqual(a.ts, b[0].int64Value, name)
                    XCTAssertEqual(a.value.bitPattern, b[1].doubleValue.bitPattern, "\(name) value at \(a.ts)")
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, 20)
    }

    func testReEncodingEveryVectorInputGivesByteIdenticalPayloadHashAndKey() throws {
        var checked = 0
        for (name, status) in try vectorNames() where status == "ok" {
            let input = try json(name, "input.json")
            guard let metric = input["metric"] as? String, let points = inputPoints(input) else { continue }   // minor_higher
            let expected = try json(name)
            let blob = try Data(contentsOf: Self.vectorDir.appendingPathComponent("\(name).agb"))
            let decoded = AGB.decode(blob)
            let day = (input["utc_day"] as! NSNumber).int64Value
            let forced = (input["force_codec"] as? NSNumber)?.intValue
            let enc = try XCTUnwrap(AGB.encodeBlock(points: points, metric: metric, utcDay: day, codec: forced), name)
            XCTAssertEqual([UInt8](enc.payload), decoded.payload, "\(name): uncompressed payload must be byte-identical")
            XCTAssertEqual(AGB.hex(enc.contentHash), expected["content_hash"] as? String, name)
            // Our own container must decode back to the same thing, whatever codec our encoder chose.
            let round = AGB.decode(enc.container)
            XCTAssertEqual(round.status, .ok, name)
            XCTAssertEqual(round.points, decoded.points, name)
            let key = AGB.blockKey(metric: metric, source: AGB.sourceKey(input["source"] as! String)!,
                                   sensorId: sensorId(input["sensor"] as! [String: Any]), utcDay: day)
            XCTAssertEqual(key, expected["block_key"] as? String, name)
            if let dropped = expected["dropped"] as? [String: Int] {
                XCTAssertEqual(enc.dropped.outsideDay, dropped["outside_day"], name)
                XCTAssertEqual(enc.dropped.nonFinite, dropped["non_finite"], name)
                XCTAssertEqual(enc.dropped.badTimestamp, dropped["bad_timestamp"], name)
                XCTAssertEqual(enc.dropped.duplicateTsCollapsed, dropped["duplicate_ts_collapsed"], name)
            }
            checked += 1
        }
        XCTAssertEqual(checked, 19)
    }

    func testFailureVectorsGiveTheirStatusAndReasonAndNeverModifyTheBytes() throws {
        for name in ["unknown_version", "unknown_codec", "corrupt_crc", "corrupt_truncated", "bad_magic"] {
            let expected = try json(name)
            let blob = try Data(contentsOf: Self.vectorDir.appendingPathComponent("\(name).agb"))
            let d = AGB.decode(blob)
            switch expected["status"] as? String {
            case "skip": XCTAssertEqual(d.status, .skip(expected["reason"] as! String), name)
            case "quarantine": XCTAssertEqual(d.status, .quarantine(expected["reason"] as! String), name)
            default: XCTFail("unexpected expectation for \(name)")
            }
            XCTAssertTrue(d.points.isEmpty, name)
            XCTAssertNil(d.summary, name)
        }
    }

    func testHigherMinorDecodesAndHashesTheStoredPayloadIncludingTheExtension() throws {
        let blob = try Data(contentsOf: Self.vectorDir.appendingPathComponent("minor_higher.agb"))
        let d = AGB.decode(blob)
        XCTAssertEqual(d.status, .ok)
        XCTAssertEqual(d.minor, 1)
        XCTAssertEqual(d.points.count, 1)
        XCTAssertEqual(AGB.hex(d.contentHash!), try json("minor_higher")["content_hash"] as? String)
        // Re-encoding drops the extension, so the hash differs (§8) — that is what bumps `revision` on a merge.
        let re = AGB.encodeBlock(points: d.points, metric: "hr", utcDay: d.points[0].ts / AGB.dayMs)!
        XCTAssertNotEqual(re.contentHash, d.contentHash)
    }

    // MARK: Spec worked examples (§7)

    func testWorkedExamplesAreByteExact() {
        let a = AGB.encodeBlock(points: [AGBPoint(ts: 0, value: 70), AGBPoint(ts: 1000, value: 71), AGBPoint(ts: 3000, value: 69)],
                                metric: "hr", utcDay: 0)!
        XCTAssertEqual([UInt8](a.payload), [0x03, 0x01, 0x00, 0x02, 0x02, 0x00, 0x00, 0x8c, 0x01, 0x02, 0x03, 0x00])
        let b = AGB.encodeBlock(points: [AGBPoint(ts: 500, value: 1), AGBPoint(ts: 1000, value: 2)], metric: "hr", utcDay: 0)!
        XCTAssertEqual([UInt8](b.payload), [0x02, 0x00, 0xe8, 0x07, 0xe8, 0x07, 0x00, 0x00, 0x02, 0x02, 0x00])
        // An empty block carries its scale: `00 01 00 <e> 00`.
        let e = AGB.encodeBlock(points: [], metric: "hrv", utcDay: 5)!
        XCTAssertEqual([UInt8](e.payload), [0x00, 0x01, 0x00, 0x01, 0x00])
    }

    // MARK: Canonicalisation edge cases (§6)

    private let day: Int64 = 20_722
    private var t0: Int64 { day * AGB.dayMs }

    func testQuantiseTiesGoTowardPositiveInfinity() {
        XCTAssertEqual(AGB.quantise(100.125, e: 2), 10_013)
        XCTAssertEqual(AGB.quantise(-0.125, e: 2), -12)
        XCTAssertEqual(AGB.quantise(-0.5, e: 0), 0)
        XCTAssertEqual(AGB.quantise(0.5, e: 0), 1)
        XCTAssertNil(AGB.quantise(Double.greatestFiniteMagnitude, e: 4), "an overflowing product is not representable")
    }

    func testUtcDayBoundariesAreInclusiveExclusive() {
        let c = AGB.canonicalise([AGBPoint(ts: t0 - 1, value: 60), AGBPoint(ts: t0, value: 61),
                                  AGBPoint(ts: t0 + AGB.dayMs - 1, value: 62), AGBPoint(ts: t0 + AGB.dayMs, value: 63)],
                                 metric: "hr", utcDay: day)!
        XCTAssertEqual(c.ts, [t0, t0 + AGB.dayMs - 1])
        XCTAssertEqual(c.dropped.outsideDay, 2)
    }

    func testOutOfOrderAndDuplicatePointsCollapseDeterministically() {
        let pts = [AGBPoint(ts: t0 + 30_000, value: 75), AGBPoint(ts: t0 + 10_000, value: 70), AGBPoint(ts: t0 + 20_000, value: 73),
                   AGBPoint(ts: t0 + 10_000, value: 70), AGBPoint(ts: t0 + 20_000, value: 72)]
        let forward = AGB.canonicalise(pts, metric: "hr", utcDay: day)!
        let backward = AGB.canonicalise(pts.reversed(), metric: "hr", utcDay: day)!
        XCTAssertEqual(forward, backward, "arrival order never affects the bytes")
        XCTAssertEqual(forward.q, [70, 73, 75], "the larger quantised value wins a same-instant conflict")
        XCTAssertEqual(forward.dropped.duplicateTsCollapsed, 2)
    }

    func testValuesOutsideTheScaleRangeFallBackToFloat64ForTheWholeBlock() throws {
        let pts = [AGBPoint(ts: t0 + 1000, value: 72), AGBPoint(ts: t0 + 2000, value: 1.5e13), AGBPoint(ts: t0 + 3000, value: 73.5)]
        let enc = try XCTUnwrap(AGB.encodeBlock(points: pts, metric: "hr", utcDay: day))
        let d = AGB.decode(enc.container)
        XCTAssertEqual(d.valueMode, 1)
        XCTAssertEqual(d.values, [72, 1.5e13, 73.5], "no point is dropped for being large, and none is rounded")
    }

    func testNonFiniteAndNegativeZeroAndBadTimestamps() {
        let c = AGB.canonicalise([AGBPoint(ts: t0, value: .nan), AGBPoint(ts: t0 + 1, value: .infinity), AGBPoint(ts: -5, value: 1),
                                  AGBPoint(ts: t0 + 2, value: -0.0)], metric: "temp", utcDay: day)!
        XCTAssertEqual(c.dropped.nonFinite, 2)
        XCTAssertEqual(c.dropped.badTimestamp, 1)
        XCTAssertEqual(c.q, [0])
    }

    func testUnknownMetricIsNeverBlocked() {
        XCTAssertNil(AGB.encodeBlock(points: [AGBPoint(ts: t0, value: 1)], metric: "not_a_metric", utcDay: day))
        XCTAssertNil(AGB.sourceKey("mock"), "sample/demo rows are never blocked")
        XCTAssertEqual(AGB.sourceKey("colmi"), "legacy", "a vendor name never appears in a key (Rule 3)")
    }

    func testMoreThanTheMaximumPointsWritesNoBlock() {
        // 131 072 distinct timestamps cannot exist in one UTC day at ≥ 1 ms spacing only if we cap the input; build it from ms.
        let pts = (0..<(AGB.maxPoints + 1)).map { AGBPoint(ts: t0 + Int64($0), value: 60) }
        XCTAssertNil(AGB.encodeBlock(points: pts, metric: "hr", utcDay: day))
    }

    func testScaleTableMatchesTheSpecAndCatalog() {
        XCTAssertEqual(AGB.scales.count, 20)
        for (k, e) in [("hr", 0), ("hrv", 1), ("temp", 2), ("glucose", 2), ("met", 1), ("uric_acid", 1), ("steps", 0), ("sleep_stage", 0)] {
            XCTAssertEqual(AGB.scales[k], e, k)
        }
        // Every MeasurementKind has a scale (a new kind must get a §5 row in the same change).
        for kind in MeasurementKind.allCases { XCTAssertNotNil(AGB.scales[kind.rawValue], "\(kind.rawValue) has no §5 scale") }
    }

    // MARK: Identity (§4)

    func testSensorIdsMatchTheGoldenVectors() throws {
        XCTAssertEqual(AGB.sensorId(ringMac: "EE:A6:A7:00:00:2A"), "a3a04cab4846d63c")
        XCTAssertEqual(AGB.sensorId(ringMac: "ee-a6-a7-00-00-2a"), "a3a04cab4846d63c", "case and separator are normalised")
        XCTAssertNil(AGB.sensorId(ringMac: "not a mac"))
        let bp = try json("bp_manual_phone", "input.json")
        let expected = try json("bp_manual_phone")
        XCTAssertEqual(AGB.sensorId(installUUID: (bp["sensor"] as! [String: Any])["install_uuid"] as! String), expected["sensor_id"] as? String)
    }

    func testRingMacFromTheA1ReplyIsReversedBytes12To17() {
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 0xA1
        frame[3] = 1   // status byte: non-zero = accepted
        for (i, b) in [0x41, 0x57, 0x87, 0x06, 0x42, 0x41].enumerated() { frame[12 + i] = UInt8(b) }
        XCTAssertEqual(AGB.ringMac(fromA1: frame), "41:42:06:87:57:41")
        frame[3] = 0   // a refusal
        XCTAssertNil(AGB.ringMac(fromA1: frame))
        frame[3] = 1
        for i in 12...17 { frame[i] = 0 }
        XCTAssertNil(AGB.ringMac(fromA1: frame), "an all-zero field is no identity")
        XCTAssertNil(AGB.ringMac(fromA1: Array(frame[0..<10])))
    }

    // MARK: Hostile input (§3, §8, §13)

    private func header(codec: UInt8 = 0, payloadLen: UInt64, crc: UInt32, body: [UInt8], major: UInt8 = 1, minor: UInt8 = 0) -> Data {
        var out: [UInt8] = [0x41, 0x47, major, minor, codec]
        AGB.putUvarint(&out, payloadLen)
        var c = crc.littleEndian
        withUnsafeBytes(of: &c) { out.append(contentsOf: $0) }
        return Data(out + body)
    }

    func testPayloadLengthAboveTheCapIsRefusedBeforeAllocating() {
        let d = AGB.decode(header(payloadLen: UInt64(AGB.maxPayload) + 1, crc: 0, body: []))
        XCTAssertEqual(d.status, .quarantine("payload_too_large"))
    }

    func testCodecZeroLengthChecks() {
        XCTAssertEqual(AGB.decode(header(payloadLen: 5, crc: 0, body: [0, 1])).status, .quarantine("truncated"))
        XCTAssertEqual(AGB.decode(header(payloadLen: 1, crc: 0, body: [0, 1])).status, .quarantine("trailing_bytes"))
        XCTAssertEqual(AGB.decode(Data([0x41, 0x47, 1, 0])).status, .quarantine("bad_magic"), "shorter than the fixed header")
    }

    func testAnInflateBombIsRejectedAfterPayloadLenPlusOneBytes() {
        // 1 MiB of zeros deflates to ~1 KB; declare a payload length far smaller than that.
        let bomb = [UInt8](repeating: 0, count: 1 << 20)
        let full = AGB.wrap(payload: bomb, codec: 1)
        var forged = [UInt8](full)
        // Rewrite payload_len (uvar at offset 5) to 8: keep codec 1 and the DEFLATE body.
        let bodyStart = 5 + 3 + 4   // 1 MiB needs a 3-byte uvar
        forged = Array(forged[0..<5]) + [8] + Array(forged[(5 + 3)..<(5 + 3 + 4)]) + Array(forged[bodyStart...])
        let d = AGB.decode(Data(forged))
        if case .quarantine = d.status {} else { XCTFail("a bomb must quarantine, got \(d.status)") }
    }

    func testVarintOverflowAndTruncatedPayloadsQuarantineInsteadOfCrashing() {
        // payload: n as an 11-byte varint
        let bad: [UInt8] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
        let d = AGB.decode(header(payloadLen: UInt64(bad.count), crc: AGB.crc32(bad), body: bad))
        XCTAssertEqual(d.status, .quarantine("varint_overflow"))
        let short: [UInt8] = [0x03, 0x01]   // n = 3, seconds, then nothing
        XCTAssertEqual(AGB.decode(header(payloadLen: 2, crc: AGB.crc32(short), body: short)).status, .quarantine("truncated"))
    }

    func testCorruptionOfAnyByteNeverCrashesAndNeverReturnsWrongData() throws {
        let blob = try Data(contentsOf: Self.vectorDir.appendingPathComponent("hrv_history.agb"))
        let good = AGB.decode(blob)
        var quarantined = 0
        for i in 0..<blob.count {
            for flip in [UInt8(0x01), 0x80, 0xFF] {
                var b = [UInt8](blob)
                b[i] ^= flip
                let d = AGB.decode(Data(b))
                if d.status == .ok { XCTAssertEqual(d.points, good.points, "a flipped byte that still decodes must not change the data (offset \(i))") }
                else { quarantined += 1 }
            }
        }
        XCTAssertGreaterThan(quarantined, 0)
    }

    func testCRCMatchesTheGzipCRC() {
        XCTAssertEqual(AGB.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(AGB.crc32([UInt8]()), 0)
    }

    // MARK: Merge (§10)

    private func lcgPoints(seed: Int64, count: Int, metric: String = "hr") -> [AGBPoint] {
        var x = seed
        func draw() -> Int64 { x = (x &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff; return x >> 16 }
        return (0..<count).map { _ in AGBPoint(ts: t0 + (draw() % 600) * 1000, value: Double(50 + draw() % 60)) }
    }

    private func block(_ pts: [AGBPoint]) -> Data { AGB.encodeBlock(points: pts, metric: "hr", utcDay: day)!.container }

    func testMergeIsCommutativeAssociativeAndIdempotent() throws {
        let a = block(lcgPoints(seed: 1, count: 300)), b = block(lcgPoints(seed: 2, count: 300)), c = block(lcgPoints(seed: 3, count: 300))
        func m(_ x: Data, _ y: Data) throws -> Data { try AGB.merge(x, y, metric: "hr", utcDay: day).container }
        func h(_ x: Data) -> Data { AGB.decode(x).contentHash! }
        XCTAssertEqual(h(try m(a, b)), h(try m(b, a)), "commutative")
        XCTAssertEqual(h(try m(try m(a, b), c)), h(try m(a, try m(b, c))), "associative")
        XCTAssertEqual(h(try m(a, a)), h(a), "idempotent")
        XCTAssertEqual(h(try m(try m(a, b), b)), h(try m(a, b)), "re-merging a copy changes nothing")
    }

    func testMergeConflictKeepsTheLargerQuantisedValueInEitherOrder() throws {
        let a = block([AGBPoint(ts: t0 + 1000, value: 70)]), b = block([AGBPoint(ts: t0 + 1000, value: 72)])
        for pair in [(a, b), (b, a)] {
            let merged = AGB.decode(try AGB.merge(pair.0, pair.1, metric: "hr", utcDay: day).container)
            XCTAssertEqual(merged.values, [72])
        }
    }

    func testMergeAppliesTombstonesAndRefusesUnreadableInputs() throws {
        let a = block([AGBPoint(ts: t0 + 1000, value: 70), AGBPoint(ts: t0 + 2000, value: 71)])
        let b = block([AGBPoint(ts: t0 + 3000, value: 72)])
        let merged = AGB.decode(try AGB.merge(a, b, metric: "hr", utcDay: day, tombstones: [t0 + 2000]).container)
        XCTAssertEqual(merged.timestamps, [t0 + 1000, t0 + 3000])
        var corrupt = [UInt8](a); corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertThrowsError(try AGB.merge(Data(corrupt), b, metric: "hr", utcDay: day)) {
            guard case .unreadable = $0 as? AGB.MergeError else { return XCTFail("\($0)") }
        }
    }

    func testMergeRequantisesABlockWrittenAtAnotherScale() throws {
        // A block that carries e = 0 for a metric whose current scale is 1 converges on the current scale.
        let old = AGB.encodeBlock(points: [AGBPoint(ts: t0 + 1000, value: 66)], metric: "hr", utcDay: day)!.container
        let other = AGB.encodeBlock(points: [AGBPoint(ts: t0 + 2000, value: 71.5)], metric: "hrv", utcDay: day)!.container
        let merged = AGB.decode(try AGB.merge(old, other, metric: "hrv", utcDay: day).container)
        XCTAssertEqual(merged.scaleE, 1)
        XCTAssertEqual(merged.values, [66, 71.5])
    }

    func testAppleDeflateOutputIsDecodableAndSmallerThanThePayloadWhenItShould() throws {
        let enc = AGB.encodeBlock(points: lcgPoints(seed: 9, count: 600), metric: "hr", utcDay: day)!
        let d = AGB.decode(enc.container)
        XCTAssertEqual(d.codec, 1, "a 600-point block should compress")
        XCTAssertLessThan(enc.container.count, enc.payload.count + 12)
        let tiny = AGB.encodeBlock(points: [AGBPoint(ts: t0, value: 71)], metric: "hr", utcDay: day)!
        XCTAssertEqual(AGB.decode(tiny.container).codec, 0, "codec 1 only when strictly smaller (§3)")
    }
}
