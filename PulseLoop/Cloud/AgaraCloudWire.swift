import Foundation

// The wire types of docs/ring/cloud-v2.md (§2) and storage-format.md §12. Field names are the server's snake_case.
// Encoding is deterministic — sorted keys, no whitespace, unescaped slashes — so the bytes uploaded for the same
// input are the same on both platforms (asserted by the golden test).

nonisolated struct WireFormat: Codable, Equatable, Sendable {
    var major: Int
    var minor: Int
    var codec: Int
}

nonisolated struct WireSummary: Codable, Equatable, Sendable {
    var n: Int
    var min: Double?
    var max: Double?
    var sum: Double?
    var firstTs: Int64?
    var lastTs: Int64?
    enum CodingKeys: String, CodingKey { case n, min, max, sum, firstTs = "first_ts", lastTs = "last_ts" }
}

nonisolated struct ExactSummary: Equatable, Sendable {
    var min: String
    var max: String
    var sum: String
}

nonisolated struct WireBlock: Codable, Equatable, Sendable {
    var blockKey: String
    var metric: String
    var source: String
    var sensorId: String
    var utcDay: Int
    var revision: Int
    var sealed: Bool
    var fmt: WireFormat
    var contentHash: String
    var summary: WireSummary
    var tombstones: [Int64]?
    /// Standard padded base64 of the container bytes.
    var data: String
    /// Exact decimal spelling of min / max / sum for the upload (not part of the JSON model; see `WireBlockBuilder`).
    var exactSummary: ExactSummary?
    enum CodingKeys: String, CodingKey {
        case blockKey = "block_key", metric, source, sensorId = "sensor_id", utcDay = "utc_day", revision, sealed, fmt
        case contentHash = "content_hash", summary, tombstones, data
    }
}

nonisolated struct WireDay: Codable, Equatable, Sendable {
    var date: String
    var steps: Int
    var distanceKm: Double
    var calories: Double
    var sleepStart: String?
    var sleepEnd: String?
    var deep: Int
    var light: Int
    var awake: Int
    var other: Int
    var sleepMinutes: Int
    var sleepScore: Int
    /// When this day was last **confirmed from the ring** (cloud-v2 §2.1). Absent means unknown — never zero: without
    /// it a missed sync day and a genuinely quiet day look identical, and a consistency metric counts the first as a
    /// real zero. `ActivityDaily.syncedAt` already carries this locally; it just never left the device.
    var syncedAt: Int64?
    enum CodingKeys: String, CodingKey {
        case date, steps, distanceKm = "distance_km", calories, sleepStart = "sleep_start", sleepEnd = "sleep_end"
        case deep, light, awake, other, sleepMinutes = "sleep_minutes", sleepScore = "sleep_score", syncedAt = "synced_at"
    }

    init(date: String, steps: Int, distanceKm: Double, calories: Double, sleepStart: String? = nil, sleepEnd: String? = nil,
         deep: Int = 0, light: Int = 0, awake: Int = 0, other: Int = 0, sleepMinutes: Int = 0, sleepScore: Int = 0,
         syncedAt: Int64? = nil) {
        self.date = date; self.steps = steps; self.distanceKm = distanceKm; self.calories = calories
        self.sleepStart = sleepStart; self.sleepEnd = sleepEnd
        self.deep = deep; self.light = light; self.awake = awake; self.other = other
        self.sleepMinutes = sleepMinutes; self.sleepScore = sleepScore; self.syncedAt = syncedAt
    }

    /// Tolerant: the server may omit zero fields or send numbers as doubles; missing fields read as 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Double { (try? c.decode(Double.self, forKey: key)) ?? 0 }
        date = try c.decode(String.self, forKey: .date)
        steps = Int(number(.steps)); distanceKm = number(.distanceKm); calories = number(.calories)
        sleepStart = try? c.decodeIfPresent(String.self, forKey: .sleepStart)
        sleepEnd = try? c.decodeIfPresent(String.self, forKey: .sleepEnd)
        deep = Int(number(.deep)); light = Int(number(.light)); awake = Int(number(.awake)); other = Int(number(.other))
        sleepMinutes = Int(number(.sleepMinutes)); sleepScore = Int(number(.sleepScore))
        let stamp = (try? c.decodeIfPresent(Int64.self, forKey: .syncedAt)) ?? nil
        syncedAt = (stamp ?? 0) > 0 ? stamp : nil
    }
}

nonisolated struct WireApp: Codable, Equatable, Sendable {
    var platform: String
    var version: String
}

