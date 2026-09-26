import Foundation
import SwiftData

enum AgaraEvent: Sendable {
    case deviceStateChanged(state: RingConnectionState, address: String?)
    /// Emitted on connect once the active wearable's type + capabilities are known, so persistence
    /// can stamp the `Device` and the UI can capability-gate its surfaces.
    case deviceIdentified(
        deviceType: RingDeviceType,
        wearableModelID: String?,
        advertisedName: String?,
        capabilities: Set<WearableCapability>,
        /// The connected ring's CoreBluetooth peripheral UUID — the stable per-ring identity on iOS (the
        /// MAC is hidden). Keys the per-ring nickname memory (`RingNicknameMemory`). Nil when there is no
        /// peripheral (the emulator's virtual transport); the row's identity is then left alone.
        peripheralIdentifier: String? = nil
    )
    case deviceForgotten
    case batteryLevel(percent: Int)
    case decodedPacket(RingDecodedEvent)
    case rawPacket(direction: PacketDirection, data: Data, decoded: RingDecodedEvent)
    case derivedUpdate(kind: String, entityType: String, entityId: String, payloadJSON: String?)
    case activityUpdate(timestamp: Date, steps: Int, distanceMeters: Double, calories: Double)
    /// One intraday activity bucket (summed into its day, not ratcheted). Calories omitted.
    case activityBucket(timestamp: Date, steps: Int, distanceMeters: Double)
    /// Emitted when a fresh ring history sync begins, so persistence zeroes the days about to be
    /// re-summed from buckets — keeps re-syncs idempotent (cleared data can't come back inflated).
    case activitySyncReset(sinceDaysAgo: Int)
    case heartRateSample(bpm: Int, timestamp: Date)
    case heartRateComplete(timestamp: Date)
    case spo2Progress(percent: Int?, timestamp: Date)
    case spo2Result(value: Int, timestamp: Date)
    case spo2Complete(timestamp: Date)
    /// One sleep record and the source that delivered it (see `RingDecodedEvent.sleepTimeline`).
    case sleepTimeline(timestamp: Date, stages: [SleepStage], source: String? = nil)
    case historyMeasurement(kind: MeasurementKind, value: Double, timestamp: Date)
    case stressSample(value: Int, timestamp: Date)
    case hrvSample(value: Int, timestamp: Date)
    case temperatureSample(celsius: Double, timestamp: Date)
    case bloodPressureSample(systolic: Int, diastolic: Int, timestamp: Date)
    case fatigueSample(value: Int, timestamp: Date)
    case bloodSugarSample(mgdl: Double, timestamp: Date)
    /// Firmware version string parsed from the ring's status/firmware payload; persisted on the Device.
    /// The ring reported whether it is on the finger.
    /// `RingSyncCoordinator` uses `worn == false` to fast-fail an in-flight spot measure: an optical
    /// sensor with no skin contact cannot read, so idling out the full window only wastes the user's
    /// time. Not persisted — it is a live condition, not data.
    case wearState(worn: Bool)
    case firmwareVersion(String)
    /// The ring's device number and test version from the `a1` reply — the firmware-update lookup key
    /// (`FirmwareUpdateChecker`). Persisted on the Device row next to `firmwareVersion`.
    case firmwareIdentity(deviceNumber: Int, version: String, testVersion: String)
    /// The ring is (not) on its charger. A live condition — not persisted (`RingBLEClient.isCharging`).
    case chargingState(Bool)
    /// The ring's decoded capability packets; persisted on the Device row.
    case ringCapabilities(RingCapabilities)
    /// The ring's automatic-measurement schedule; persisted on the Device row.
    case autoMeasureSchedule([AutoMeasureEntry])
    /// A finished on-demand blood-components test: five spot readings.
    case bloodComponentsSample(BloodComponentsReading, timestamp: Date)
    /// Friendly history-sync progress for the product UI (e.g. "Syncing sleep…"). Never protocol terms.
    case syncProgress(stage: String)
    case workoutStarted(UUID)
    case workoutPaused(UUID)
    case workoutResumed(UUID)
    case workoutFinished(UUID)
    case gpsPoint(
        sessionId: UUID,
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        horizontalAccuracy: Double?,
        speed: Double?,
        course: Double?,
        accepted: Bool,
        rejectionReason: String?,
        timestamp: Date
    )
    case coachTrace(String)
}

