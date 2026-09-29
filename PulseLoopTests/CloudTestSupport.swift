import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// A settable clock for `@Sendable` closures.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Date()) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// A boolean the engine's `sampleDataActive` closure can read from a test.
final class CloudFlag: @unchecked Sendable {
    var on = false
}

/// Collects the ring events a sync would publish.
final class CloudEventRecorder: @unchecked Sendable {
    var events: [RingDecodedEvent] = []
}

/// One "device" of a cloud account in a test: its own in-memory store, defaults, session and engine, talking to a
/// shared `FakeCloudBackend`. Two of these on one backend are two phones of one account.
@MainActor
final class CloudDevice {
    /// 2026-09-29T12:00:00Z — the same pinned clock the storage tests use.
    static let now = Date(timeIntervalSince1970: 1_790_596_800)

    let backend: FakeCloudBackend
    let container: ModelContainer
    let state: AgaraCloudState
    let sessionStore: AgaraMemoryAuthStore
    let auth: AgaraAuthClient
    let api: AgaraCloudAPI
    let engine: AgaraSyncEngine
    let sampleData = CloudFlag()
    let recorder = CloudEventRecorder()
    let email: String
    var context: ModelContext { container.mainContext }
    var store: AgaraSyncStore { engine.syncStore }
    private let suite: String
    static let password = "password1"

    static func make(backend: FakeCloudBackend? = nil,
                     email: String = "user@example.com", createUser: Bool = true, verified: Bool = true, consent: Bool = true,
                     signIn: Bool = true, limits: AgaraSyncLimits? = nil, calendar: Calendar = .current) async throws -> CloudDevice {
        let backend = backend ?? FakeCloudBackend(defaults: UserDefaults(suiteName: "t.\(UUID().uuidString)")!)
        let suite = "agara.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if createUser { backend.createUser(email: email, password: password, verified: verified) }
        let container = try ModelContainerFactory.make(inMemory: true)
        let state = AgaraCloudState(defaults: defaults)
        if consent { state.giveConsent(at: now) }
        let sessionStore = AgaraMemoryAuthStore()
        let auth = AgaraAuthClient(config: backend.config, transport: backend, store: sessionStore, bundleId: "com.agara.ring")
        if signIn { try await auth.signIn(email: email, password: password) }
        let api = AgaraCloudAPI(config: backend.config, transport: backend, auth: auth)
        let flag = CloudFlag(), recorder = CloudEventRecorder()
        let engine = AgaraSyncEngine(api: api, auth: auth, container: container, state: state, limits: limits,
                                     clientId: { "00000000-0000-4000-8000-000000000001" }, appVersion: "1.1.0",
                                     now: { CloudDevice.now }, calendar: calendar,
                                     sampleDataActive: { flag.on }, publish: { recorder.events += $0 })
        let device = CloudDevice(backend: backend, container: container, state: state, sessionStore: sessionStore, auth: auth, api: api,
                                 engine: engine, email: email, suite: suite, flag: flag, recorder: recorder)
        return device
    }

    private init(backend: FakeCloudBackend, container: ModelContainer, state: AgaraCloudState, sessionStore: AgaraMemoryAuthStore,
                 auth: AgaraAuthClient, api: AgaraCloudAPI, engine: AgaraSyncEngine, email: String, suite: String,
                 flag: CloudFlag, recorder: CloudEventRecorder) {
        self.backend = backend; self.container = container; self.state = state; self.sessionStore = sessionStore
        self.auth = auth; self.api = api; self.engine = engine; self.email = email; self.suite = suite
        self.sampleData.on = false
        self.recorderRef = recorder
        self.flagRef = flag
    }
    private let recorderRef: CloudEventRecorder
    private let flagRef: CloudFlag
    var events: [RingDecodedEvent] { recorderRef.events }
    var sampleDataActive: Bool { get { flagRef.on } set { flagRef.on = newValue } }

    var today: Int64 { BlockStore.today(now: CloudDevice.now) }

    // MARK: Data

    /// `count` readings on UTC day `day`, then (when the day is old enough) sealed into a block, or (open days) snapshotted.
    func addSeries(day: Int64, kind: MeasurementKind = .heartRate, source: MeasurementSource = .live, sensor: String = "a3a04cab4846d63c",
                   count: Int = 60, stepMs: Int64 = 60_000, startMs: Int64 = 3_600_000, value: (Int) -> Double = { Double(60 + $0 % 40) }) {
        for i in 0..<count {
            context.insert(PulseLoop.Measurement(kind: kind, value: value(i), unit: kind.unit,
                                       timestamp: BlockStore.date(ms: day * AGB.dayMs + startMs + Int64(i) * stepMs), source: source, sensorId: sensor))
        }
        try? context.save()
    }

    /// Compact every sealable day and snapshot the open ones (what the maintenance job does).
    func compact() throws {
        try context.save()
        _ = StorageMaintenance.compactAll(now: CloudDevice.now, context: context)
        _ = try BlockStore.snapshotOpenDays(now: CloudDevice.now, context: context)
    }

    var ledgers: [BlockSync] { ((try? context.fetch(FetchDescriptor<BlockSync>(sortBy: [SortDescriptor(\.blockKey)]))) ?? []) }
    var blocks: [MeasurementBlock] { ((try? context.fetch(FetchDescriptor<MeasurementBlock>(sortBy: [SortDescriptor(\.blockKey)]))) ?? []) }
    var rows: [PulseLoop.Measurement] { ((try? context.fetch(FetchDescriptor<PulseLoop.Measurement>(sortBy: [SortDescriptor(\.timestamp)]))) ?? []) }
    var unsyncedCount: Int { ledgers.filter { !$0.isSynced }.count }

    /// Points of a stored block.
    func points(_ blockKey: String) -> [AGBPoint] {
        guard let block = blocks.first(where: { $0.blockKey == blockKey }) else { return [] }
        return AGB.decode(block.data).points
    }

    func run() async throws -> CloudSyncSummary { try await engine.run() }
}

extension FakeCloudBackend {
    /// Requests to a path suffix.
    func count(pathSuffix: String) -> Int { requests.filter { $0.url.path.hasSuffix(pathSuffix) }.count }
    func requests(pathSuffix: String) -> [CloudRequest] { requests.filter { $0.url.path.hasSuffix(pathSuffix) } }
}

/// Wire block for a set of points, built independently of the app's storage (what "another device" would upload).
func makeWireBlock(metric: String = "hr", source: String = "live", sensor: String = "a3a04cab4846d63c", day: Int64,
                   points: [AGBPoint], sealed: Bool = true, revision: Int = 1) -> WireBlock {
    let enc = AGB.encodeBlock(points: points, metric: metric, utcDay: day)!
    let decoded = AGB.decode(enc.container)
    let s = decoded.summary!
    return WireBlock(blockKey: AGB.blockKey(metric: metric, source: source, sensorId: sensor, utcDay: day), metric: metric, source: source,
                     sensorId: sensor, utcDay: Int(day), revision: revision, sealed: sealed,
                     fmt: WireFormat(major: decoded.major ?? 1, minor: decoded.minor ?? 0, codec: decoded.codec ?? 0),
                     contentHash: AGB.hex(enc.contentHash),
                     summary: WireSummary(n: s.n, min: s.min, max: s.max, sum: s.sum, firstTs: s.firstTs, lastTs: s.lastTs),
                     tombstones: nil, data: enc.container.base64EncodedString())
}