nonisolated struct SyncRequest: Codable, Equatable, Sendable {
    var envelope: Int
    var clientId: String
    var app: WireApp
    var sentAt: Int64
    var blocks: [WireBlock]
    var days: [WireDay]
    enum CodingKeys: String, CodingKey { case envelope, clientId = "client_id", app, sentAt = "sent_at", blocks, days }
}

nonisolated struct BlockResult: Codable, Equatable, Sendable {
    var blockKey: String
    var status: String
    var serverHash: String?
    var serverRevision: Int?
    var reason: String?
    enum CodingKeys: String, CodingKey { case blockKey = "block_key", status, serverHash = "server_hash", serverRevision = "server_revision", reason }
}

nonisolated struct DayResult: Codable, Equatable, Sendable {
    var date: String
    var status: String
    var reason: String?
}

/// The server's answer for one session: `accepted` (stored, changed), `duplicate` (already held — both are
/// acknowledgements), or `rejected` with a reason.
nonisolated struct SessionResult: Codable, Equatable, Sendable {
    var sessionKey: String
    var status: String
    var reason: String?
    enum CodingKeys: String, CodingKey { case sessionKey = "session_key", status, reason }
}

/// The server's answer for one EV40 tracker row (cloud-v2 §2.1): `accepted` (stored), `duplicate` (the mask was
/// already the stored one — both are acknowledgements), or `rejected` with a reason. `updatedAt` is the **server's**
/// stamp of the stored row, which is what the client keeps for the next conflict decision.
nonisolated struct Ev40RowResult: Codable, Equatable, Sendable {
    var date: String
    var status: String
    var reason: String?
    var updatedAt: Int64?
    enum CodingKeys: String, CodingKey { case date, status, reason, updatedAt = "updated_at" }
}

nonisolated struct SyncResponse: Codable, Equatable, Sendable {
    var envelope: Int?
    var cursor: String?
    var blocks: [BlockResult]
    var days: [DayResult]
    /// Absent on a server that predates sessions (and on every request that carries none), so it decodes as empty
    /// rather than failing the whole response.
    var sessions: [SessionResult] = []
    /// The EV40 tracker outcomes; absent on a server that predates the tracker (decoded as empty, like sessions).
    var tracker: [Ev40RowResult] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        envelope = try c.decodeIfPresent(Int.self, forKey: .envelope)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        blocks = try c.decodeIfPresent([BlockResult].self, forKey: .blocks) ?? []
        days = try c.decodeIfPresent([DayResult].self, forKey: .days) ?? []
        sessions = try c.decodeIfPresent([SessionResult].self, forKey: .sessions) ?? []
        tracker = try c.decodeIfPresent([Ev40RowResult].self, forKey: .tracker) ?? []
    }
    init(envelope: Int? = 1, cursor: String?, blocks: [BlockResult], days: [DayResult], sessions: [SessionResult] = [],
         tracker: [Ev40RowResult] = []) {
        self.envelope = envelope; self.cursor = cursor; self.blocks = blocks; self.days = days
        self.sessions = sessions; self.tracker = tracker
    }
}

nonisolated struct ChangesResponse: Codable, Equatable, Sendable {
    var cursor: String
    var more: Bool
    var blocks: [WireBlock]
    var days: [WireDay]
    /// Sessions pulled from another device (empty until the server stores them).
    var sessions: [WireSession] = []
    /// EV40 tracker rows pulled from another device (empty until the server stores them).
    var tracker: [WireEv40Day] = []

    enum CodingKeys: String, CodingKey { case cursor, more, blocks, days, sessions, tracker }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        more = try c.decodeIfPresent(Bool.self, forKey: .more) ?? false
        blocks = try c.decodeIfPresent([WireBlock].self, forKey: .blocks) ?? []
        days = try c.decodeIfPresent([WireDay].self, forKey: .days) ?? []
        sessions = try c.decodeIfPresent([WireSession].self, forKey: .sessions) ?? []
        tracker = try c.decodeIfPresent([WireEv40Day].self, forKey: .tracker) ?? []
    }
    init(cursor: String, more: Bool, blocks: [WireBlock], days: [WireDay], sessions: [WireSession] = [],
         tracker: [WireEv40Day] = []) {
        self.cursor = cursor; self.more = more; self.blocks = blocks; self.days = days
        self.sessions = sessions; self.tracker = tracker
    }
}

