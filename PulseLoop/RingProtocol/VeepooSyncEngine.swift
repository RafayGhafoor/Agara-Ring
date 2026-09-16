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
/// either its last-page marker (`E0 00 01`) or its no-data marker (`E0 ?? 00`) — then write
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
    /// The history loop has finished at least once — the SDK docs say measurements should run after
    /// the daily data was read, so the live stream only starts then (avoids "device busy" refusals).
    private var historyFinished = false
    /// A per-day history pass is in flight (startup or `syncHistory`). While set, the live stream
    /// must stay off — the ring refuses measurements mid-daily-read; `reconcileLiveStream` gates on it.
    private var historyInFlight = false
    /// Poll-tick number at which the history pass last made progress. A day that does not advance
    /// within two ticks (~60 s) is treated as done by `watchdogAdvance` — the ring normally sends an
    /// explicit completion (or no-data) marker per day, but a dropped one (observed across a BLE
    /// reconnect) must not wedge the loop and block the live HR start forever.
    private var lastProgressTick = 0

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
        historyFinished = false
        historyInFlight = false
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
        // Session config, then battery + today's totals, then the day-0 history loop. The harness
        // ran these as spaced writes because it wrote directly; the client's serialized write queue
        // preserves order, so no inter-command delays are needed.
        writer?.enqueue(VeepooEncoder.session())
        writer?.enqueue(VeepooEncoder.battery())
        writer?.enqueue(VeepooEncoder.steps())
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
                guard let self else { return }
                self.pollTick += 1
                self.writer?.enqueue(VeepooEncoder.steps())
                if self.pollTick.isMultiple(of: 2) {
                    self.writer?.enqueue(VeepooEncoder.battery())
                }
                if self.historyInFlight, self.pollTick - self.lastProgressTick >= 1 {
                    self.watchdogAdvance()
                }
                self.reconcileLiveStream()
            }
        }
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
        guard !historyInFlight else { return }
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
        let dayOffset = Int(data[3])
        // No-data marker (`E0 ?? 00 <day>`): the ring kept no sleep for this day. Complete the
        // phase so the loop moves on to the daily transfer — same as the harness.
        if data[2] == 0x00 {
            if dayOffset == currentDay, !sleepComplete { completeSleepTransfer() }
            return
        }
        sleepFrames[dayOffset, default: [:]][Int(data[1])] = data
        // Last page (`E0 00 01 <day>`): the payload pages are all in.
        if data[1] == 0x00, data[2] == 0x01, dayOffset == currentDay, !sleepComplete {
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
    /// (4 bytes) stripped — then decode the A3 summary into a per-minute sleep timeline.
    private func emitSleepSummary() {
        guard let frames = sleepFrames[currentDay], !frames.isEmpty else { return }
        let payload = frames.keys.sorted(by: >).flatMap { Array((frames[$0] ?? Data()).dropFirst(4)) }
        guard let summary = decoder.sleepSummary(payload: payload) else { return }

        // Stages expand at one minute each from `start`. The minute COUNTS are hardware-verified;
        // the per-minute ordering is not recoverable from the A3 payload, so deep → light → awake →
        // other is the documented assumption. `persistSleepTimeline` dedups by block start, so
        // re-syncs are idempotent.
        writer?.emit(.sleepTimeline(timestamp: summary.start, stages: summary.stages))
    }

    // MARK: DF daily records

    private func handleDailyFrame(_ data: Data) {
        guard data.count >= 3 else { return }
        // End marker (`DF FF FF`): the day's record transfer is complete.
        if data[1] == 0xFF, data[2] == 0xFF {
            if !dailyComplete { completeDailyTransfer() }
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
        for index in records.keys.sorted() {
            guard let parts = records[index], let first = parts[1], let second = parts[2] else {
                incomplete += 1
                continue
            }
            let payload = Array(first.dropFirst(4)) + Array(second.dropFirst(4))
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
        }
        if incomplete > 0, let writer {
            writer.emit(.historySyncProgress(stage: "daily: \(incomplete) incomplete records skipped"))
        }
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

    func startSpO2() {
        writer?.enqueue(VeepooEncoder.oxygenStart())
    }

    func stopSpO2() {
        writer?.enqueue(VeepooEncoder.oxygenStop())
    }

    func startBloodPressure() {
        writer?.enqueue(VeepooEncoder.bloodPressureStart())
    }

    func stopBloodPressure() {
        writer?.enqueue(VeepooEncoder.bloodPressureStop())
    }

    /// No find-device or goal opcode exists in the verified subset — explicit no-ops.
    func findDevice() {}
    func setGoal(steps: Int) {}

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
        guard authenticated else { return }
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