import Foundation
import Compression
import CryptoKit

// AGB v1 — the Agara block format. Authoritative spec: docs/ring/storage-format.md (Rule 5: nothing in
// here is invented; every rule cites the section it implements). Python reference: scripts/agb_ref.py.
// Golden vectors: ring-emulator/testdata/agb/ (run by AGBCodecTests, never copied).
//
// Two conforming writers given the same points MUST produce the same UNCOMPRESSED payload bytes and so the
// same content_hash. Compressed bytes are NOT normative (Apple COMPRESSION_ZLIB and zlib differ), so nothing
// here ever hashes or compares them. Pure value logic: no SwiftData, no main-actor state.

/// One decoded or to-be-encoded point: epoch milliseconds and a value.
nonisolated struct AGBPoint: Equatable, Sendable {
    var ts: Int64
    var value: Double
}

/// Outcome of a decode (§8): readers never throw. `skip` = made by a newer version (keep bytes, show a gap);
/// `quarantine` = corruption (keep bytes, flag, never delete).
nonisolated enum AGBStatus: Equatable, Sendable {
    case ok
    case skip(String)
    case quarantine(String)

    var reason: String? {
        switch self {
        case .ok: return nil
        case let .skip(r), let .quarantine(r): return r
        }
    }
}

/// Summary columns (§9), computed from the decoded points.
nonisolated struct AGBSummary: Equatable, Sendable {
    var n: Int
    var min: Double?
    var max: Double?
    var sum: Double?
    var firstTs: Int64?
    var lastTs: Int64?
}

/// What the writer discarded while canonicalising (§6 step 1 and 4). Diagnostics only.
nonisolated struct AGBDropped: Equatable, Sendable {
    var outsideDay = 0
    var nonFinite = 0
    var badTimestamp = 0
    var duplicateTsCollapsed = 0
}

nonisolated struct AGBDecoded: Sendable {
    var status: AGBStatus = .ok
    var major: Int?
    var minor: Int?
    var codec: Int?
    var payloadLen: Int?
    var crc32: UInt32?
    /// The uncompressed payload as stored (including minor-extension bytes). Set once the CRC checked out.
    var payload: [UInt8]?
    var tsUnit: Int?
    var valueMode: Int?
    var scaleE: Int?
    var timestamps: [Int64] = []
    /// Fixed-point integers (mode 0) or empty (mode 1).
    var q: [Int64] = []
    var values: [Double] = []

    var points: [AGBPoint] { zip(timestamps, values).map { AGBPoint(ts: $0, value: $1) } }
    var isOK: Bool { status == .ok }

    /// SHA-256 of the payload (§10). For a block in state skip/quarantine use `AGB.containerHash`.
    var contentHash: Data? { payload.map { AGB.sha256(Data($0)) } }

    /// §9. Empty block: n = 0, everything else nil. A non-ok block has no summary (nil).
    var summary: AGBSummary? {
        guard isOK else { return nil }
        let n = timestamps.count
        guard n > 0 else { return AGBSummary(n: 0, min: nil, max: nil, sum: nil, firstTs: nil, lastTs: nil) }
        if valueMode == 0, let e = scaleE {
            let s = AGB.pow10[e]
            var lo = q[0], hi = q[0], total: Int64 = 0
            for x in q { if x < lo { lo = x }; if x > hi { hi = x }; total += x }
            return AGBSummary(n: n, min: Double(lo) / s, max: Double(hi) / s, sum: Double(total) / s,
                              firstTs: timestamps[0], lastTs: timestamps[n - 1])
        }
        var acc = 0.0
        var lo = values[0], hi = values[0]
        for v in values { acc += v; if v < lo { lo = v }; if v > hi { hi = v } }   // strict left-to-right
        return AGBSummary(n: n, min: lo, max: hi, sum: acc, firstTs: timestamps[0], lastTs: timestamps[n - 1])
    }
}

nonisolated struct AGBEncoded: Sendable {
    var container: Data
    var payload: Data
    var contentHash: Data
    var pointCount: Int
    var dropped: AGBDropped
}