actor AgaraEventBus {
    static let shared = AgaraEventBus()
    
    private var continuations: [UUID: AsyncStream<AgaraEvent>.Continuation] = [:]
    
    func publish(_ event: AgaraEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
    
    func stream() -> AsyncStream<AgaraEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.remove(id) }
            }
        }
    }
    
    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

@MainActor
final class EventPersistenceSubscriber {
    private let context: ModelContext
    private var task: Task<Void, Never>?

    /// Rolling cap for the raw-packet trace, and how often we prune (every Nth insert, so we don't
    /// pay a fetch on every packet during a sync burst). DEBUG builds always capture; release
    /// builds only when the user opts in (see `RawPacketCapture`).
    private let rawPacketCap = 2_000
    private let rawPacketPruneInterval = 200
    private var rawPacketInsertsSincePrune = 0

    /// Coalesced-save state. During a sync the ring streams hundreds of events; saving per event
    /// woke every `@Query` hundreds of times (the re-render storm). Instead we insert/mutate without
    /// saving, then flush (one `save()` + one "data changed" signal) after the stream briefly idles
    /// or a hard cap of pending writes is reached.
    private var pendingWrites = 0
    private var flushTask: Task<Void, Never>?
    /// Idle window after the last event before we flush a batch.
    private let flushDebounceNanos: UInt64 = 300_000_000   // 0.3s
    /// Hard ceiling so a long continuous stream still flushes periodically (never unbounded latency).
    private let flushMaxPending = 100

    /// Identity of a history sample within one sync run — see `isDuplicateHistory`.
    private struct HistoryKey: Hashable {
        let kind: String
        let epoch: Int
    }
    /// History samples already seen this sync. Cleared when a sync completes, so it can't grow
    /// unbounded across a long-lived session.
    private var seenHistoryKeys: Set<HistoryKey> = []

    /// Battery-history throttle. Battery events arrive on connect and roughly hourly from the watchdog,
    /// sometimes repeating the same percent; we only persist a `BatterySample` when the value changes or
    /// a 30-min floor has elapsed, keeping the history table tiny. State is in-memory, so the first
    /// reading after a (re)launch always records — which is what we want for a per-session data point.
    private var lastBatteryPercent: Int?
    private var lastBatteryLogAt: Date?
    private let batteryMinInterval: TimeInterval = 30 * 60   // 30 min

    /// True while every live HR sample must be kept: a workout (its stream is the recorded data) or a
    /// spot HR measurement (its samples are the reading). Set by the app to the coordinator's state.
    var keepEveryHeartRateSample: @MainActor () -> Bool = { false }
    /// When the last throttled live HR row was stored — see `LiveHeartRateThrottle`.
    private var lastLiveHRStoredAt: Date?

    init(context: ModelContext) {
        self.context = context
    }

    // Explicit deinit: cancels the outstanding event/flush tasks and (crucially) gives this
    // @MainActor class a non-isolated deinit. Without one, the compiler synthesizes a main-actor
    // -isolated deinit that hops through `swift_task_deinitOnExecutorMainActorBackDeploy` on dealloc;
    // that back-deploy shim double-frees on iOS < 26.5 (the CI runner's runtime), aborting the test
    // process with SIGABRT when a unit test creates and drops a subscriber. See the CI notes in ci.yml.
    deinit {
        task?.cancel()
        flushTask?.cancel()
    }

    func start() {
        guard task == nil else { return }
        // Keep the audit tables a rolling week (they grew without bound).
        DebugRepository.pruneAuditTables(context: context)
        task = Task {
            let stream = await AgaraEventBus.shared.stream()
            for await event in stream {
                await MainActor.run {
                    self.persist(event)
                }
            }
        }
    }

    func stop() {
        flushTask?.cancel()
        flushNow()
        task?.cancel()
        task = nil
    }

    /// Persist any pending batched writes immediately. Call on app background/suspend so a sync that
    /// is mid-batch isn't lost.
    func flush() {
        // A suspended mid-sync burst may never see `.syncProgress("done")` — settle any pending
        // calorie-estimate recomputes before the save (no-op when nothing is dirty).
        DailyCalorieEstimator.flushDirty(context: context)
        flushNow()
    }

    func persist(_ event: AgaraEvent) {
        noopWrite = false
        applyPersist(event)
        // Nothing written (an unchanged poll value, a throttled sample, a non-data event): no save and no
        // data-change signal — the 30 s poll used to wake the widget, Health export and every store.
        guard !noopWrite else { return }
        scheduleFlush()
    }