/// `GET /api/agara/me`.
nonisolated struct MeInfo: Codable, Equatable, Sendable {
    var id: String?
    var email: String?
    var emailVerified: Bool
    var syncAllowed: Bool
    var graceEndsAt: Date?

    enum CodingKeys: String, CodingKey { case id, email, emailVerified = "email_verified", syncAllowed = "sync_allowed", graceEndsAt = "grace_ends_at" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        emailVerified = (try? c.decodeIfPresent(Bool.self, forKey: .emailVerified)) ?? false
        syncAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .syncAllowed)) ?? emailVerified
        graceEndsAt = (try? c.decodeIfPresent(String.self, forKey: .graceEndsAt)).flatMap { $0 }.flatMap(WireCodec.parseDate)
    }
    init(id: String? = nil, email: String? = nil, emailVerified: Bool, syncAllowed: Bool, graceEndsAt: Date? = nil) {
        self.id = id; self.email = email; self.emailVerified = emailVerified; self.syncAllowed = syncAllowed; self.graceEndsAt = graceEndsAt
    }
}

/// `DELETE /api/agara/me`.
nonisolated struct DeleteMeResult: Equatable, Sendable {
    var deleted: Bool
    var firebaseDeleted: Bool
}

/// The upload JSON, written by hand in a **fixed key order** with the summary printed as exact decimals, so the text is a
/// pure function of (key, revision, sealed, container, tombstones) and both apps reach the same digest for the same
/// input (`wire_golden.txt` in the Android tree pins 19 of them; `AgaraCloudGoldenTests` reads it in place).
/// One recorded workout session (cloud-v2 §2.1, "Workout sessions"). Both apps recorded these locally and uploaded
/// **none** of it, which is why a `source=workout` filter over block metrics could never match; the cloud had no
/// session shape at all.
nonisolated struct WireSession: Codable, Equatable, Sendable {
    var sessionKey: String
    var date: String
    var type: String
    var startedAt: Int64
    var endedAt: Int64?
    var durationMin: Double
    var calories: Double?
    var distanceM: Double?
    var avgHr: Double?
    var minHr: Double?
    var maxHr: Double?
    var avgSpo2: Double?
    var deleted: Bool
    enum CodingKeys: String, CodingKey {
        case sessionKey = "session_key", date, type, startedAt = "started_at", endedAt = "ended_at"
        case durationMin = "duration_min", calories, distanceM = "distance_m"
        case avgHr = "avg_hr", minHr = "min_hr", maxHr = "max_hr", avgSpo2 = "avg_spo2", deleted
    }
}

/// One EV40 tracker row as `GET /changes` returns it (cloud-v2 §2.1/§3.2). `date` is the user's local date, `mask`
/// the eight disciplines as bits (Hydrate 0 … Rest 7), `updatedAt` the **server's** stamp in epoch ms.
nonisolated struct WireEv40Day: Codable, Equatable, Sendable {
    var date: String
    var mask: Int
    var updatedAt: Int64
    enum CodingKeys: String, CodingKey { case date, mask, updatedAt = "updated_at" }

    init(date: String, mask: Int, updatedAt: Int64) {
        self.date = date; self.mask = mask; self.updatedAt = updatedAt
    }

    /// Tolerant: a missing/zero stamp reads as 0, and the mask is clamped to the eight bits the app knows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        mask = (try c.decodeIfPresent(Int.self, forKey: .mask)).map(Ev40Disciplines.normalised) ?? 0
        updatedAt = (try c.decodeIfPresent(Int64.self, forKey: .updatedAt)) ?? 0
    }
}

