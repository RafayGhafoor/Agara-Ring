import Foundation

/// Veepoo sync engine: a response-driven machine gated on the A1 auth ack, then the per-day
/// E0→DF→marker history loop — a direct port of the hardware-verified harness in `tools/veepoo_ble.swift`.
///
/// ## Why the engine holds the history state
///
/// The ring's history replies do **not** echo the requested day offset (this is the load-bearing
/// finding of the harness work, and the reason the DF record index is a big-endian 16-bit so byte 2
/// is never mistaken for the offset). Only the code that *issues* the per-day queries knows which day
/// is in flight, so that code also owns the frame grouping — here, the engine. The driver forwards
/// E0/DF frames through as `.unknown` and the engine reassembles them under `currentDay`, exactly
/// like the harness's `currentHistoryDay`.
///
/// ## The day loop
///
/// For each day 0…`historyDays`-1: write E0 `<day>` and wait until the sleep transfer completes —
/// either its last-page marker (`E0 00 <sessions>`) or its no-data marker (`E0 ?? 00`) — then write
/// `DF 01 <day> 00` and wait for the `DF FF FF` end marker, then move on. Both completions were
/// observed on hardware: days 0–2 returned sleep, days 3–6 replied no-data immediately, and the DF
/// transfers for days 1–6 completed empty. A ring that goes silent mid-transfer stalls at that day —
/// the buffered frames stay put and the next connect re-runs the loop (`connectionDidStart` clears
/// them), which is the same tolerance the connectivity layer applies to a missing reply.
@MainActor
final class VeepooSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder: VeepooDecoder
    /// How many days of history the ring can hold / the loop walks. The verified run read 7 days
    /// (offsets 0–6) and the ring answered no-data past what it retained.
    private let historyDays: Int

    private var authenticated = false
    private var currentDay = 0
    private var sleepComplete = false
    private var dailyComplete = false
    /// day → page index → raw frame, for the E0 sleep pages.
    private var sleepFrames: [Int: [Int: Data]] = [:]
    /// day → record index (BE16) → part → raw frame, for the DF daily records.
    private var dailyFrames: [Int: [Int: [Int: Data]]] = [:]
    /// Live poll timer: refreshes today's totals (D8) and battery (A0) every 30 s, the same rolling
    /// read the python live client (`tools/veepoo_live.py`) performs — but at a cadence the UI can
    /// swallow, with the ~1 Hz FEA1 stream (driver) covering the between-poll movement.
    private var pollTimer: Timer?
    private var pollTick = 0
    /// Whether the continuous `D0 01` heart-rate test stream is held open (live HR mode). Managed by
    /// `reconcileLiveStream`, which follows `VeepooLivePrefsStore.liveHeartRateEnabled`.
    private var liveStreamStarted = false
    /// A SpO₂ / blood-pressure test holds the ring's optical sensor. The ring runs **one** test at a time:
    /// any `D0 01` while one is running switches it to heart rate and abandons the other — on the real ring
    /// the SpO₂ test ended itself (`80 02 02`) and the BP test froze at 40 %, both exactly when the poll tick
    /// re-asserted the live HR stream (captured on Android, 2026-09-25). While set, the tick sends nothing.
    private var spotTestActive = false
    /// The history loop has finished at least once — the SDK docs say measurements should run after
    /// the daily data was read, so the live stream only starts then (avoids "device busy" refusals).
    private var historyFinished = false
    /// A per-day history pass is in flight (startup or `syncHistory`). While set, the live stream
    /// must stay off — the ring refuses measurements mid-daily-read; `reconcileLiveStream` gates on it.
    private var historyInFlight = false
    /// Poll-tick number at which the history pass last made progress — a completion *or any E0/DF
    /// frame*. A day silent for a whole tick is treated as done by `watchdogAdvance` — the ring normally
    /// sends an explicit completion (or no-data) marker per day, but a dropped one (observed across a
    /// BLE reconnect) must not wedge the loop and block the live HR start forever. Counting frames as
    /// progress is what keeps a real day's DF transfer (longer than a tick) from being cut mid-stream.
    private var lastProgressTick = 0
    /// Ticks since the last progress before the watchdog fires. `lastProgressTick` holds the tick
    /// number *before* the next increment, so 2 means one whole tick interval (30–60 s) with no frame;
    /// 1 would fire at the first tick after any progress (0–30 s). Same value as Android's.
    static let stallTicks = 2

    /// The auth ack arrived while `FirmwareUpdateHold` was set; the post-auth sequence waits for its release.
    private var postAuthDeferred = false

    /// DF records dropped this connection because their CRC-16 didn't match the header (debug count).
    private(set) var crcFailures = 0
    /// The user's profile + goals for the `a3` frame, pushed after auth and on change (flag `profile_sync`).
    private var profile: UserProfileValues?
    /// Feature-flag lookup, injectable so tests can pin a flag without touching UserDefaults.
    var isFeatureOn: (AgaraFeature) -> Bool = { AgaraFeatureStore.isOn($0) }

    /// How many days of history the loop walks.
    ///
    /// Seven, because that is what the UI wants to show and what the vendor cloud holds. The ring
    /// itself only retains ~3 days and answers no-data for the rest — those days complete on their own
    /// marker immediately, so the extra days cost almost nothing. (An earlier 7-day walk was cut to 3
    /// because a flaky link restarted the pass from day 0 before it could finish; with the per-day state
    /// reset in `completeDailyTransfer` each day now ends on its marker instead of the 30 s watchdog.)
    init(writer: RingCommandWriter?, decoder: VeepooDecoder, historyDays: Int = AgaraConfig.Ring.historyDays) {
        self.writer = writer
        self.decoder = decoder
        self.historyDays = historyDays
    }

    // MARK: Link lifecycle

    func connectionDidStart() {
        authenticated = false
        currentDay = 0
        sleepComplete = false
        dailyComplete = false
        sleepFrames.removeAll()
        dailyFrames.removeAll()
        liveStreamStarted = false
        spotTestActive = false
        historyFinished = false
        historyInFlight = false
        postAuthDeferred = false
        crcFailures = 0
        stopPolling()
    }

    func connectionDidEnd() {
        connectionDidStart()
    }

    /// No-op on purpose: the A1 session frame is written by the driver's
    /// `immediatePostSubscriptionCommands` (it must lead), and everything this engine sends waits
    /// for the auth ack in `handle`.
    func runStartup() {}

    func handle(_ event: RingDecodedEvent) {
        switch event {
        case let .commandAck(commandId) where commandId == 0xA1 && !authenticated:
            authenticated = true
            runPostAuthentication()
        case let .unknown(commandId, raw) where commandId == 0xE0:
            handleSleepFrame(raw)
        case let .unknown(commandId, raw) where commandId == 0xDF:
            handleDailyFrame(raw)
        default:
            break
        }
    }

    // MARK: Post-auth sequence

    private func runPostAuthentication() {
        if FirmwareUpdateHold.active {
            // A reconnect in the middle of a firmware install: only the battery (the install shows it);
            // history and the poll tick wait until the hold is released.
            postAuthDeferred = true
            writer?.enqueue(VeepooEncoder.battery())
            return
        }
        // Session config, then battery + today's totals, then the day-0 history loop. The harness
        // ran these as spaced writes because it wrote directly; the client's serialized write queue
        // preserves order, so no inter-command delays are needed.
        writer?.enqueue(VeepooEncoder.session())
        writer?.enqueue(VeepooEncoder.battery())
        writer?.enqueue(VeepooEncoder.steps())
        if isFeatureOn(.profileSync), let profile {
            writer?.enqueue(VeepooEncoder.profile(profile))
        }
        // The schedule reply was only ever seen in the vendor app's sessions, so ask for it (read-only).
        if isFeatureOn(.autoMeasureSettings) {
            writer?.enqueue(VeepooEncoder.autoMeasureRead())
        }
        writer?.enqueue(VeepooEncoder.sleepHistory(dayOffset: 0))
        historyInFlight = true
        lastProgressTick = pollTick
        startPolling()
    }

    // MARK: Live polling (D8 / A0)

    /// Roll the python client's live loop into the app: poll D8 every 30 s (steps/distance/calories
    /// ratchet via `.activityUpdate`) and A0 every other tick (60 s battery). The ring answers these
    /// at any time, including mid-history-transfer, so no gating is needed.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollTickFired()
            }
        }
    }

    /// One poll tick: D8 every tick, A0 every other, the stall watchdog, the live-stream reconcile.
    /// Internal so tests can drive ticks without waiting 30 s.
    func pollTickFired() {
        pollTick += 1
        // Leave the ring alone mid-test (see `spotTestActive`) and mid-install; the next tick after resumes.
        if spotTestActive || FirmwareUpdateHold.active { return }
        writer?.enqueue(VeepooEncoder.steps())
        if pollTick.isMultiple(of: 2) {
            writer?.enqueue(VeepooEncoder.battery())
        }
        if historyInFlight, pollTick - lastProgressTick >= Self.stallTicks {
            watchdogAdvance()
        }
        reconcileLiveStream()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTick = 0
    }

    /// Advance a stalled history day: finish whichever phase is outstanding (sleep, then daily) and
    /// move on — the loop's own markers are still preferred, this only fires when one is missing.
    private func watchdogAdvance() {
        if !sleepComplete {
            completeSleepTransfer()
        } else if !dailyComplete {
            completeDailyTransfer()
        }
    }

    // MARK: Live heart-rate stream

    /// Keep the `D0 01` test stream in step with `VeepooLivePrefsStore.liveHeartRateEnabled`: start
    /// it once the history pass finished (the ring's own docs warn measurements before the daily read
    /// are refused as "busy"), stop it when the user disables live mode or the link drops. Re-run on
    /// every poll tick so a settings change applies within ~30 s.
    private func reconcileLiveStream() {
        guard !historyInFlight, !spotTestActive, !FirmwareUpdateHold.active else { return }
        let wantsLive = VeepooLivePrefsStore.shared.liveHeartRateEnabled
        if wantsLive, !liveStreamStarted, historyFinished {
            liveStreamStarted = true
            writer?.enqueue(VeepooEncoder.heartRateStart())
        } else if !wantsLive, liveStreamStarted {
            liveStreamStarted = false
            writer?.enqueue(VeepooEncoder.heartRateStop())
        } else if wantsLive, liveStreamStarted {
            // Re-assert the start every tick: the ring can end the test stream on its side (observed:
            // ~20 s of 1 Hz rows then silence while the link still stood), and once it has, the only
            // way back is a fresh start frame — this makes the stream self-healing instead of waiting
            // for the next reconnect to re-run the whole startup.
            writer?.enqueue(VeepooEncoder.heartRateStart())
        }
    }

    // MARK: E0 sleep pages

    private func handleSleepFrame(_ data: Data) {
        guard data.count >= 4 else { return }
        lastProgressTick = pollTick
        let dayOffset = Int(data[3])
        // No-data marker (`E0 ?? 00 <day>`): the ring kept no sleep for this day. Complete the
        // phase so the loop moves on to the daily transfer — same as the harness.
        if data[2] == 0x00 {
            if dayOffset == currentDay, !sleepComplete { completeSleepTransfer() }
            return
        }
        sleepFrames[dayOffset, default: [:]][Int(data[1])] = data
        // Last page (`E0 00 <sessions> <day>`): the payload pages are all in. Byte 2 is the number of
        // sessions in the transfer — 1 on every page seen so far, but a day with a nap is `E0 00 02`,
        // which the old `== 0x01` test never completed (only the stall watchdog moved it on).
        if data[1] == 0x00, dayOffset == currentDay, !sleepComplete {
            completeSleepTransfer()
        }
    }

    private func completeSleepTransfer() {
        sleepComplete = true
        lastProgressTick = pollTick
        emitSleepSummary()
        writer?.enqueue(VeepooEncoder.dailyHistory(dayOffset: currentDay))
    }

    /// Assemble the sleep payload exactly as the harness did — pages sorted descending, frame header
    /// (4 bytes) stripped — then emit one per-minute timeline per session (`A1` block) in the transfer.
    ///
    /// Each record is stamped with the link's identity (`RingCommandWriter.connectionSource`), because the
    /// store replaces only the *same source's* overlapping blocks: a grown re-send of this ring's night
    /// replaces its earlier version, while the emulator or a second ring on the same night never touches it
    /// (`docs/process/plans/sleep-session-merge.md` §5). On iOS the identity is the CoreBluetooth peripheral
    /// UUID — CoreBluetooth hides the MAC, so the `a1` MAC check Android applies (D3) has nothing to compare
    /// against here (a recorded platform difference).
    private func emitSleepSummary() {
        guard let frames = sleepFrames[currentDay], !frames.isEmpty else { return }
        let payload = frames.keys.sorted(by: >).flatMap { Array((frames[$0] ?? Data()).dropFirst(4)) }
        let source = writer?.connectionSource
        for summary in decoder.sleepSummaries(payload: payload) {
            writer?.emit(.sleepTimeline(timestamp: summary.start, stages: summary.stages, source: source))
        }
    }

    // MARK: DF daily records

    private func handleDailyFrame(_ data: Data) {
        guard data.count >= 3 else { return }
        lastProgressTick = pollTick
        // End marker (`DF FF FF`): the day's record transfer is complete — but only while this day's DF
        // request is outstanding (sleep done, daily not). A stray marker (e.g. from a duplicated
        // request's transfer) arriving during the sleep phase used to complete the day without its
        // records ever being asked for; on 2026-09-25 that skipped days 1–6 in 0.6 s (Android capture).
        if data[1] == 0xFF, data[2] == 0xFF {
            if sleepComplete, !dailyComplete { completeDailyTransfer() }
            return
        }
        guard data.count >= 4 else { return }
        // Record index is big-endian 16-bit: `(data[1] << 8) | data[2]`. Byte 2 is NOT the day
        // offset — this matters for full 288-record days. Do not regress.
        let recordIndex = (Int(data[1]) << 8) | Int(data[2])
        let part = Int(data[3])
        dailyFrames[currentDay, default: [:]][recordIndex, default: [:]][part] = data
    }

    private func completeDailyTransfer() {
        dailyComplete = true
        lastProgressTick = pollTick
        emitDailyRecords()
        currentDay += 1
        if currentDay < historyDays {
            // Reset the per-day phases before asking for the next day. Without this, `sleepComplete`
            // stays true from the previous day, so that day's sleep completion marker (or its no-data
            // marker) is ignored and the loop only advances via the 30 s stall watchdog — the whole
            // pass then takes a watchdog tick per day instead of a second. Found by driving this
            // engine against the ring emulator; on hardware it hid behind the watchdog.
            sleepComplete = false
            dailyComplete = false
            sleepFrames.removeAll()
            dailyFrames.removeAll()
            writer?.enqueue(VeepooEncoder.sleepHistory(dayOffset: currentDay))
        } else {
            writer?.emit(.historySyncFinished)
            historyFinished = true
            historyInFlight = false
            reconcileLiveStream()
        }
    }

    private func emitDailyRecords() {
        guard let records = dailyFrames[currentDay] else { return }
        var incomplete = 0
        var corrupt = 0
        for index in records.keys.sorted() {
            guard let parts = records[index] else { continue }
            let payload: [UInt8]
            switch Self.assemble(parts) {
            case let .complete(bytes): payload = bytes
            case .incomplete: incomplete += 1; continue
            case .checksumMismatch: corrupt += 1; continue
            }
            guard let record = decoder.dailyRecord(payload: payload) else { continue }

            // Activity slot (B2): the day total is recomputed as the sum of distinct-timestamp
            // buckets, so re-syncs are idempotent.
            writer?.emit(.activityBucket(
                timestamp: record.timestamp,
                steps: record.steps,
                distanceMeters: Double(record.distanceMeters)
            ))

            // Per-minute vitals. B4 (HR) and B9 (SpO₂) carry five one-minute samples per 5-minute
            // slot, stamped at slot + i minutes; the rest are single values at the slot start.
            let calendar = decoder.calendar
            for (offset, value) in record.heartRates.enumerated() {
                let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
                writer?.emit(.historyMeasurement(kind: .heartRate, value: Double(value), timestamp: date))
            }
            for (offset, value) in record.oxygen.enumerated() {
                let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
                writer?.emit(.historyMeasurement(kind: .spo2, value: Double(value), timestamp: date))
            }
            for (offset, value) in record.hrv.enumerated() {
                let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
                writer?.emit(.historyMeasurement(kind: .hrv, value: Double(value), timestamp: date))
            }
            if record.systolic > 0, record.diastolic > 0 {
                writer?.emit(.historyMeasurement(
                    kind: .bloodPressureSystolic, value: Double(record.systolic), timestamp: record.timestamp
                ))
                writer?.emit(.historyMeasurement(
                    kind: .bloodPressureDiastolic, value: Double(record.diastolic), timestamp: record.timestamp
                ))
            }
            if record.stress > 0 {
                writer?.emit(.historyMeasurement(kind: .stress, value: Double(record.stress), timestamp: record.timestamp))
            }
            if record.glucoseMgdl > 0 {
                writer?.emit(.historyMeasurement(kind: .bloodSugar, value: record.glucoseMgdl, timestamp: record.timestamp))
            }
            emitExtendedMetrics(record)
        }
        crcFailures += corrupt
        if incomplete > 0, let writer {
            writer.emit(.historySyncProgress(stage: "daily: \(incomplete) incomplete records skipped"))
        }
        if corrupt > 0, let writer {
            writer.emit(.historySyncProgress(stage: "daily: \(corrupt) records failed their checksum"))
        }
    }

    /// Respiration (B6) and cardiac load (B9 20–24) per minute; MET (BF) and the five blood components
    /// (C2) at the slot start. Always decoded and stored — only their UI is behind flags.
    private func emitExtendedMetrics(_ record: VeepooDailyRecord) {
        let calendar = decoder.calendar
        for (offset, value) in record.respiration.enumerated() {
            let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
            writer?.emit(.historyMeasurement(kind: .respiratoryRate, value: Double(value), timestamp: date))
        }
        for (offset, value) in record.cardiacLoad.enumerated() {
            let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
            writer?.emit(.historyMeasurement(kind: .cardiacLoad, value: Double(value), timestamp: date))
        }
        if record.met > 0 {
            writer?.emit(.historyMeasurement(kind: .met, value: record.met, timestamp: record.timestamp))
        }
        for (kind, value) in record.bloodComponents?.measurements ?? [] {
            writer?.emit(.historyMeasurement(kind: kind, value: value, timestamp: record.timestamp))
        }
    }

    /// The outcome of joining one DF record's parts.
    enum RecordAssembly: Equatable {
        case complete([UInt8])
        /// A declared part is missing.
        case incomplete
        /// All parts are in, but the CRC-16 in the header doesn't match — the record is dropped.
        case checksumMismatch
    }

    /// Join a DF record's data parts `1…N` into its TLV stream. N depends on the MTU — 2 at a large
    /// MTU (125-byte frames, what iOS normally negotiates), 15 at the default one (20-byte frames) —
    /// and is carried in the part-`00` header (frame byte 6). Reading only parts 1+2 at the default
    /// MTU cuts `B4` mid-value and drops every vital sign (`docs/process/plans/df-multipart-records.md`).
    /// Without a header, the contiguous run from part 1 is used. Nil while any declared part is missing
    /// or the checksum fails.
    static func assembleRecord(_ parts: [Int: Data]) -> [UInt8]? {
        if case let .complete(payload) = assemble(parts) { return payload }
        return nil
    }

    /// `assembleRecord` with the reason when it fails. With a part-`00` header, the joined stream is cut
    /// to the valid byte count (header byte 10) and checked against the CRC-16/MODBUS in bytes 11–12
    /// (LE) — every one of the 12,505 records in the real capture passes, so a mismatch is corruption.
    static func assemble(_ parts: [Int: Data]) -> RecordAssembly {
        var count = 0
        let header = parts[0].map { [UInt8]($0) }
        if let header, header.count > 6, header[6] > 0 {
            count = Int(header[6])
        } else {
            while parts[count + 1] != nil { count += 1 }
        }
        guard count > 0 else { return .incomplete }
        var payload: [UInt8] = []
        for part in 1...count {
            guard let frame = parts[part] else { return .incomplete }
            payload += frame.dropFirst(4)
        }
        if let header, header.count > 12 {
            let valid = Int(header[10])
            if valid > 0, valid <= payload.count {
                payload = Array(payload.prefix(valid))
                let expected = UInt16(header[11]) | (UInt16(header[12]) << 8)
                guard veepooCRC16Modbus(payload) == expected else { return .checksumMismatch }
            }
        }
        return .complete(payload)
    }

    // MARK: App-facing actions

    /// One-shot measurements: enqueue the SDK's per-test start frames; the driver latches `measuring`
    /// off them and decodes the D0/0x80/0x90 streams into live events. The Vitals screen drives the
    /// session (start on tap, stop when the reading lands) exactly like it does for other families.
    func startHeartRate() {
        writer?.enqueue(VeepooEncoder.heartRateStart())
    }

    func stopHeartRate() {
        writer?.enqueue(VeepooEncoder.heartRateStop())
    }

    // SpO₂ and BP take the sensor from the live HR stream: mark the stream stopped (the ring drops it
    // when another test starts) and hold the poll tick off until the test ends — see `spotTestActive`.
    func startSpO2() { startSpotTest(VeepooEncoder.oxygenStart()) }

    func stopSpO2() { stopSpotTest(VeepooEncoder.oxygenStop()) }

    func startBloodPressure() { startSpotTest(VeepooEncoder.bloodPressureStart()) }

    func stopBloodPressure() { stopSpotTest(VeepooEncoder.bloodPressureStop()) }

    // Stress, glucose and blood components hold the optical sensor the same way.
    func startStress() { startSpotTest(VeepooEncoder.stressStart()) }

    func stopStress() { stopSpotTest(VeepooEncoder.stressStop()) }

    func startGlucose() { startSpotTest(VeepooEncoder.glucoseStart()) }

    func stopGlucose() { stopSpotTest(VeepooEncoder.glucoseStop()) }

    func startBloodComponents() { startSpotTest(VeepooEncoder.bloodComponentsStart()) }

    func stopBloodComponents() { stopSpotTest(VeepooEncoder.bloodComponentsStop()) }

    private func startSpotTest(_ frame: Data) {
        spotTestActive = true
        liveStreamStarted = false
        writer?.enqueue(frame)
    }

    private func stopSpotTest(_ frame: Data) {
        spotTestActive = false
        writer?.enqueue(frame)
    }

    /// Find ring: `b5 0a` starts the vibration, `b5 0b` stops it (the coordinator auto-stops after 10 s).
    func findDevice() {
        writer?.enqueue(VeepooEncoder.findDeviceStart())
    }

    func stopFindDevice() {
        writer?.enqueue(VeepooEncoder.findDeviceStop())
    }

    /// The step goal rides the `a3` profile frame, sent by `applyUserProfile` (flag `profile_sync`).
    func setGoal(steps: Int) {}

    /// Remember the profile for the post-auth `a3` frame.
    func setUserProfile(_ profile: UserProfileValues) {
        self.profile = profile
    }

    /// Profile or goals changed while connected: push the `a3` frame now (flag `profile_sync`).
    func applyUserProfile(_ profile: UserProfileValues) {
        self.profile = profile
        guard authenticated, isFeatureOn(.profileSync) else { return }
        writer?.enqueue(VeepooEncoder.profile(profile))
    }

    var isHistorySyncing: Bool { historyInFlight }

    func enterFirmwareHold() {
        if liveStreamStarted {
            liveStreamStarted = false
            writer?.enqueue(VeepooEncoder.heartRateStop())
        }
    }

    func resumeAfterFirmwareHold() {
        if authenticated, postAuthDeferred {
            postAuthDeferred = false
            runPostAuthentication()
        }
    }

    /// Battery is in-band: A0 → decoded `.battery` event. The once-per-connect A0 in the post-auth
    /// sequence covers the normal case; this re-requests on demand.
    func requestBattery() {
        writer?.enqueue(VeepooEncoder.battery())
    }

    /// Re-run the whole per-day history loop without re-handshaking — the periodic top-up while
    /// connected. Reset the per-day state first so frames from the previous pass cannot pollute this
    /// one (record indexes restart every day, and the ring does not echo the day).
    ///
    /// The live HR stream must be **stopped** for the duration: the ring refuses measurements while
    /// the daily data is being read (the SDK's own "device busy" contract), so a history pass run
    /// against an open `D0 01` stream comes back empty — which is exactly how "connected but sleep
    /// never refreshes" happens. `completeDailyTransfer` restarts the stream when the pass ends.
    func syncHistory() {
        // A pass already in flight is not restarted: re-sending `E0 00` mid-transfer makes the ring serve
        // day 0 again, and that transfer's end marker lands in the middle of the new pass.
        guard authenticated, !historyInFlight, !FirmwareUpdateHold.active else { return }
        currentDay = 0
        sleepComplete = false
        dailyComplete = false
        sleepFrames.removeAll()
        dailyFrames.removeAll()
        if liveStreamStarted {
            liveStreamStarted = false
            writer?.enqueue(VeepooEncoder.heartRateStop())
        }
        historyInFlight = true
        lastProgressTick = pollTick
        writer?.enqueue(VeepooEncoder.sleepHistory(dayOffset: 0))
    }
}