/// A canonicalised block body (§6): mode 0 keeps the quantised integers, mode 1 the raw doubles.
nonisolated struct AGBCanonical: Equatable, Sendable {
    var mode: UInt8
    var e: Int
    var ts: [Int64]
    var q: [Int64]
    var v: [Double]
    var dropped: AGBDropped
    var count: Int { ts.count }
}

nonisolated private struct AGBFailure: Error {
    let status: AGBStatus
    static func skip(_ r: String) -> AGBFailure { AGBFailure(status: .skip(r)) }
    static func quarantine(_ r: String) -> AGBFailure { AGBFailure(status: .quarantine(r)) }
}

nonisolated enum AGB {
    // MARK: Constants (§3, §5) — from the generated catalog wherever the catalog carries them.

    static let magic: [UInt8] = [0x41, 0x47]
    static let major = UInt8(AgaraConfig.Storage.blockFormatMajor)
    static let minor = UInt8(AgaraConfig.Storage.blockFormatMinor)
    static let dayMs: Int64 = 86_400_000
    static let maxPoints = AgaraConfig.Storage.blockMaxPoints
    static let maxPayload = AgaraConfig.Storage.blockMaxPayloadBytes
    static let maxQ: Int64 = (1 << 40) - 1
    static let maxTs: Int64 = (1 << 53) - 1
    static let unknownSensor = AgaraConfig.Storage.sensorUnknownId
    /// Exactly representable powers of ten: the only multiplier/divisor either side of quantising ever uses.
    static let pow10: [Double] = [1, 10, 100, 1_000, 10_000]

    /// Frozen per-metric decimal exponent (§5), parsed from `AgaraConfig.Storage.blockScales`.
    static let scales: [String: Int] = {
        var out: [String: Int] = [:]
        for pair in AgaraConfig.Storage.blockScales.split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let e = Int(kv[1]) { out[String(kv[0])] = e }
        }
        return out
    }()

    static let sources: Set<String> = ["ring", "history", "live", "workout", "manual", "legacy"]

    // MARK: Identity (§4)

    /// Map a `MeasurementSource` raw value to the key spelling; nil for `mock` (never blocked) and unknowns.
    static func sourceKey(_ raw: String) -> String? {
        let mapped = raw == "colmi" ? "legacy" : raw   // the decode-only raw value of an earlier ring family
        return sources.contains(mapped) ? mapped : nil
    }

    static func blockKey(metric: String, source: String, sensorId: String, utcDay: Int64) -> String {
        "v1/\(metric)/\(source)/\(sensorId)/\(utcDay)"
    }

    /// `a1` reply bytes 12...17 reversed, uppercase colon hex (BLE-address order). Nil for a refusal, a short frame or an
    /// all-zero field — same rule as Android's `VeepooDecoder.ringMac`.
    static func ringMac(fromA1 frame: [UInt8]) -> String? {
        guard frame.count >= 18, frame[0] == 0xA1, frame[3] != 0 else { return nil }
        let bytes = (12...17).reversed().map { frame[$0] }
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func normalizedMac(_ mac: String) -> String? {
        let parts = mac.replacingOccurrences(of: "-", with: ":").uppercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.joined(separator: ":")
    }

    static func sensorId(ringMac mac: String) -> String? {
        guard let norm = normalizedMac(mac) else { return nil }
        return hex16(Data(("agara.sensor.v1|ring|" + norm).utf8))
    }

    static func sensorId(installUUID uuid: String) -> String {
        hex16(Data(("agara.sensor.v1|install|" + uuid.lowercased()).utf8))
    }

    private static func hex16(_ data: Data) -> String {
        sha256(data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Hash and CRC

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha256(_ bytes: [UInt8]) -> Data { Data(SHA256.hash(data: bytes)) }

    /// Hash of a block in state skip/quarantine: the stored container (identification only, §10).
    static func containerHash(_ container: Data) -> Data { sha256(container) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// CRC-32/IEEE (the gzip CRC).
    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Primitives (§2)

    static func zz(_ n: Int64) -> UInt64 { UInt64(bitPattern: (n << 1) ^ (n >> 63)) }
    static func unzz(_ u: UInt64) -> Int64 { Int64(bitPattern: u >> 1) ^ -Int64(bitPattern: u & 1) }

    static func putUvarint(_ out: inout [UInt8], _ value: UInt64) {
        var u = value
        while u >= 0x80 { out.append(UInt8(u & 0x7F) | 0x80); u >>= 7 }
        out.append(UInt8(u))
    }

    /// LEB128, at most 10 bytes, must fit 64 bits; a non-minimal encoding is accepted.
    private static func getUvarint(_ b: [UInt8], _ i: inout Int, _ end: Int) throws -> UInt64 {
        var r: UInt64 = 0
        var shift: UInt64 = 0
        for k in 0..<10 {
            guard i < end else { throw AGBFailure.quarantine("truncated") }
            let c = b[i]
            i += 1
            if k == 9 && c > 1 { throw AGBFailure.quarantine("varint_overflow") }
            r |= UInt64(c & 0x7F) << shift
            if c < 0x80 { return r }
            shift += 7
        }
        throw AGBFailure.quarantine("varint_overflow")
    }

    // MARK: Canonicalisation (§6)

    /// `q = floor(v × 10^e + 0.5)` — one multiply, one add, one floor; nil when the product is not finite.
    static func quantise(_ v: Double, e: Int) -> Double? {
        let scaled = v * pow10[e]
        guard scaled.isFinite else { return nil }
        let shifted = scaled + 0.5
        return shifted.rounded(.down)
    }

    /// Input: any set of points for one key. Output: the canonical, sorted, de-duplicated body (§6 steps 1-4).
    /// Nil when `metric` has no §5 scale (unknown metrics are never blocked).
    static func canonicalise(_ points: [AGBPoint], metric: String, utcDay: Int64) -> AGBCanonical? {
        guard let e = scales[metric] else { return nil }
        let lo = utcDay * dayMs, hi = (utcDay + 1) * dayMs
        var dropped = AGBDropped()
        var kept: [AGBPoint] = []
        kept.reserveCapacity(points.count)
        for p in points {
            if p.ts < 0 || p.ts > maxTs { dropped.badTimestamp += 1; continue }
            if p.ts < lo || p.ts >= hi { dropped.outsideDay += 1; continue }
            if !p.value.isFinite { dropped.nonFinite += 1; continue }
            kept.append(p)
        }
        var qs: [Int64] = []
        qs.reserveCapacity(kept.count)
        var fixed = true
        for p in kept {
            if let f = quantise(p.value, e: e), abs(f) <= Double(maxQ) { qs.append(Int64(f)) } else { fixed = false; break }
        }
        var out = AGBCanonical(mode: fixed ? 0 : 1, e: e, ts: [], q: [], v: [], dropped: dropped)
        if fixed {
            var items = zip(kept.map(\.ts), qs).map { (ts: $0, q: $1) }
            items.sort { $0.ts != $1.ts ? $0.ts < $1.ts : $0.q < $1.q }
            for it in items {
                if let last = out.ts.last, last == it.ts {
                    out.q[out.q.count - 1] = it.q            // same ts: the larger value (sorted last) wins
                    out.dropped.duplicateTsCollapsed += 1
                } else { out.ts.append(it.ts); out.q.append(it.q) }
            }
        } else {
            var items = kept.map { (ts: $0.ts, v: $0.value + 0.0) }   // +0.0 turns -0.0 into 0.0
            items.sort { $0.ts != $1.ts ? $0.ts < $1.ts : $0.v < $1.v }
            for it in items {
                if let last = out.ts.last, last == it.ts {
                    out.v[out.v.count - 1] = it.v
                    out.dropped.duplicateTsCollapsed += 1
                } else { out.ts.append(it.ts); out.v.append(it.v) }
            }
        }
        return out
    }

    // MARK: Payload (§7)

    /// Nil when the block would exceed the format limits (§6 step 5: the rows stay hot).
    static func encodePayload(_ c: AGBCanonical) -> [UInt8]? {
        let n = c.count
        guard n <= maxPoints else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16 + n * 3)
        putUvarint(&out, UInt64(n))
        let seconds = c.ts.allSatisfy { $0 % 1000 == 0 }
        let unit: Int64 = seconds ? 1000 : 1
        out.append(seconds ? 1 : 0)
        if n > 0 {
            let t = c.ts.map { $0 / unit }
            putUvarint(&out, zz(t[0]))
            if n > 1 {
                var dPrev = t[1] - t[0]
                putUvarint(&out, zz(dPrev))
                if n > 2 {
                    for i in 2..<n {
                        let d = t[i] - t[i - 1]
                        putUvarint(&out, zz(d - dPrev))
                        dPrev = d
                    }
                }
            }
        }
        out.append(c.mode)
        if c.mode == 0 {
            out.append(UInt8(c.e))
            var prev: Int64 = 0
            for q in c.q { putUvarint(&out, zz(q - prev)); prev = q }
        } else {
            for v in c.v {
                var bits = v.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
            }
        }
        out.append(0)   // flags_present
        return out.count <= maxPayload ? out : nil
    }

    // MARK: Container (§3)

    /// Wrap an uncompressed payload. `codec == nil` = DEFLATE iff strictly smaller than the payload.
    static func wrap(payload: [UInt8], codec: Int? = nil, minor: UInt8 = AGB.minor) -> Data {
        var body = payload
        var used: UInt8 = 0
        if codec == nil || codec == 1, let deflated = deflate(payload), codec == 1 || deflated.count < payload.count {
            body = deflated
            used = 1
        }
        var out: [UInt8] = magic + [major, minor, used]
        putUvarint(&out, UInt64(payload.count))
        var crc = crc32(payload).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        out.append(contentsOf: body)
        return Data(out)
    }

    /// Raw DEFLATE via Apple's `COMPRESSION_ZLIB` (no zlib or gzip wrapper; level is Apple's, §3 allows it).
    private static func deflate(_ payload: [UInt8]) -> [UInt8]? {
        guard !payload.isEmpty else { return nil }
        // Ask for at most payload.count bytes so a stream that doesn't shrink is reported as 0 (=> codec 0).
        var dst = [UInt8](repeating: 0, count: payload.count + 64)
        let written = compression_encode_buffer(&dst, dst.count, payload, payload.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { return nil }
        return Array(dst[0..<written])
    }

    /// Inflate exactly `payloadLen` bytes with an output cap of `payloadLen + 1` (§3: a stream that inflates further
    /// is a bomb). Errors follow the reference: a stream that never ends is `inflate_error`; wrong length is
    /// `length_mismatch`; bytes after the end of the stream are `trailing_bytes`.
    private static func inflate(_ body: [UInt8], payloadLen: Int) throws -> [UInt8] {
        let capacity = payloadLen + 1
        var dst = [UInt8](repeating: 0, count: capacity)
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw AGBFailure.quarantine("inflate_error")
        }
        defer { compression_stream_destroy(streamPtr) }
        var produced = 0
        var ended = false
        var errored = false
        var trailing = false
        var input = body
        input.withUnsafeMutableBufferPointer { inBuf in
            dst.withUnsafeMutableBufferPointer { outBuf in
                streamPtr.pointee.src_ptr = UnsafePointer(inBuf.baseAddress ?? UnsafeMutablePointer<UInt8>(bitPattern: 1)!)
                streamPtr.pointee.src_size = inBuf.count
                streamPtr.pointee.dst_ptr = outBuf.baseAddress!
                streamPtr.pointee.dst_size = outBuf.count
                while true {
                    let srcBefore = streamPtr.pointee.src_size, dstBefore = streamPtr.pointee.dst_size
                    let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    produced = outBuf.count - streamPtr.pointee.dst_size
                    if status == COMPRESSION_STATUS_END {
                        ended = true
                        trailing = streamPtr.pointee.src_size > 0
                        break
                    }
                    if status == COMPRESSION_STATUS_ERROR { errored = true; break }
                    // OK: keep going until END. Stop when the output is full (more than payload_len => bomb) or
                    // a pass moved nothing (the stream is cut short).
                    if streamPtr.pointee.dst_size == 0 { break }
                    if streamPtr.pointee.src_size == srcBefore && streamPtr.pointee.dst_size == dstBefore { break }
                }
            }
        }
        if errored { throw AGBFailure.quarantine("inflate_error") }
        if !ended { throw AGBFailure.quarantine(produced > payloadLen ? "length_mismatch" : "inflate_error") }
        if trailing { throw AGBFailure.quarantine("trailing_bytes") }
        if produced != payloadLen { throw AGBFailure.quarantine("length_mismatch") }
        return Array(dst[0..<payloadLen])
    }

    /// Canonicalise + encode (§6, §7, §3). Nil for an unknown metric or a block over the format limits.
    static func encodeBlock(points: [AGBPoint], metric: String, utcDay: Int64, codec: Int? = nil) -> AGBEncoded? {
        guard let canonical = canonicalise(points, metric: metric, utcDay: utcDay), let payload = encodePayload(canonical) else { return nil }
        return AGBEncoded(container: wrap(payload: payload, codec: codec), payload: Data(payload),
                          contentHash: sha256(payload), pointCount: canonical.count, dropped: canonical.dropped)
    }

    // MARK: Decode (§8)

    /// Never throws: returns ok, skip or quarantine; the caller keeps the stored bytes in every non-ok case.
    static func decode(_ blob: Data) -> AGBDecoded {
        var r = AGBDecoded()
        do {
            try decodeInto(&r, [UInt8](blob))
        } catch let failure as AGBFailure {
            r.status = failure.status
            r.timestamps = []; r.q = []; r.values = []
            r.payload = nil
        } catch {
            r.status = .quarantine("inflate_error")
        }
        return r
    }

    private static func decodeInto(_ r: inout AGBDecoded, _ blob: [UInt8]) throws {
        guard blob.count >= 5, blob[0] == magic[0], blob[1] == magic[1] else { throw AGBFailure.quarantine("bad_magic") }
        r.major = Int(blob[2]); r.minor = Int(blob[3]); r.codec = Int(blob[4])
        guard blob[2] == major else { throw AGBFailure.skip("unknown_version") }
        guard blob[4] == 0 || blob[4] == 1 else { throw AGBFailure.skip("unknown_codec") }
        var i = 5
        let plen64 = try getUvarint(blob, &i, blob.count)
        guard plen64 <= UInt64(maxPayload) else { throw AGBFailure.quarantine("payload_too_large") }
        let plen = Int(plen64)
        guard i + 4 <= blob.count else { throw AGBFailure.quarantine("truncated") }
        let crc = UInt32(blob[i]) | UInt32(blob[i + 1]) << 8 | UInt32(blob[i + 2]) << 16 | UInt32(blob[i + 3]) << 24
        r.crc32 = crc
        r.payloadLen = plen
        let body = Array(blob[(i + 4)...])
        let payload: [UInt8]
        if blob[4] == 0 {
            if body.count < plen { throw AGBFailure.quarantine("truncated") }
            if body.count > plen { throw AGBFailure.quarantine("trailing_bytes") }
            payload = body
        } else {
            payload = try inflate(body, payloadLen: plen)
        }
        guard crc32(payload) == crc else { throw AGBFailure.quarantine("crc_mismatch") }
        r.payload = payload
        try parsePayload(&r, payload)
    }

    private static func parsePayload(_ r: inout AGBDecoded, _ p: [UInt8]) throws {
        let end = p.count
        var i = 0
        let n64 = try getUvarint(p, &i, end)
        guard n64 <= UInt64(maxPoints) else { throw AGBFailure.quarantine("too_many_points") }
        let n = Int(n64)
        guard i < end else { throw AGBFailure.quarantine("truncated") }
        let unitByte = p[i]; i += 1
        guard unitByte == 0 || unitByte == 1 else { throw AGBFailure.quarantine("bad_ts_unit") }
        let unit: Int64 = unitByte == 1 ? 1000 : 1
        r.tsUnit = Int(unit)
        var ts: [Int64] = []
        ts.reserveCapacity(n)
        var overflow = false
        if n > 0 {
            var t = unzz(try getUvarint(p, &i, end))
            ts.append(t)
            if n > 1 {
                var d = unzz(try getUvarint(p, &i, end))
                var (nt, o) = t.addingReportingOverflow(d); overflow = overflow || o; t = nt
                ts.append(t)
                if n > 2 {
                    for _ in 0..<(n - 2) {
                        let dod = unzz(try getUvarint(p, &i, end))
                        (d, o) = d.addingReportingOverflow(dod); overflow = overflow || o
                        (nt, o) = t.addingReportingOverflow(d); overflow = overflow || o; t = nt
                        ts.append(t)
                    }
                }
            }
        }
        var scaled: [Int64] = []
        scaled.reserveCapacity(n)
        for t in ts {
            let (m, o) = t.multipliedReportingOverflow(by: unit)
            if o { overflow = true }
            scaled.append(m)
        }
        if overflow || scaled.contains(where: { $0 < 0 || $0 > maxTs }) { throw AGBFailure.quarantine("bad_timestamp") }
        for k in 1..<max(1, scaled.count) where scaled[k] <= scaled[k - 1] { throw AGBFailure.quarantine("not_sorted") }
        guard i < end else { throw AGBFailure.quarantine("truncated") }
        let mode = p[i]; i += 1
        var q: [Int64] = []
        var vals: [Double] = []
        vals.reserveCapacity(n)
        if mode == 0 {
            guard i < end else { throw AGBFailure.quarantine("truncated") }
            let e = Int(p[i]); i += 1
            guard e <= 4 else { throw AGBFailure.quarantine("bad_scale") }
            r.scaleE = e
            let s = pow10[e]
            q.reserveCapacity(n)
            var cur: Int64 = 0
            for _ in 0..<n {
                let delta = unzz(try getUvarint(p, &i, end))
                let (sum, o) = cur.addingReportingOverflow(delta)
                if o || abs(sum) > maxQ { throw AGBFailure.quarantine("value_range") }
                cur = sum
                q.append(cur)
                vals.append(Double(cur) / s)
            }
        } else if mode == 1 {
            guard i + 8 * n <= end else { throw AGBFailure.quarantine("truncated") }
            for _ in 0..<n {
                var bits: UInt64 = 0
                for k in 0..<8 { bits |= UInt64(p[i + k]) << UInt64(8 * k) }
                i += 8
                let v = Double(bitPattern: bits)
                guard v.isFinite else { throw AGBFailure.quarantine("value_range") }
                vals.append(v)
            }
        } else {
            throw AGBFailure.quarantine("bad_value_mode")
        }
        r.valueMode = Int(mode)
        guard i < end else { throw AGBFailure.quarantine("truncated") }
        let flags = p[i]; i += 1
        if flags == 1 {
            guard i + n <= end else { throw AGBFailure.quarantine("truncated") }
            i += n   // per-point flags: ignored by 1.0 readers
        } else if flags != 0 {
            throw AGBFailure.quarantine("bad_flags")
        }
        if i != end && r.minor == 0 { throw AGBFailure.quarantine("trailing_bytes") }
        r.timestamps = scaled
        r.q = q
        r.values = vals
    }

    // MARK: Merge (§10)

    enum MergeError: Error, Equatable { case unreadable(AGBStatus), unknownMetric, tooManyPoints }

    /// Union of two readable blocks of one key, minus tombstoned timestamps, re-quantised at the current scale and
    /// encoded canonically. Commutative, associative and idempotent. A merge with a skip/quarantine block is refused.
    static func merge(_ a: Data, _ b: Data, metric: String, utcDay: Int64, tombstones: Set<Int64> = [],
                      codec: Int? = nil) throws -> AGBEncoded {
        let da = decode(a), db = decode(b)
        for d in [da, db] where d.status != .ok { throw MergeError.unreadable(d.status) }
        return try mergePoints(da.points + db.points, metric: metric, utcDay: utcDay, tombstones: tombstones, codec: codec)
    }

    /// The same rule for an already-decoded union (rows + a block, or a block minus a deleted point).
    static func mergePoints(_ points: [AGBPoint], metric: String, utcDay: Int64, tombstones: Set<Int64> = [],
                            codec: Int? = nil) throws -> AGBEncoded {
        guard scales[metric] != nil else { throw MergeError.unknownMetric }
        let live = tombstones.isEmpty ? points : points.filter { !tombstones.contains($0.ts) }
        guard let enc = encodeBlock(points: live, metric: metric, utcDay: utcDay, codec: codec) else { throw MergeError.tooManyPoints }
        return enc
    }
}