nonisolated enum WireBlockBuilder {
    /// One block object of the envelope (storage-format §12) from the stored container.
    static func json(blockKey: String, revision: Int, sealed: Bool, decoded: AGBDecoded, tombstones: [Int64], container: Data) -> String? {
        guard let parsed = ParsedBlockKey.parse(blockKey), let hash = decoded.contentHash, decoded.isOK else { return nil }
        var exact: ExactSummary?
        var first: Int64?, last: Int64?
        let n = decoded.timestamps.count
        if n > 0 {
            first = decoded.timestamps.first; last = decoded.timestamps.last
            if decoded.valueMode == 0, let e = decoded.scaleE {
                var lo = decoded.q[0], hi = decoded.q[0], total: Int64 = 0
                for x in decoded.q { if x < lo { lo = x }; if x > hi { hi = x }; total += x }
                exact = ExactSummary(min: scaled(lo, e), max: scaled(hi, e), sum: scaled(total, e))
            } else if let s = decoded.summary, let lo = s.min, let hi = s.max, let sum = s.sum {
                exact = ExactSummary(min: num(lo), max: num(hi), sum: num(sum))
            }
        }
        return assemble(blockKey: blockKey, parsed: parsed, revision: revision, sealed: sealed,
                        fmt: WireFormat(major: decoded.major ?? 1, minor: decoded.minor ?? 0, codec: decoded.codec ?? 0),
                        hash: AGB.hex(hash), n: n, exact: exact, first: first, last: last, tombstones: tombstones,
                        data: container.base64EncodedString())
    }

    /// The same text for a block already in wire form (tests, the fake server's counterpart devices).
    static func json(_ w: WireBlock) -> String {
        let parsed = ParsedBlockKey.parse(w.blockKey) ?? ParsedBlockKey(metric: w.metric, source: w.source, sensorId: w.sensorId, day: Int64(w.utcDay))
        let exact = w.exactSummary ?? {
            guard let lo = w.summary.min, let hi = w.summary.max, let sum = w.summary.sum else { return nil }
            return ExactSummary(min: num(lo), max: num(hi), sum: num(sum))
        }()
        return assemble(blockKey: w.blockKey, parsed: parsed, revision: w.revision, sealed: w.sealed, fmt: w.fmt, hash: w.contentHash,
                        n: w.summary.n, exact: exact, first: w.summary.firstTs, last: w.summary.lastTs,
                        tombstones: w.tombstones ?? [], data: w.data)
    }

    private static func assemble(blockKey: String, parsed: ParsedBlockKey, revision: Int, sealed: Bool, fmt: WireFormat, hash: String, n: Int,
                                 exact: ExactSummary?, first: Int64?, last: Int64?, tombstones: [Int64], data: String) -> String {
        var s = "{\"block_key\":\"\(blockKey)\",\"metric\":\"\(parsed.metric)\",\"source\":\"\(parsed.source)\",\"sensor_id\":\"\(parsed.sensorId)\""
        s += ",\"utc_day\":\(parsed.day),\"revision\":\(revision),\"sealed\":\(sealed)"
        s += ",\"fmt\":{\"major\":\(fmt.major),\"minor\":\(fmt.minor),\"codec\":\(fmt.codec)}"
        s += ",\"content_hash\":\"\(hash)\",\"summary\":{\"n\":\(n)"
        if n > 0, let exact, let first, let last {
            s += ",\"min\":\(exact.min),\"max\":\(exact.max),\"sum\":\(exact.sum),\"first_ts\":\(first),\"last_ts\":\(last)"
        }
        s += "}"
        if !tombstones.isEmpty { s += ",\"tombstones\":[" + tombstones.map(String.init).joined(separator: ",") + "]" }
        s += ",\"data\":\"\(data)\"}"
        return s
    }

    /// `q / 10^e` as an exact plain decimal (`54`, `36.65`, `0.1`, `-1.5`).
    static func scaled(_ q: Int64, _ e: Int) -> String {
        if q == 0 { return "0" }
        var digits = String(q.magnitude)
        if e > 0 {
            if digits.count <= e { digits = String(repeating: "0", count: e - digits.count + 1) + digits }
            let cut = digits.index(digits.endIndex, offsetBy: -e)
            var fraction = String(digits[cut...])
            while fraction.hasSuffix("0") { fraction.removeLast() }
            digits = fraction.isEmpty ? String(digits[..<cut]) : String(digits[..<cut]) + "." + fraction
        }
        return (q < 0 ? "-" : "") + digits
    }

    /// A JSON number without a needless ".0" (integral values print as integers).
    static func num(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return javaStyle(d)
    }

    /// Java's `Double.toString` spelling for non-integral or huge values (`1.0E20`), which is what Android prints.
    private static func javaStyle(_ d: Double) -> String {
        let magnitude = abs(d)
        if magnitude >= 1e-3 && magnitude < 1e7 { return d.description }
        // Scientific: the shortest round-trip digits Swift prints, re-laid as Java does (`1.50000000001455E13`).
        let text = "\(magnitude)"
        var mantissa = text, exp10 = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exp10 = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let whole = parts[0], fraction = parts.count > 1 ? parts[1] : ""
        var digits = Array(whole + fraction)
        var leadingZeros = 0
        while leadingZeros < digits.count - 1, digits[leadingZeros] == "0" { leadingZeros += 1 }
        digits.removeFirst(leadingZeros)
        let exponent = whole.count - 1 - leadingZeros + exp10
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let rest = digits.count > 1 ? String(digits[1...]) : "0"
        return (d < 0 ? "-" : "") + String(digits[0]) + "." + rest + "E" + String(exponent)
    }

    /// One day row, fixed order (sleep fields only when the night exists).
    /// A session object of the envelope. Absent optional values are **omitted**, not encoded as null, so the server
    /// keeps whatever it already holds for them (a later partial write cannot blank a heart rate).
    static func json(_ w: WireSession) -> String {
        var parts = [
            "\"session_key\":\(quote(w.sessionKey))",
            "\"date\":\(quote(w.date))",
            "\"type\":\(quote(w.type))",
            "\"started_at\":\(w.startedAt)",
            "\"duration_min\":\(num(w.durationMin))",
        ]
        if let ended = w.endedAt { parts.append("\"ended_at\":\(ended)") }
        if let v = w.calories { parts.append("\"calories\":\(num(v))") }
        if let v = w.distanceM { parts.append("\"distance_m\":\(num(v))") }
        if let v = w.avgHr { parts.append("\"avg_hr\":\(num(v))") }
        if let v = w.minHr { parts.append("\"min_hr\":\(num(v))") }
        if let v = w.maxHr { parts.append("\"max_hr\":\(num(v))") }
        if let v = w.avgSpo2 { parts.append("\"avg_spo2\":\(num(v))") }
        if w.deleted { parts.append("\"deleted\":true") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func json(_ d: WireDay) -> String {
        var s = "{\"date\":\"\(d.date)\",\"steps\":\(d.steps),\"distance_km\":\(num(d.distanceKm)),\"calories\":\(num(d.calories))"
        if let start = d.sleepStart, let end = d.sleepEnd {
            s += ",\"sleep_start\":\"\(start)\",\"sleep_end\":\"\(end)\",\"deep\":\(d.deep),\"light\":\(d.light),\"awake\":\(d.awake),\"other\":\(d.other),\"sleep_minutes\":\(d.sleepMinutes)"
            if d.sleepScore > 0 { s += ",\"sleep_score\":\(d.sleepScore)" }
        }
        if let stamp = d.syncedAt, stamp > 0 { s += ",\"synced_at\":\(stamp)" }
        return s + "}"
    }

    /// `sync_envelope_version` of the catalog (1).
    static let envelopeVersion = 1

    /// The request body: `envelope, client_id, app{platform,version}, sent_at, blocks, days` in that order.
    /// A JSON string literal, escaped. One implementation, because the envelope and the session objects both quote
    /// user-provided text (`type`, `client_id`) and a second copy would drift.
    static func quote(_ v: String) -> String {
        var out = "\""
        for ch in v.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default: out += ch.value < 0x20 ? String(format: "\\u%04x", ch.value) : String(ch)
            }
        }
        return out + "\""
    }

    static func envelope(clientId: String, platform: String, version: String, sentAt: Int64, blocks: [String], days: [String],
                         sessions: [String] = [], tracker: [String] = []) -> Data {
        var s = "{\"envelope\":\(envelopeVersion),\"client_id\":\(quote(clientId)),\"app\":{\"platform\":\(quote(platform)),\"version\":\(quote(version))},\"sent_at\":\(sentAt),\"blocks\":["
        s += blocks.joined(separator: ",") + "],\"days\":[" + days.joined(separator: ",")
        s += "],\"sessions\":[" + sessions.joined(separator: ",")
        s += "],\"tracker\":[" + tracker.joined(separator: ",") + "]}"
        return Data(s.utf8)
    }

    /// One EV40 tracker row of the envelope: `{"date":"2026-11-04","mask":165}` — fixed key order, and **no
    /// timestamp**, because the server stamps the change with its own clock (cloud-v2 §2.1, plan D3). Takes the two
    /// values rather than the model, so the wire layer never touches SwiftData.
    nonisolated static func json(dateKey: String, mask: Int) -> String {
        "{\"date\":\(quote(dateKey)),\"mask\":\(Ev40Disciplines.normalised(mask))}"
    }
}

nonisolated enum WireCodec {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encode(_ request: SyncRequest) throws -> Data {
        WireBlockBuilder.envelope(clientId: request.clientId, platform: request.app.platform, version: request.app.version, sentAt: request.sentAt,
                                  blocks: request.blocks.map(WireBlockBuilder.json), days: request.days.map(WireBlockBuilder.json))
    }

    static func hex(_ data: Data) -> String { AGB.hex(data) }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// RFC 3339 in UTC, whole seconds (`2026-09-25T22:10:00Z`) — the server's spelling.
    static func rfc3339(_ date: Date) -> String { isoFormatter.string(from: date) }

    static func parseDate(_ text: String) -> Date? { isoFormatter.date(from: text) ?? isoFractional.date(from: text) }
}