    /// Set by `applyPersist` when the event changed nothing in the store (Android's `noopWrite`).
    private var noopWrite = false

    /// Debounced batch flush: reset the idle timer each event; flush immediately if too many writes
    /// have piled up. Coalesces a sync burst into a handful of saves + change signals.
    private func scheduleFlush() {
        pendingWrites += 1
        if pendingWrites >= flushMaxPending {
            flushNow()
            return
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            let nanos = self?.flushDebounceNanos ?? 300_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.flushNow()
        }
    }

    /// Persist the accumulated batch and notify observers exactly once.
    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard pendingWrites > 0 else { return }
        pendingWrites = 0
        try? context.save()
        // One coalesced signal per batch; stores recompute once instead of per event.
        AgaraDataChange.shared.notify()
    }

    // This is an exhaustive event router; each enum case is independent rather than branching logic.
    // swiftlint:disable:next cyclomatic_complexity
    private func applyPersist(_ event: AgaraEvent) {
        switch event {
        case let .deviceStateChanged(state, address):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.state = state
            device.bleAddressHint = address ?? device.bleAddressHint
            if state == .connected {
                device.lastConnectedAt = Date()
                device.lastSyncAt = Date()
            }
            context.insert(device)
        case let .deviceIdentified(deviceType, wearableModelID, advertisedName, capabilities, peripheralIdentifier):
            let device = MetricsService.fetchDevices(context).first ?? Device()
            device.deviceType = deviceType
            device.wearableModelID = wearableModelID
            if let advertisedName {
                device.advertisedName = advertisedName
            }
            device.capabilities = capabilities
            // The single row is reused by whichever ring connects, so its nickname follows the ring's
            // identity: ring B connecting after ring A shows B's own name (or none), not A's.
            if let peripheralIdentifier {
                RingNicknameMemory().adopt(identifier: peripheralIdentifier, on: device)
            }
            adoptDeviceName(advertised: advertisedName, deviceType: deviceType, on: device)
            context.insert(device)
        case .deviceForgotten:
            guard let device = MetricsService.fetchDevices(context).first else { break }
            device.wearableModelID = nil
            device.advertisedName = nil
            // The name goes with them. This single row is *reused* by the next ring paired
            // (`fetchDevices(context).first ?? Device()`), so a name adopted from the ring being
            // forgotten would otherwise outlive it — and, being neither empty nor a placeholder,
            // `adoptDeviceName` would read it as a name the user chose and defend it against the new
            // ring's own advertisement forever. Forget one ring, pair the next, and the coach's
            // `device_name` and the diagnostics export's `wearableName` would both still name the old
            // one: worse than the old placeholder, because it reads as authoritative.
            device.name = ""
            // The user's name for the ring goes with it too: the next ring paired starts as "Agara Ring",
            // and this ring's entry leaves the per-ring memory so re-pairing it later starts unnamed.
            device.nickname = nil
            if let identifier = device.peripheralIdentifier {
                RingNicknameMemory().remove(identifier: identifier)
            }
            device.peripheralIdentifier = nil
            context.insert(device)
        case let .batteryLevel(percent):
            let existing = MetricsService.fetchDevices(context).first
            let device = existing ?? Device()
            let sampled = recordBatterySample(percent)
            if existing != nil, device.batteryPercent == percent {
                if !sampled { noopWrite = true }
                break
            }
            device.batteryPercent = percent
            context.insert(device)
        case let .rawPacket(direction, data, decoded):
            // The raw byte trace is a developer diagnostic. DEBUG builds always keep it; release
            // builds keep it only while the user has explicitly enabled capture in Privacy & Data —
            // the toggle exists so a remote tester on TestFlight can hand back protocol bytes from a
            // ring family we've never had in hand (raw packets encode health data, hence opt-in,
            // off by default and clearable).
            guard RawPacketCapture.isEnabled else { noopWrite = true; return }
            context.insert(
                RawPacketRow(
                    direction: direction,
                    commandId: Int(data.first ?? 0),
                    hexPayload: data.hexString,
                    decodedKind: decoded.kind,
                    decodedJSON: decoded.debugJSON,
                    confidence: decoded.confidence
                )
            )
            // Keep the trace a rolling window so it can't grow without bound. Prune only every Nth
            // insert to avoid a fetch on every packet during a sync burst.
            rawPacketInsertsSincePrune += 1
            if rawPacketInsertsSincePrune >= rawPacketPruneInterval {
                rawPacketInsertsSincePrune = 0
                DebugRepository.pruneRawPackets(maxRows: rawPacketCap, context: context)
            }
        case let .derivedUpdate(kind, entityType, entityId, payloadJSON):
            context.insert(DerivedUpdateRow(kind: kind, entityType: entityType, entityId: entityId, payloadJSON: payloadJSON))
        case let .activityUpdate(timestamp, steps, distanceMeters, calories):
            // Single ratchet source of truth (monotonic max within a day), tagged as live.
            let (_, changed) = ActivityService.applyActivityUpdateIfChanged(
                ActivityDailyUpdate(
                    date: timestamp,
                    steps: steps,
                    calories: calories,
                    distanceMeters: distanceMeters,
                    source: "live",
                    syncedAt: Date()
                ),
                context: context
            )
            // Unchanged totals (the 30 s poll while still): nothing to write, no signal. The per-update
            // audit row (`DerivedUpdateRow`) is no longer written — nothing reads it back per update, and it
            // was the table's main source of growth.
            guard changed else { noopWrite = true; break }
            // Devices that report no calorie counter (send 0): keep today's on-device estimate
            // tracking the live step ratchet. Throttled — cumulative packets can stream every second.
            if calories <= 0 {
                DailyCalorieEstimator.recomputeThrottled(day: timestamp, context: context)
            }
        case let .activityBucket(timestamp, steps, distanceMeters):
            // Per-quarter-hour ring history: upserted by timestamp + the day total recomputed as the
            // sum of distinct buckets, so re-syncs are idempotent (no drift). Calories omitted.
            ActivityService.applyActivityBucket(date: timestamp, steps: steps, distanceMeters: distanceMeters, context: context)
        case .activitySyncReset:
            // No longer needed — bucket upsert-by-timestamp makes re-syncs idempotent on its own.
            // Kept as a no-op so the (still-published) event doesn't fall through to `unknown`.
            break
        case let .heartRateSample(bpm, timestamp):
            // The live stream arrives about once a second; outside a workout / spot test one row per 5 s
            // is kept (Android `LiveHeartRateThrottle`, plan release-hardening-storage B3). The screens
            // read the live value from the coordinator, not from the store.
            guard LiveHeartRateThrottle.shouldStore(
                lastStoredAt: lastLiveHRStoredAt, at: timestamp, keepAll: keepEveryHeartRateSample()
            ) else { noopWrite = true; return }
            lastLiveHRStoredAt = timestamp
            persistMeasurement(kind: .heartRate, value: Double(bpm), timestamp: timestamp, source: .live, kindLabel: "hr_sample")
        case let .spo2Result(value, timestamp):
            persistMeasurement(kind: .spo2, value: Double(value), timestamp: timestamp, source: .live, kindLabel: "spo2_result")
        case let .historyMeasurement(kind, value, timestamp):
            persistMeasurement(kind: kind, value: value, timestamp: timestamp, source: .history, kindLabel: "history_measurement")
        case let .stressSample(value, timestamp):
            // The on-demand stress test (`89 06`) is a spot reading, stored like the other spot legs.
            persistMeasurement(kind: .stress, value: Double(value), timestamp: timestamp, source: .live, kindLabel: "stress_sample")
        case let .hrvSample(value, timestamp):
            persistMeasurement(kind: .hrv, value: Double(value), timestamp: timestamp, source: .ring, kindLabel: "hrv_sample")
        case let .temperatureSample(celsius, timestamp):
            persistMeasurement(kind: .temperature, value: celsius, timestamp: timestamp, source: .ring, kindLabel: "temperature_sample")
        case let .bloodPressureSample(systolic, diastolic, timestamp):
            // BP is two metrics in one packet — store as two rows so each trends independently.
            persistMeasurement(kind: .bloodPressureSystolic, value: Double(systolic), timestamp: timestamp, source: .live, kindLabel: "bp_systolic_sample")
            persistMeasurement(kind: .bloodPressureDiastolic, value: Double(diastolic), timestamp: timestamp, source: .live, kindLabel: "bp_diastolic_sample")
        case let .fatigueSample(value, timestamp):
            persistMeasurement(kind: .fatigue, value: Double(value), timestamp: timestamp, source: .live, kindLabel: "fatigue_sample")
        case let .bloodSugarSample(mgdl, timestamp):
            persistMeasurement(kind: .bloodSugar, value: mgdl, timestamp: timestamp, source: .live, kindLabel: "blood_sugar_sample")
        case let .firmwareVersion(version):
            persistFirmwareVersion(version)
        case let .firmwareIdentity(deviceNumber, _, testVersion):
            if let device = DeviceRepository.current(context: context) {
                if device.deviceNumber != deviceNumber { device.deviceNumber = deviceNumber }
                if device.firmwareTestVersion != testVersion { device.firmwareTestVersion = testVersion }
            }
        case let .ringCapabilities(capabilities):
            if let device = DeviceRepository.current(context: context), device.ringCapabilitiesJSON != capabilities.json {
                device.ringCapabilitiesJSON = capabilities.json
            }
        case let .autoMeasureSchedule(entries):
            let json = AutoMeasureEntry.encodeList(entries)
            if let device = DeviceRepository.current(context: context), device.autoMeasureJSON != json {
                device.autoMeasureJSON = json
            }
        case let .bloodComponentsSample(reading, timestamp):
            for (kind, value) in reading.measurements {
                persistMeasurement(kind: kind, value: value, timestamp: timestamp, source: .live, kindLabel: "blood_components_sample")
            }
        case let .sleepTimeline(timestamp, stages, source):
            SleepService.applySleepRecord(start: timestamp, stages: stages, source: source, context: context)
        case let .gpsPoint(sessionId, latitude, longitude, altitude, horizontalAccuracy, speed, course, accepted, rejectionReason, timestamp):
            context.insert(ActivityGpsPoint(
                sessionId: sessionId,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: horizontalAccuracy,
                speed: speed,
                course: course,
                timestamp: timestamp,
                accepted: accepted,
                rejectionReason: rejectionReason
            ))
            if let session = ActivityRepository.session(id: sessionId, context: context) {
                if accepted {
                    session.gpsPointCount += 1
                    session.lastGpsPointAt = timestamp
                } else {
                    session.rejectedGpsPointCount += 1
                }
            }
        case let .syncProgress(stage):
            // Stamp the *completion* of a full history sync so the coach freshness gate can tell a
            // finished sync from a bare CONNECT (`lastSyncAt`, re-stamped every connect).
            if stage == "done" {
                if let device = DeviceRepository.current(context: context) {
                    device.lastFullSyncAt = Date()
                }
                // The rows are committed by now; the next sync re-checks against the database.
                seenHistoryKeys.removeAll(keepingCapacity: true)
                // Recompute calorie estimates for every day this sync touched, in one pass — the
                // batched flush below saves the writes and fires the coalesced change signal.
                DailyCalorieEstimator.flushDirty(context: context)
            }
        case .decodedPacket:
            noopWrite = true
        // `.wearState` is a live condition the measurement flow reacts to, not data — nothing to store.
        case .heartRateComplete, .spo2Progress, .spo2Complete, .workoutStarted, .workoutPaused,
             .workoutResumed, .workoutFinished, .coachTrace, .wearState, .chargingState:
            noopWrite = true
        }
        // NB: no per-event save here — `scheduleFlush()` (called by `persist`) batches the save.
    }
    
    /// Persist one live/history measurement, record a derived-update audit row, and link it to
    /// an in-progress workout if one is recording. Mirrors `persistence._on_hr_sample`.
    ///
    /// History rows are **upserted** on `(kind, timestamp)`: a ring replays the same log every time we
    /// re-request a day, and the epochs it stamps are deterministic, so an exact-timestamp match is a
    /// valid identity. Live samples keep append semantics (two readings a second apart are two events).
    private func persistMeasurement(kind: MeasurementKind, value: Double, timestamp: Date, source: MeasurementSource, kindLabel: String) {
        if source == .history, let unchanged = isDuplicateHistory(kind: kind, value: value, timestamp: timestamp) {
            // A re-synced slot with the same value writes nothing (a revised value updates in place).
            if unchanged { noopWrite = true }
            return
        }
        let row = Measurement(kind: kind, value: value, unit: kind.unit, timestamp: timestamp, source: source)
        context.insert(row)
        // No per-measurement `DerivedUpdateRow` any more: one audit row per sample doubled every sync's
        // inserts and nothing reads them per measurement (audit batch B; the table is also pruned).
        _ = ActivityRecorderService.linkSample(
            kind: kind,
            value: value,
            timestamp: timestamp,
            measurementId: row.id,
            source: source,
            confidence: .known,
            context: context
        )
    }

    /// True when this history sample is already stored (updating the existing row's value in place).
    /// Two tiers: an in-process key set keeps the hot sync path off the database entirely, and a single
    /// indexed fetch catches re-syncs across launches. `context.insert` is not visible to `fetch` until
    /// the batched save lands, which is exactly why the in-memory tier is needed.
    /// nil = new sample; true = already stored with this value; false = already stored, value revised.
    private func isDuplicateHistory(kind: MeasurementKind, value: Double, timestamp: Date) -> Bool? {
        let key = HistoryKey(kind: kind.rawValue, epoch: Int(timestamp.timeIntervalSince1970))
        if seenHistoryKeys.contains(key) { return true }
        seenHistoryKeys.insert(key)

        let kindRaw = kind.rawValue
        let sourceRaw = MeasurementSource.history.rawValue
        var descriptor = FetchDescriptor<Measurement>(predicate: #Predicate {
            $0.kindRaw == kindRaw && $0.timestamp == timestamp && $0.sourceRaw == sourceRaw
        })
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else { return nil }
        // Same slot, possibly refined value (the ring can revise an averaged block). Update in place;
        // no new audit/link row, because nothing new happened.
        guard existing.value != value else { return true }
        existing.value = value
        return false
    }

    /// Append a battery reading to the drainage history, throttled to on-change or a 30-min floor so
    /// the table stays tiny. Rides the same coalesced flush as every other persist (no extra `save()`).
    /// Returns whether a sample was written.
    @discardableResult
    private func recordBatterySample(_ percent: Int) -> Bool {
        guard (0...100).contains(percent) else { return false }   // guard the Device()-fallback default / garbage
        let now = Date()
        let changed = percent != lastBatteryPercent
        let floorElapsed = lastBatteryLogAt.map { now.timeIntervalSince($0) >= batteryMinInterval } ?? true
        guard changed || floorElapsed else { return false }
        context.insert(BatterySample(percent: percent, timestamp: now))
        lastBatteryPercent = percent
        lastBatteryLogAt = now
        return true
    }

    /// Names nobody chose: `"SMART_RING"` (the default `Device()` used to insert, and still sitting in
    /// rows written before `Device.name` became empty by default) and the ring's own placeholder name.
    /// A `Device.name` holding one of these has never been told what the ring is actually called, so it
    /// is the only kind of name this may overwrite.
    private static let placeholderDeviceNames: Set<String> =
        Set(["SMART_RING"] + RingDeviceType.allCases.map(\.displayName))

    /// Give the device the best name available for the ring **now on the other end of the link** — its
    /// advertised name, or its family's placeholder when the advertisement carried none — without ever
    /// overwriting a name a human chose.
    ///
    /// `Device.name` is what the human-facing surfaces read (the coach's device context, the diagnostics
    /// export's `wearableName`), and nothing ever wrote it: a paired ring exported as `SMART_RING`, which
    /// is a misleading thing to hand someone debugging. `advertisedName` alone was set and nothing read it.
    ///
    /// The placeholder check is the whole of the "don't clobber" rule. No screen renames a device today,
    /// so in practice this only ever fills a blank — but when one does, the user's name must survive the
    /// next connect, which re-publishes `.deviceIdentified` on every handshake.
    ///
    /// Falling back to `deviceType.displayName` keeps the row's name in the *current* ring's family when a
    /// connect brings no advertisement to adopt (state restoration, a cached peripheral). `.deviceForgotten`
    /// clears the name to `""` precisely so this path can run.
    private func adoptDeviceName(advertised: String?, deviceType: RingDeviceType, on device: Device) {
        let current = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || Self.placeholderDeviceNames.contains(current) else { return }
        let adopted = advertised ?? deviceType.displayName
        guard device.name != adopted else { return }
        device.name = adopted
    }

    /// Record the ring's firmware version on the current Device row (idempotent — no-op if unchanged).
    private func persistFirmwareVersion(_ version: String) {
        guard let device = DeviceRepository.current(context: context), device.firmwareVersion != version else { return }
        device.firmwareVersion = version
    }
}

/// How often the *live* heart-rate stream is written. The ring streams about one sample a second while
/// connected; outside a workout (and a spot test) one row per `minGap` keeps the chart's shape at a fifth of
/// the rows. Same rule and constant as Android's `LiveHeartRateThrottle`.
enum LiveHeartRateThrottle {
    static let minGap: TimeInterval = 5

    static func shouldStore(lastStoredAt: Date?, at: Date, keepAll: Bool) -> Bool {
        guard !keepAll, let lastStoredAt else { return true }
        return at < lastStoredAt || at.timeIntervalSince(lastStoredAt) >= minGap
    }
}
