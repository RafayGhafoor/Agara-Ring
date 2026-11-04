#if DEBUG
import Foundation

/// An in-process stand-in for **both** Firebase Auth (Identity Toolkit + Secure Token) and the Agara server, behind
/// `CloudTransport`. There is no real Firebase project, so every unit test and the UI test drive the cloud through this.
/// DEBUG builds only (compiled out of Release, like the other test hooks).
///
/// It follows cloud-v2.md closely enough to catch client mistakes: the token's `email_verified` claim is frozen at issue
/// time (so a stale claim gives `403 email_not_verified` until the client force-refreshes), `DELETE /me` needs a recent
/// login, sync validates every block with the real AGB decoder (hash, summary, day), merges with the real §10 rule and
/// answers `accepted` / `duplicate` / `merged` / `rejected`, and `/changes` pages by a per-account sequence.
nonisolated final class FakeCloudBackend: CloudTransport, AgaraCloudBackendInfo, @unchecked Sendable {
    // MARK: Wiring

    let config: AgaraCloudConfig
    let sessionStore: AgaraAuthSessionStore
    let state: AgaraCloudState
    private let limits: AgaraSyncLimits

    @MainActor static func launchInstance() -> FakeCloudBackend {
        let suite = "agara.fakecloud.\(UUID().uuidString)"
        let backend = FakeCloudBackend(defaults: UserDefaults(suiteName: suite)!)
        if DebugLaunch.isSet("fakeCloudVerifyAfter") { backend.autoVerifyAfter = TimeInterval(DebugLaunch.integer("fakeCloudVerifyAfter")) }
        return backend
    }

    private let lock = NSLock()
    /// The clock used for token expiry and `auth_time`.
    var clock: @Sendable () -> Date = { Date() }

    @MainActor init(defaults: UserDefaults? = nil, sessionStore: AgaraAuthSessionStore = AgaraMemoryAuthStore(), limits: AgaraSyncLimits? = nil) {
        self.limits = limits ?? .catalog
        var config = AgaraCloudConfig(firebaseApiKey: "fake-key", firebaseProjectId: "fake-project",
                                      baseURL: URL(string: "https://fake.agara.test")!, syncIntervalMinutes: 60,
                                      retryBackoffSeconds: [30, 120, 600, 1800], verifyPollSeconds: 1)
        config.identityToolkitBase = URL(string: "https://identitytoolkit.googleapis.com")!
        self.config = config
        self.sessionStore = sessionStore
        self.state = AgaraCloudState(defaults: defaults ?? UserDefaults(suiteName: "agara.fakecloud.\(UUID().uuidString)")!)
    }

    // MARK: Fake accounts and tokens

    struct User { var uid: String; var email: String; var password: String; var verified: Bool; var firebaseDeleted = false; var firstSeen = Date() }
    struct Token { var uid: String; var expiresAt: Date; var verifiedClaim: Bool; var authTime: Date }

    private var users: [String: User] = [:]            // by uid
    private var idTokens: [String: Token] = [:]
    private var refreshTokens: [String: (uid: String, authTime: Date)] = [:]
    private var counter = 0
    /// Uids whose server data was erased: their still-valid tokens answer `account_deleted`.
    private var deletedUids: Set<String> = []

    // MARK: Fake server data

    struct StoredBlock { var container: Data; var hash: Data; var wire: WireBlock; var revision: Int; var tombstones: Set<Int64>; var seq: Int }
    private var blocks: [String: [String: StoredBlock]] = [:]   // uid → block_key → block
    private var days: [String: [String: (day: WireDay, seq: Int)]] = [:]
    /// EV40 tracker rows: uid → local date → (the row incl. the **server's** stamp, seq). The stamp comes from this
    /// fake's clock, exactly as the real server stamps a change itself (cloud-v2 §2.1).
    private var tracker: [String: [String: (row: WireEv40Day, seq: Int)]] = [:]
    private var seqs: [String: Int] = [:]

    // MARK: Test controls and observations

    /// UI tests: mark the address verified this many seconds after the verification e-mail was sent (nil = never).
    var autoVerifyAfter: TimeInterval?
    /// Seconds an issued ID token lives.
    var tokenLifetime: TimeInterval = 3600
    /// When true, every network call fails as offline.
    var offline = false
    /// A `403 email_not_verified` for unverified tokens (the grace window is over).
    var enforceVerification = true
    /// Email-enumeration protection: an existing address gets a success-like reply with no tokens instead of EMAIL_EXISTS.
    var maskExistingEmail = false
    /// Seconds an unverified account may still use the cloud after first sight (decision D10 is 72 h; 0 = never).
    var graceSeconds: TimeInterval = 0
    /// `firebase_deleted` in the `DELETE /me` reply (false makes the client call `accounts:delete`).
    var serverDeletesFirebaseUser = true
    var recentLoginWindow: TimeInterval = 300
    /// Failures to serve before behaving normally: matched by substring of the path, consumed in order.
    struct Injected { var pathContains: String; var status: Int; var code: String; var retryAfter: Int? = nil; var remaining = 1; var skip = 0 }
    private var injected: [Injected] = []

    /// Every request, as sent (headers, URL and body), for assertions.
    /// Block keys the server refuses (reason `bad_summary`).
    var rejectBlockKeys: Set<String> = []
    private(set) var requests: [CloudRequest] = []
    /// Artificial delay before every answer (to make concurrent callers overlap).
    var latency: TimeInterval = 0
    private(set) var requestLog: [(method: String, path: String)] = []
    private(set) var syncBodies: [Data] = []
    private(set) var syncRequestCount = 0
    private(set) var refreshCount = 0
    private(set) var emailsSent: [(kind: String, to: String)] = []

    func inject(_ failure: Injected) { lock.lock(); injected.append(failure); lock.unlock() }

    func user(email: String) -> User? { lock.lock(); defer { lock.unlock() }; return users.values.first { $0.email == email } }

    /// The user clicks the e-mailed link.
    func markVerified(email: String) {
        lock.lock(); defer { lock.unlock() }
        if let uid = users.values.first(where: { $0.email == email })?.uid { users[uid]?.verified = true }
    }

    /// Every issued ID token expires now (the server answers `401 token_expired`).
    func expireAllTokens() {
        lock.lock(); defer { lock.unlock() }
        for key in idTokens.keys { idTokens[key]?.expiresAt = clock().addingTimeInterval(-1) }
    }

    /// Mark `authTime` of every token as long ago (so the next `DELETE /me` needs a fresh login).
    func ageLogins(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        for (key, token) in idTokens { idTokens[key]?.authTime = token.authTime.addingTimeInterval(-seconds) }
    }

    func serverBlocks(email: String) -> [String: StoredBlock] {
        lock.lock(); defer { lock.unlock() }
        guard let uid = users.values.first(where: { $0.email == email })?.uid else { return [:] }
        return blocks[uid] ?? [:]
    }

    func serverDays(email: String) -> [String: WireDay] {
        lock.lock(); defer { lock.unlock() }
        guard let uid = users.values.first(where: { $0.email == email })?.uid else { return [:] }
        return (days[uid] ?? [:]).mapValues(\.day)
    }

    func serverTracker(email: String) -> [String: WireEv40Day] {
        lock.lock(); defer { lock.unlock() }
        guard let uid = users.values.first(where: { $0.email == email })?.uid else { return [:] }
        return (tracker[uid] ?? [:]).mapValues(\.row)
    }

    /// Seed the server with an EV40 day another device uploaded (for pull tests).
    func seedTracker(email: String, date: String, mask: Int, updatedAt: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let uid = users.values.first(where: { $0.email == email })?.uid else { return }
        tracker[uid, default: [:]][date] = (WireEv40Day(date: date, mask: mask, updatedAt: updatedAt), nextSeq(uid))
    }

    /// Seed the server with a block another device uploaded (for pull tests).
    func seed(email: String, block wire: WireBlock, tombstones: Set<Int64> = []) {
        lock.lock(); defer { lock.unlock() }
        guard let uid = users.values.first(where: { $0.email == email })?.uid, let container = Data(base64Encoded: wire.data) else { return }
        let seq = nextSeq(uid)
        blocks[uid, default: [:]][wire.blockKey] = StoredBlock(container: container, hash: AGB.sha256(Data(AGB.decode(container).payload ?? [])),
                                                              wire: wire, revision: 1, tombstones: tombstones, seq: seq)
    }

    func createUser(email: String, password: String, verified: Bool) {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let uid = "uid\(counter)"
        users[uid] = User(uid: uid, email: email, password: password, verified: verified)
    }

    // MARK: CloudTransport

    func send(_ request: CloudRequest) async throws -> CloudResponse {
        let delay = lock.withLock { latency }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try lock.withLock { try handle(request) }
    }

    private func handle(_ request: CloudRequest) throws -> CloudResponse {
        if offline { throw CloudTransportError.offline }
        let path = request.url.path
        requestLog.append((request.method, path))
        requests.append(request)
        if let index = injected.firstIndex(where: { path.contains($0.pathContains) && $0.remaining > 0 }) {
            if injected[index].skip > 0 {
                injected[index].skip -= 1   // let this many matching requests through first
            } else {
                injected[index].remaining -= 1
                let failure = injected[index]
                return serverError(failure.status, failure.code, retryAfter: failure.retryAfter)
            }
        }
        let host = request.url.host ?? ""
        if host.contains("securetoken") { return secureToken(request) }
        if host.contains("identitytoolkit") { return identityToolkit(request) }
        return agaraServer(request)
    }

    // MARK: Firebase

    private func firebaseError(_ message: String, status: Int = 400) -> CloudResponse {
        json(status, ["error": ["code": status, "message": message]])
    }

    private func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> CloudResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return CloudResponse(status: status, headers: headers, body: data)
    }

    private func issue(_ user: User, authTime: Date) -> [String: Any] {
        counter += 1
        let id = "idtoken.\(user.uid).\(counter)"
        let refresh = "refresh.\(user.uid).\(counter)"
        idTokens[id] = Token(uid: user.uid, expiresAt: clock().addingTimeInterval(tokenLifetime), verifiedClaim: user.verified, authTime: authTime)
        refreshTokens[refresh] = (user.uid, authTime)
        return ["idToken": id, "refreshToken": refresh, "expiresIn": String(Int(tokenLifetime)), "localId": user.uid, "email": user.email]
    }

    private func identityToolkit(_ request: CloudRequest) -> CloudResponse {
        let method = request.url.lastPathComponent
        let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        switch method {
        case "accounts:signUp":
            let email = (body["email"] as? String) ?? "", password = (body["password"] as? String) ?? ""
            if !email.contains("@") { return firebaseError("INVALID_EMAIL") }
            if !(8...128).contains(password.count) { return firebaseError("PASSWORD_DOES_NOT_MEET_REQUIREMENTS : Missing password requirements: [Password must contain at least 8 characters]") }
            if users.values.contains(where: { $0.email == email }) { return maskExistingEmail ? json(200, [:]) : firebaseError("EMAIL_EXISTS") }
            counter += 1
            let user = User(uid: "uid\(counter)", email: email, password: password, verified: false)
            users[user.uid] = user
            return json(200, issue(user, authTime: clock()))
        case "accounts:signInWithPassword":
            let email = (body["email"] as? String) ?? "", password = (body["password"] as? String) ?? ""
            guard let user = users.values.first(where: { $0.email == email && !$0.firebaseDeleted }), user.password == password
            else { return firebaseError("INVALID_LOGIN_CREDENTIALS") }
            return json(200, issue(user, authTime: clock()))
        case "accounts:sendOobCode":
            let kind = (body["requestType"] as? String) ?? ""
            if kind == "VERIFY_EMAIL" {
                guard let token = idTokens[(body["idToken"] as? String) ?? ""], let user = users[token.uid] else { return firebaseError("INVALID_ID_TOKEN") }
                emailsSent.append(("VERIFY_EMAIL", user.email))
                if let delay = autoVerifyAfter {   // the "link click" for UI tests: verified `delay` seconds after the mail
                    let address = user.email
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.markVerified(email: address) }
                }
            } else {
                emailsSent.append((kind, (body["email"] as? String) ?? ""))
            }
            return json(200, ["email": (body["email"] as? String) ?? ""])
        case "accounts:lookup":
            guard let token = idTokens[(body["idToken"] as? String) ?? ""], let user = users[token.uid], !user.firebaseDeleted
            else { return firebaseError("USER_NOT_FOUND") }
            return json(200, ["users": [["localId": user.uid, "email": user.email, "emailVerified": user.verified]]])
        case "accounts:delete":
            guard let token = idTokens[(body["idToken"] as? String) ?? ""], users[token.uid] != nil else { return firebaseError("INVALID_ID_TOKEN") }
            users[token.uid]?.firebaseDeleted = true
            return json(200, [:])
        default:
            return firebaseError("OPERATION_NOT_ALLOWED")
        }
    }

    private func secureToken(_ request: CloudRequest) -> CloudResponse {
        refreshCount += 1
        let form = String(decoding: request.body ?? Data(), as: UTF8.self)
        let pairs = form.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        let refresh = pairs.first { $0.first == "refresh_token" }?.dropFirst().first?.removingPercentEncoding ?? ""
        guard let entry = refreshTokens[refresh], let user = users[entry.uid], !user.firebaseDeleted else { return firebaseError("INVALID_REFRESH_TOKEN") }
        let issued = issue(user, authTime: entry.authTime)
        return json(200, ["id_token": issued["idToken"]!, "refresh_token": issued["refreshToken"]!,
                          "expires_in": issued["expiresIn"]!, "user_id": user.uid])
    }

    // MARK: Agara server

    private func serverError(_ status: Int, _ code: String, retryAfter: Int? = nil) -> CloudResponse {
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = String(retryAfter) }
        return json(status, ["status": status, "code": code, "message": code], headers: headers)
    }

    private func nextSeq(_ uid: String) -> Int { seqs[uid, default: 0] += 1; return seqs[uid]! }

    private func agaraServer(_ request: CloudRequest) -> CloudResponse {
        guard let bearer = request.headers["Authorization"], bearer.hasPrefix("Bearer "),
              let token = idTokens[String(bearer.dropFirst(7))] else { return serverError(401, "invalid_token") }
        if token.expiresAt <= clock() { return serverError(401, "token_expired") }
        let uid = token.uid
        if deletedUids.contains(uid) { return serverError(401, "account_deleted") }
        guard let user = users[uid] else { return serverError(401, "invalid_token") }
        let path = request.url.path
        if path.hasSuffix("/me"), request.method == "GET" {
            let graceEnd = user.firstSeen.addingTimeInterval(graceSeconds)
            let inGrace = graceSeconds > 0 && clock() < graceEnd
            var reply: [String: Any] = ["id": uid, "email": user.email, "email_verified": token.verifiedClaim,
                                        "sync_allowed": token.verifiedClaim || !enforceVerification || inGrace, "firebase": true,
                                        "server_time": WireCodec.rfc3339(clock())]
            if !token.verifiedClaim, graceSeconds > 0 { reply["grace_ends_at"] = WireCodec.rfc3339(graceEnd) }
            return json(200, reply)
        }
        if path.hasSuffix("/me"), request.method == "DELETE" {
            if clock().timeIntervalSince(token.authTime) > recentLoginWindow { return serverError(401, "recent_login_required") }
            blocks[uid] = nil; days[uid] = nil; tracker[uid] = nil; seqs[uid] = nil
            deletedUids.insert(uid)
            if serverDeletesFirebaseUser { users[uid]?.firebaseDeleted = true }
            return json(200, ["deleted": true, "firebase_deleted": serverDeletesFirebaseUser])
        }
        let inGrace = graceSeconds > 0 && clock() < user.firstSeen.addingTimeInterval(graceSeconds)
        if !token.verifiedClaim, enforceVerification, !inGrace { return serverError(403, "email_not_verified") }
        if path.hasSuffix("/sync"), request.method == "POST" { return sync(uid, request) }
        if path.hasSuffix("/changes"), request.method == "GET" { return changes(uid, request) }
        return serverError(404, "not_found")
    }

    private func sync(_ uid: String, _ request: CloudRequest) -> CloudResponse {
        syncRequestCount += 1
        syncBodies.append(request.body ?? Data())
        guard let body = request.body, let envelope = try? JSONDecoder().decode(SyncRequest.self, from: body) else { return serverError(400, "bad_request") }
        if envelope.envelope != 1 { return serverError(400, "unsupported_envelope") }
        if envelope.blocks.count > limits.maxBlocks { return serverError(413, "too_many_blocks") }
        if envelope.days.count > limits.maxDayRows { return serverError(413, "too_many_days") }
        if body.count > limits.maxBodyBytes { return serverError(413, "body_too_large") }

        var results: [BlockResult] = []
        for wire in envelope.blocks { results.append(store(uid, wire)) }
        var dayResults: [DayResult] = []
        for day in envelope.days {
            guard AgaraCloudDays.parseDay(day.date, calendar: Calendar(identifier: .gregorian)) != nil else {
                dayResults.append(DayResult(date: day.date, status: "rejected", reason: "bad_date")); continue
            }
            let existing = days[uid]?[day.date]?.day
            let merged = Self.mergeDay(existing, day)
            if merged != existing { days[uid, default: [:]][day.date] = (merged, nextSeq(uid)) }
            dayResults.append(DayResult(date: day.date, status: "ok"))
        }
        // EV40 tracker rows: decoded separately because `SyncRequest` carries only blocks and days.
        struct TrackerEnvelope: Decodable {
            struct Row: Decodable { var date: String; var mask: Int }
            var tracker: [Row]?
        }
        let incoming = (try? JSONDecoder().decode(TrackerEnvelope.self, from: body))?.tracker ?? []
        if incoming.count > AgaraCloudTracker.maxRowsPerRequest { return serverError(413, "too_many_tracker") }
        var trackerResults: [Ev40RowResult] = []
        for row in incoming {
            guard AgaraCloudDays.parseDay(row.date, calendar: Calendar(identifier: .gregorian)) != nil else {
                trackerResults.append(Ev40RowResult(date: row.date, status: "rejected", reason: "bad_date")); continue
            }
            guard (0...255).contains(row.mask) else {
                trackerResults.append(Ev40RowResult(date: row.date, status: "rejected", reason: "bad_mask")); continue
            }
            let stamp = Int64(clock().timeIntervalSince1970 * 1000)
            if let existing = tracker[uid]?[row.date], existing.row.mask == row.mask {
                trackerResults.append(Ev40RowResult(date: row.date, status: "duplicate", updatedAt: existing.row.updatedAt))
                continue
            }
            tracker[uid, default: [:]][row.date] = (WireEv40Day(date: row.date, mask: row.mask, updatedAt: stamp), nextSeq(uid))
            trackerResults.append(Ev40RowResult(date: row.date, status: "accepted", updatedAt: stamp))
        }
        let response = SyncResponse(cursor: "c1.\(seqs[uid] ?? 0)", blocks: results, days: dayResults, tracker: trackerResults)
        return CloudResponse(status: 200, body: (try? JSONEncoder().encode(response)) ?? Data())
    }

    /// Day rows: steps / distance / calories take the maximum, the sleep summary comes as a unit from the longer night.
    static func mergeDay(_ a: WireDay?, _ b: WireDay) -> WireDay {
        guard var out = a else { return b }
        out.steps = max(out.steps, b.steps); out.distanceKm = max(out.distanceKm, b.distanceKm); out.calories = max(out.calories, b.calories)
        if b.sleepMinutes > out.sleepMinutes {
            out.sleepStart = b.sleepStart; out.sleepEnd = b.sleepEnd; out.deep = b.deep; out.light = b.light
            out.awake = b.awake; out.other = b.other; out.sleepMinutes = b.sleepMinutes; out.sleepScore = b.sleepScore
        }
        return out
    }

    private func store(_ uid: String, _ wire: WireBlock) -> BlockResult {
        func reject(_ reason: String) -> BlockResult { BlockResult(blockKey: wire.blockKey, status: "rejected", serverHash: nil, serverRevision: nil, reason: reason) }
        if rejectBlockKeys.contains(wire.blockKey) { return reject("bad_summary") }
        guard let key = ParsedBlockKey.parse(wire.blockKey), key.metric == wire.metric, key.source == wire.source,
              key.sensorId == wire.sensorId, key.day == Int64(wire.utcDay), AGB.sources.contains(key.source) else { return reject("bad_key") }
        guard AGB.scales[key.metric] != nil else { return reject("unknown_metric") }
        guard let container = Data(base64Encoded: wire.data) else { return reject("bad_block") }
        let decoded = AGB.decode(container)
        guard decoded.isOK, let payloadHash = decoded.contentHash else { return reject("bad_block") }
        guard AGB.hex(payloadHash) == wire.contentHash else { return reject("bad_hash") }
        guard decoded.timestamps.allSatisfy({ BlockStore.utcDay(ms: $0) == key.day }), (wire.tombstones ?? []).allSatisfy({ BlockStore.utcDay(ms: $0) == key.day })
        else { return reject("outside_day") }
        guard let summary = decoded.summary, summary.n == wire.summary.n, summary.firstTs == wire.summary.firstTs, summary.lastTs == wire.summary.lastTs
        else { return reject("bad_summary") }

        let incomingTombs = Set(wire.tombstones ?? [])
        guard let existing = blocks[uid]?[wire.blockKey] else {
            let seq = nextSeq(uid)
            blocks[uid, default: [:]][wire.blockKey] = StoredBlock(container: container, hash: payloadHash, wire: wire, revision: 1, tombstones: incomingTombs, seq: seq)
            return BlockResult(blockKey: wire.blockKey, status: "accepted", serverHash: wire.contentHash, serverRevision: 1, reason: nil)
        }
        if existing.hash == payloadHash, incomingTombs.isSubset(of: existing.tombstones) {
            return BlockResult(blockKey: wire.blockKey, status: "duplicate", serverHash: wire.contentHash, serverRevision: existing.revision, reason: nil)
        }
        let tombs = existing.tombstones.union(incomingTombs)
        guard let merged = try? AGB.merge(existing.container, container, metric: key.metric, utcDay: key.day, tombstones: tombs) else { return reject("bad_block") }
        if merged.contentHash == existing.hash, incomingTombs.isSubset(of: existing.tombstones) {
            return BlockResult(blockKey: wire.blockKey, status: "duplicate", serverHash: AGB.hex(existing.hash), serverRevision: existing.revision, reason: nil)
        }
        let seq = nextSeq(uid)
        let keepIncoming = merged.contentHash == payloadHash
        var stored = existing
        stored.container = keepIncoming ? container : merged.container
        stored.hash = merged.contentHash
        stored.tombstones = tombs
        stored.revision += 1
        stored.seq = seq
        var newWire = wire
        newWire.contentHash = AGB.hex(merged.contentHash)
        newWire.data = stored.container.base64EncodedString()
        newWire.sealed = wire.sealed || existing.wire.sealed
        if let s = AGB.decode(stored.container).summary {
            newWire.summary = WireSummary(n: s.n, min: s.min, max: s.max, sum: s.sum, firstTs: s.firstTs, lastTs: s.lastTs)
        }
        newWire.tombstones = tombs.isEmpty ? nil : tombs.sorted()
        stored.wire = newWire
        blocks[uid]![wire.blockKey] = stored
        return BlockResult(blockKey: wire.blockKey, status: keepIncoming ? "accepted" : "merged", serverHash: AGB.hex(merged.contentHash),
                           serverRevision: stored.revision, reason: nil)
    }

    private func changes(_ uid: String, _ request: CloudRequest) -> CloudResponse {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let since = items.first { $0.name == "since" }?.value ?? ""
        let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? 200
        var after = 0
        if !since.isEmpty {
            guard since.hasPrefix("c1."), let n = Int(since.dropFirst(3)) else { return serverError(400, "bad_cursor") }
            after = n
        }
        var entries: [(seq: Int, block: WireBlock?, day: WireDay?, tracker: WireEv40Day?)] = []
        for stored in (blocks[uid] ?? [:]).values where stored.seq > after { entries.append((stored.seq, stored.wire, nil, nil)) }
        for (_, value) in days[uid] ?? [:] where value.seq > after { entries.append((value.seq, nil, value.day, nil)) }
        for (_, value) in tracker[uid] ?? [:] where value.seq > after { entries.append((value.seq, nil, nil, value.row)) }
        entries.sort { $0.seq < $1.seq }
        let page = Array(entries.prefix(limit))
        let cursor = page.last.map { "c1.\($0.seq)" } ?? since
        let response = ChangesResponse(cursor: cursor, more: entries.count > page.count, blocks: page.compactMap(\.block),
                                       days: page.compactMap(\.day), tracker: page.compactMap(\.tracker))
        return CloudResponse(status: 200, body: (try? JSONEncoder().encode(response)) ?? Data())
    }
}
#endif
