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
/// For each day of the pass's `SyncPlan` (day 0, then every past day not yet complete for this ring): write
/// E0 `<day>` and wait until the sleep transfer completes — either its last-page marker (`E0 00 <sessions>`)
/// or its no-data marker (`E0 ?? 00`) — then write `DF <posLo> <posHi> <day>` (position 1 for a whole day,
/// `last stored + 1` to resume today) and wait for the `DF FF FF` end marker, then move on. Both completions were
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
    /// What the current history day has brought down so far (reported with the day's progress event).
    private var dayCounts = SyncDayCounts()

    private var authenticated = false
    private var currentDay = 0
    private var sleepComplete = false
    private var dailyComplete = false
    /// The E0 sleep pages of the transfer in flight: page index → raw frame. Scoped to **one transfer**
    /// (BUG-201): the buffer used to be keyed by day and page and survived across transfers, so a second
    /// transfer's page 0 replaced the first one's and the assembled payload mixed two nights.
    private var sleepFrames: [Int: Data] = [:]
    /// The highest page index this transfer announced (its first page carries it); page 0 is the last.
    private var sleepPageCount = 0
    /// The last page index buffered — a page index above it means the ring started a new transfer.
    private var lastSleepPageIndex = -1
    /// The day's sleep outcome for the ledger: true once a transfer's sleep reached storage, or the ring
    /// genuinely answered no-data. BUG-203: a day is not complete without it.
    private var daySleepStored = false
    /// The first `a1` identity this install saw per link (SEC-301); a later contradiction is counted.
    private var pinnedSensorId: [String: String] = [:]
    /// The `a1` identity of the current link, nil until its handshake reply arrives.
    private var linkSensorId: String?
    /// day → record index (BE16) → part → raw frame, for the DF daily records.
    private var dailyFrames: [Int: [Int: [Int: Data]]] = [:]
    /// The pass's plan (`SyncPlan`): which days, from which record. `planIndex` is the day in flight.
    private var plan: [SyncPlan.Day] = []
    private var planIndex = 0
    /// The ring and the day the pass started on — the ledger keys (a pass that crosses midnight keeps its dates).
    private var passRing: String?
    private var passToday = AppClock.now
    /// The current day's DF header record count (`total_blocks`) and the record numbers received intact.
    private var dayTotalBlocks: Int?
    private var dayRecords: Set<Int> = []
    /// The per-ring, per-date ledger the plan reads and each finished day updates. Injectable for tests.
    var syncPlanStore: SyncPlanStore = .shared
    /// The clock the plan's dates come from. Injectable for tests.
    var now: () -> Date = Date.init
    /// Live poll timer: refreshes today's totals (D8) and battery (A0) every 30 s, the same rolling
    /// read the python live client (`tools/veepoo_live.py`) performs — but at a cadence the UI can
    /// swallow, with the ~1 Hz FEA1 stream (driver) covering the between-poll movement.
    private var pollTimer: Timer?
    private var pollTick = 0
    /// Whether the continuous `D0 01` heart-rate test stream is held open (live HR mode). Managed by
    /// `reconcileLiveStream`, which follows `VeepooLivePrefsStore.liveHeartRateEnabled`.
    private var liveStreamStarted = false
    /// The app itself holds the `D0` stream (a workout's HR or a spot HR test, `startHeartRate` /
    /// `measureHeartRateSpot` until `stopHeartRate`). While set, `reconcileLiveStream` never sends `D0 00`, whatever
    /// the live-HR preference says — that would kill the app's own stream. Same as Android's `appHeldStream`.
    private var appHeldStream = false
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

    /// A spot heart-rate test (`measureHeartRateSpot`) is running. The ring serialises its notifications, so
    /// a history transfer running next to the test queues the 1 Hz `D0` samples behind hundreds of DF
    /// frames — they arrive seconds apart and the measurement fails its contact-gap check ("Couldn't get a
    /// steady reading" during the post-connect sync, 2026-09-26). While set, the day loop issues no new
    /// request: the transfer already on the wire finishes, the next E0/DF waits in `pendingHistoryRequest`.
    private var spotHeartRateActive = false
    /// The history request held back while `spotHeartRateActive`; sent when the test stops.
    private var pendingHistoryRequest: Data?

    /// The auth ack arrived while `FirmwareUpdateHold` was set; the post-auth sequence waits for its release.
    private var postAuthDeferred = false

    /// DF records dropped this connection because their CRC-16 didn't match the header (debug count).
    private(set) var crcFailures = 0
    /// Sleep transfers whose completeness checks failed (BUG-201): a page missing, or fewer sessions decoded
    /// than the header announced. The day is left un-advanced so the next pass asks for it again.
    private(set) var sleepIncompleteTransfers = 0
    /// Sleep sessions dropped because the `A1` block overran the payload, or carried no `A5` curve at all —
    /// storing either would be a fabricated hypnogram (BUG-108).
    private(set) var sleepRejectedSessions = 0
    /// Provenance of the sleep records this link delivered (SEC-301, report-only per decision D4).
    private(set) var sleepProvenance = SleepProvenance()
    /// Sessions whose decoded curve disagreed with the ring's own `A3` total or awake count (A2/BUG-202).
    /// Diagnostics only: the record is stored as decoded and the retries stay A1's and A4's.
    private(set) var sleepCountMismatches = 0
    /// The user's profile + goals for the `a3` frame, pushed after auth and on change (flag `profile_sync`).
    private var profile: UserProfileValues?
    /// Feature-flag lookup, injectable so tests can pin a flag without touching UserDefaults.
    var isFeatureOn: (AgaraFeature) -> Bool = { AgaraFeatureStore.isOn($0) }
    /// The live heart-rate preference (`VeepooLivePrefsStore`), injectable for tests.
    var wantsLiveHeartRate: () -> Bool = { VeepooLivePrefsStore.shared.liveHeartRateEnabled }
    private var livePrefObserver: NSObjectProtocol?

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
        // Apply a live-HR toggle at once (off → `D0 00` once), not at the next 30 s poll tick.
        livePrefObserver = NotificationCenter.default.addObserver(
            forName: VeepooLivePrefsStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveHeartRatePreferenceChanged() }
        }
    }

    /// The user flipped the live heart-rate preference: start or stop the `D0` stream now.
    func liveHeartRatePreferenceChanged() {
        guard authenticated else { return }
        reconcileLiveStream()
    }

    // MARK: Link lifecycle

    func connectionDidStart() {
        authenticated = false
        currentDay = 0
        sleepComplete = false
        dailyComplete = false
        resetSleepTransfer()
        dailyFrames.removeAll()
        daySleepStored = false
        linkSensorId = nil
        plan = []
        planIndex = 0
        dayTotalBlocks = nil
        dayRecords = []
        liveStreamStarted = false
        appHeldStream = false
        spotTestActive = false
        historyFinished = false
        historyInFlight = false
        postAuthDeferred = false
        spotHeartRateActive = false
        pendingHistoryRequest = nil
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
        case let .ringIdentity(sensorId):
            // SEC-301: the only identity iOS can compare — the ring's own `a1` MAC, hashed. CoreBluetooth
            // never reveals the BLE address, so the check is "does not contradict what this peripheral
            // reported before" rather than Android's MAC-vs-address equality.
            linkSensorId = sensorId
        case let .settingAck(commandId, _) where commandId == 0xB3:
            // Read the table back after every set, ok or not, so the app shows what the ring now holds.
            writer?.enqueue(VeepooEncoder.autoMeasureRead())
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
        beginPass()
        startPolling()
    }

    /// Plan the pass (`SyncPlan`) and ask for its first day — always day 0.
    private func beginPass() {
        passRing = writer?.historyRingID
        passToday = now()
        let ledger = passRing.map { syncPlanStore.ledger(ring: $0) }
        plan = SyncPlan.make(historyDays: historyDays, today: passToday, calendar: decoder.calendar, ledger: ledger).days
        planIndex = 0
        currentDay = plan.first?.offset ?? 0
        sleepComplete = false
        dailyComplete = false
        resetSleepTransfer()
        dailyFrames.removeAll()
        dayTotalBlocks = nil
        dayRecords = []
        #if DEBUG
        E2ETrace.log("history plan: " + plan.map { "day \($0.offset) from \($0.position)" }.joined(separator: ", ")
                     + " of \(historyDays) (ring \(passRing ?? "none"))")
        #endif
        historyInFlight = true
        lastProgressTick = pollTick
        beginHistoryDay(currentDay)
        requestHistory(VeepooEncoder.sleepHistory(dayOffset: currentDay))
    }

    /// The DF position the current day is asked from.
    private var currentPosition: Int {
        plan.indices.contains(planIndex) ? plan[planIndex].position : 1
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
        if historyInFlight, pendingHistoryRequest == nil, pollTick - lastProgressTick >= Self.stallTicks {
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
            completeDailyTransfer(endMarker: false)
        }
    }

    // MARK: Live heart-rate stream

    /// Keep the `D0 01` test stream in step with `VeepooLivePrefsStore.liveHeartRateEnabled`: start
    /// it once the history pass finished (the ring's own docs warn measurements before the daily read
    /// are refused as "busy"), stop it when the user disables live mode or the link drops. Re-run on
    /// every poll tick so a settings change applies within ~30 s.
    private func reconcileLiveStream() {
        guard !historyInFlight, !spotTestActive, !FirmwareUpdateHold.active else { return }
        let wantsLive = wantsLiveHeartRate()
        if wantsLive, !liveStreamStarted, historyFinished {
            liveStreamStarted = true
            writer?.enqueue(VeepooEncoder.heartRateStart())
        } else if !wantsLive, liveStreamStarted {
            liveStreamStarted = false
            // The app's own stream (workout / spot test) rides the same `D0`: leave it to the app's `stopHeartRate`.
            if !appHeldStream { writer?.enqueue(VeepooEncoder.heartRateStop()) }
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
        let pageIndex = Int(data[1])
        let sessions = Int(data[2])
        // No-data marker is exactly `E0 00 00 <day>`: page 0, no sessions. Reading byte 2 alone also
        // swallowed a real page — `e0 10 00 04 …` (page 0x10 of day 4) was discarded as "no data" (BUG-201).
        if pageIndex == 0x00, sessions == 0x00 {
            if dayOffset == currentDay, !sleepComplete {
                daySleepStored = true    // the ring kept no sleep for this day: that is an answer, not a loss
                completeSleepTransfer()
            }
            return
        }
        guard dayOffset == currentDay, !sleepComplete else { return }
        // BUG-201: pages count down to 0, so a page index above the last one held means the ring has
        // started a **new** transfer — drop the old pages rather than splicing two transfers together.
        if pageIndex > lastSleepPageIndex {
            sleepFrames.removeAll()
            sleepPageCount = pageIndex
        }
        lastSleepPageIndex = pageIndex
        // Never overwrite a page already held for this transfer: the same index from a second transfer can
        // carry a different body (16 payload bytes in a complete transfer, 4 in a page-0-only answer).
        if sleepFrames[pageIndex] == nil { sleepFrames[pageIndex] = data }
        if pageIndex == 0x00 { completeSleepTransfer(announcedSessions: sessions) }
    }

    /// Close the day's sleep phase.
    ///
    /// `announcedSessions` is the count page 0 declared (0 for the no-data marker, nil when the stall
    /// watchdog closed a transfer that never finished). An incomplete transfer is **not** stored and the
    /// day is not advanced: the watchdog closes the phase a tick later, and `SyncPlan` keeps the day in the
    /// walk because it has no sleep, so the next pass asks again (BUG-201 + BUG-203).
    private func completeSleepTransfer(announcedSessions: Int? = nil) {
        if let announcedSessions, announcedSessions > 0, !emitSleepSummary(announcedSessions: announcedSessions) {
            return
        }
        sleepComplete = true
        lastProgressTick = pollTick
        resetSleepTransfer()
        requestHistory(VeepooEncoder.dailyHistory(dayOffset: currentDay, position: currentPosition))
    }

    private func resetSleepTransfer() {
        sleepFrames.removeAll()
        sleepPageCount = 0
        lastSleepPageIndex = -1
    }

    /// Send the day loop's next request — or hold it while a spot HR test runs (`spotHeartRateActive`).
    private func requestHistory(_ frame: Data) {
        if spotHeartRateActive {
            pendingHistoryRequest = frame
        } else {
            writer?.enqueue(frame)
        }
    }

    /// The spot HR test ended: send the held-back request, and restart the stall clock so the paused
    /// time doesn't count as silence.
    private func resumeHistoryAfterSpotHeartRate() {
        guard spotHeartRateActive else { return }
        spotHeartRateActive = false
        lastProgressTick = pollTick
        if let frame = pendingHistoryRequest {
            pendingHistoryRequest = nil
            writer?.enqueue(frame)
        }
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
    /// - Returns: whether the transfer was stored (false = incomplete, nothing stored, retry the day).
    @discardableResult
    private func emitSleepSummary(announcedSessions: Int) -> Bool {
        // BUG-201 checks, the same two `SleepRawRepair` applies to stored bytes: every page index
        // 0…highest is here, and the sessions decoded equal the count the header announced.
        let runComplete = (0...sleepPageCount).allSatisfy { sleepFrames[$0] != nil }
        let payload = sleepFrames.keys.sorted(by: >).flatMap { Array((sleepFrames[$0] ?? Data()).dropFirst(4)) }
        let summaries = decoder.sleepSummaries(payload: payload)
        guard runComplete, summaries.count == announcedSessions else {
            sleepIncompleteTransfers += 1
            SleepSyncDiagnostics.shared.record(.incompleteTransfers)
            writer?.emit(.historySyncProgress(
                stage: "sleep: transfer incomplete (\(summaries.count) of \(announcedSessions) sessions), will retry"
            ))
            return false
        }
        let source = writer?.connectionSource
        for summary in summaries {
            noteProvenance()
            // BUG-108: a block whose declared length overran the payload is only partly decoded, and a
            // block with no `A5` curve has no stage order at all. Skip it (and keep the day in the walk)
            // rather than store a night the ring never gave.
            guard !summary.blockOverrun, !summary.stages.isEmpty else {
                sleepRejectedSessions += 1
                SleepSyncDiagnostics.shared.record(.rejectedSessions)
                writer?.emit(.historySyncProgress(
                    stage: summary.blockOverrun ? "sleep: a record overran its transfer, will retry"
                                                : "sleep: a record carried no stage curve, skipped"
                ))
                continue
            }
            writer?.emit(.sleepTimeline(timestamp: summary.start, stages: summary.stages, source: source))
            dayCounts.sleepNights += 1
            daySleepStored = true
            noteSleepCountMismatch(summary)
        }
        return daySleepStored
    }

    /// A2 (BUG-202) — compare the ring's own `A3` numbers with what was decoded, and say so.
    ///
    /// `A3` bytes 25–26 are the ring's total window (awake included) and bytes 29–30 its own awake count;
    /// the curve is what the app stores. On real firmware the two agree exactly (650 = 650, awake 38 = 38),
    /// so a difference means the transfer or the curve lost minutes — which nothing could see before, because
    /// the ring's numbers were dropped one frame after they were decoded.
    ///
    /// **Diagnostic only** (decision A2): no rewrite of what the user sees, and no second retry mechanism —
    /// the retries are A1's incomplete-transfer counter and A4's `blockOverrun`.
    private func noteSleepCountMismatch(_ summary: VeepooSleepSummary) {
        let curveMinutes = summary.stages.count
        let curveAwake = summary.stages.filter { $0 == .awake }.count
        var differences: [String] = []
        if abs(summary.totalMinutes - curveMinutes) > Self.sleepCountTolerance {
            differences.append("total \(summary.totalMinutes) vs curve \(curveMinutes)")
        }
        if let statedAwake = summary.statedAwakeMinutes, abs(statedAwake - curveAwake) > Self.sleepCountTolerance {
            differences.append("awake \(statedAwake) vs curve \(curveAwake)")
        }
        guard !differences.isEmpty else { return }
        sleepCountMismatches += 1
        SleepSyncDiagnostics.shared.record(.countMismatches)
        writer?.emit(.historySyncProgress(stage: "sleep: the ring's own count differs (" + differences.joined(separator: ", ") + ")"))
    }

    /// How far the ring's own `A3` count and the decoded curve may differ before it is reported as a
    /// diagnostic. Zero on real firmware; one minute absorbs a rounding difference in a re-staged night.
    static let sleepCountTolerance = 1

    /// SEC-301, **report-only** this release (decision D4): count what we would reject, keep storing.
    private func noteProvenance() {
        sleepProvenance.checked += 1
        guard let sensorId = linkSensorId else {
            sleepProvenance.nullIdentity += 1
            SleepSyncDiagnostics.shared.record(.provenanceNullIdentity)
            return
        }
        let source = writer?.connectionSource ?? ""
        if let pinned = pinnedSensorId[source] {
            guard pinned != sensorId else { return }
            sleepProvenance.mismatched += 1
            SleepSyncDiagnostics.shared.record(.provenanceMismatches)
            writer?.emit(.historySyncProgress(
                stage: "sleep: this link reports a different ring identity than it did before (SEC-301)"
            ))
        } else {
            pinnedSensorId[source] = sensorId
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
            if sleepComplete, !dailyComplete { completeDailyTransfer(endMarker: true) }
            return
        }
        guard data.count >= 4 else { return }
        // Record index is big-endian 16-bit: `(data[1] << 8) | data[2]`. Byte 2 is NOT the day
        // offset — this matters for full 288-record days. Do not regress.
        let recordIndex = (Int(data[1]) << 8) | Int(data[2])
        let part = Int(data[3])
        // Part 00 is the record header; bytes 4–5 (LE) are the day's record count (`total_blocks`).
        if part == 0, data.count >= 6 {
            let total = Int(data[4]) | (Int(data[5]) << 8)
            dayTotalBlocks = max(dayTotalBlocks ?? 0, total)
        }
        dailyFrames[currentDay, default: [:]][recordIndex, default: [:]][part] = data
    }

    private func completeDailyTransfer(endMarker: Bool) {
        dailyComplete = true
        lastProgressTick = pollTick
        emitDailyRecords()
        recordDayInLedger(endMarker: endMarker)
        writer?.emit(.historyDayProgress(SyncDayProgress(day: currentDay, totalDays: plan.count, counts: dayCounts,
                                                         days: plan.map(\.offset))))
        planIndex += 1
        if planIndex < plan.count {
            currentDay = plan[planIndex].offset
            // Reset the per-day phases before asking for the next day. Without this, `sleepComplete`
            // stays true from the previous day, so that day's sleep completion marker (or its no-data
            // marker) is ignored and the loop only advances via the 30 s stall watchdog — the whole
            // pass then takes a watchdog tick per day instead of a second. Found by driving this
            // engine against the ring emulator; on hardware it hid behind the watchdog.
            sleepComplete = false
            dailyComplete = false
            resetSleepTransfer()
            dailyFrames.removeAll()
            dayTotalBlocks = nil
            dayRecords = []
            daySleepStored = false
            beginHistoryDay(currentDay)
            requestHistory(VeepooEncoder.sleepHistory(dayOffset: currentDay))
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
        var implausible = 0
        for index in records.keys.sorted() {
            guard let parts = records[index] else { continue }
            let payload: [UInt8]
            switch Self.assemble(parts) {
            case let .complete(bytes): payload = bytes
            case .incomplete: incomplete += 1; continue
            case .checksumMismatch: corrupt += 1; continue
            }
            // BUG-102: the record's date is the day we asked for — B1 carries no year, and building one
            // from the phone's clock filed a ring a minute ahead a *year* back.
            guard let record = decoder.dailyRecord(payload: payload,
                                                   day: SyncPlan.date(offset: currentDay, today: passToday,
                                                                      calendar: decoder.calendar))
            else { continue }
            // BUG-105: a record whose slot the plausibility gate throws away must not count as stored —
            // the ring still holds those bytes and would serve them correctly, but a watermark that covers
            // a dropped record means the day is never asked for again.
            guard RingEventBridge.isWithinHistoryWindow(record.timestamp, now: now()) else {
                implausible += 1
                continue
            }
            // The SDK's record number (LE of bytes 1–2) — what a resume position counts in.
            dayRecords.insert((index >> 8) | ((index & 0xFF) << 8))
            dayCounts.steps += record.steps
            dayCounts.heartRate += record.heartRates.filter { $0.value > 0 }.count
            dayCounts.spo2 += record.oxygen.filter { $0.value > 0 }.count
            dayCounts.hrv += record.hrv.filter { $0.value > 0 }.count
            if record.stress > 0 { dayCounts.stress += 1 }

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
            for (offset, sample) in record.heartRates.enumerated() {
                let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
                writer?.emit(.historyMeasurement(kind: .heartRate, value: Double(sample.value), timestamp: date))
            }
            for (offset, sample) in record.oxygen.enumerated() {
                let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
                writer?.emit(.historyMeasurement(kind: .spo2, value: Double(sample.value), timestamp: date))
            }
            for (offset, sample) in record.hrv.enumerated() {
                let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
                writer?.emit(.historyMeasurement(kind: .hrv, value: Double(sample.value), timestamp: date))
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
        if implausible > 0, let writer {
            writer.emit(.historySyncProgress(
                stage: "daily: \(implausible) records outside the history window, will retry"
            ))
        }
    }

    /// Respiration (B6) and cardiac load (B9 20–24) per minute; MET (BF) and the five blood components
    /// (C2) at the slot start. Always decoded and stored — only their UI is behind flags.
    private func emitExtendedMetrics(_ record: VeepooDailyRecord) {
        let calendar = decoder.calendar
        for (offset, sample) in record.respiration.enumerated() {
            let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
            writer?.emit(.historyMeasurement(kind: .respiratoryRate, value: Double(sample.value), timestamp: date))
        }
        for (offset, sample) in record.cardiacLoad.enumerated() {
            let date = calendar.date(byAdding: .minute, value: offset, to: record.timestamp) ?? record.timestamp
            writer?.emit(.historyMeasurement(kind: .cardiacLoad, value: Double(sample.value), timestamp: date))
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
        appHeldStream = true
        writer?.enqueue(VeepooEncoder.heartRateStart())
    }

    func stopHeartRate() {
        appHeldStream = false
        writer?.enqueue(VeepooEncoder.heartRateStop())
        // `D0 00` ends whatever `D0` stream was open, the live one included; the tick restarts it.
        liveStreamStarted = false
        resumeHistoryAfterSpotHeartRate()
    }

    /// Spot HR: the same `D0 01` stream, but the day loop pauses between requests until `stopHeartRate`
    /// (see `spotHeartRateActive`). Workout and live streams use `startHeartRate` and don't pause it.
    func measureHeartRateSpot() {
        spotHeartRateActive = true
        appHeldStream = true
        writer?.enqueue(VeepooEncoder.heartRateStart())
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

    /// `b3 01` set, one metric (flag `auto_measure_settings`); the ack triggers a `b3 02` read-back in `handle`.
    func setAutoMeasure(_ entry: AutoMeasureEntry) -> Bool {
        guard authenticated, let writer, isFeatureOn(.autoMeasureSettings) else { return false }
        for frame in AutoMeasure.setFrames(entry) { writer.enqueue(frame) }
        return true
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
        // Stop the live stream for the pass — but not under a spot HR test, whose samples ride the same
        // stream: the pass starts paused instead and the test's own stop ends the stream.
        if liveStreamStarted, !spotHeartRateActive {
            liveStreamStarted = false
            writer?.enqueue(VeepooEncoder.heartRateStop())
        }
        beginPass()
    }

    /// Reset the day's counts and say the day started (`SyncProgress` shows it as "syncing").
    private func beginHistoryDay(_ day: Int) {
        dayCounts = SyncDayCounts()
        writer?.emit(.historyDayProgress(SyncDayProgress(day: day, totalDays: plan.count, days: plan.map(\.offset))))
    }

    /// Remember what this day brought down (`SyncPlan.record`), so a closed past day is skipped next time and
    /// today resumes after the unbroken run of stored records. Nothing is kept for a link without an identity.
    private func recordDayInLedger(endMarker: Bool) {
        guard let ring = passRing else { return }
        let date = SyncPlan.dateKey(offset: currentDay, today: passToday, calendar: decoder.calendar)
        let prior = syncPlanStore.state(ring: ring, date: date)
        let state = SyncPlan.record(prior, offset: currentDay,
                                    position: currentPosition, records: dayRecords,
                                    totalBlocks: dayTotalBlocks, endMarker: endMarker,
                                    sleepStored: daySleepStored)
        syncPlanStore.set(state, ring: ring, date: date, today: passToday, calendar: decoder.calendar)
        // BUG-211: the ring's own count came back below the watermark the app kept — its storage reset (a
        // firmware flash, a replacement ring, a cleared store). The day starts over; say why, so a stale
        // "stored through 93" over a ring that now holds 5 is not diagnosed as a sync that did nothing.
        let shrank = SyncPlan.shrank(prior, totalBlocks: dayTotalBlocks)
        if shrank {
            writer?.emit(.historySyncProgress(
                stage: "history: the ring's stored count for \(date) shrank (stored \(prior?.storedThrough ?? 0), "
                    + "ring now \(dayTotalBlocks ?? 0) records) — re-reading the day"
            ))
        }
        #if DEBUG
        E2ETrace.log("history day \(currentDay) (\(date)) from \(currentPosition): \(dayRecords.count) records, "
                     + "total \(dayTotalBlocks.map(String.init) ?? "-"), stored through \(state.storedThrough), "
                     + "sleep \(state.sleepStored ? "stored" : "missing"), "
                     + (state.complete ? "complete" : "open")
                     + (shrank ? " (ring storage shrank — re-reading the day)" : ""))
        #endif
    }
}