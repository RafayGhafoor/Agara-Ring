import Foundation

/// Something the link reports while an install runs: a notification on `F031`, or the link going down.
enum OtaLinkEvent: Equatable {
    case notify(Data)
    case dropped
}

/// The transport the installer drives — the connected Agara ring's `F003` service. Behind a protocol so the
/// state machine runs against a scripted fake ring in unit tests; production is `RingOtaLink`.
@MainActor
protocol OtaLink: AnyObject {
    /// Receives every `OtaLinkEvent` from now on; nil detaches.
    func setListener(_ listener: ((OtaLinkEvent) -> Void)?)

    var isConnected: Bool { get }

    /// Prepare `F003` on the current connection: enable `F031` notifications. Returns the largest frame the
    /// link can carry (write-without-response), or nil when the ring has no `F003`/`F031`/`F032`.
    func openChannel() async -> Int?

    /// One frame to `F032`, write-without-response, in order. Never blocks.
    func write(_ frame: Data)

    /// Bring the link back (after a drop, or after the post-update restart). True once connected within `timeout`.
    func reconnect(timeout: TimeInterval) async -> Bool

    /// Wait for the link to go down (the ring restarting). True when it did within `timeout`.
    func awaitDisconnect(timeout: TimeInterval) async -> Bool

    /// The firmware the ring's `a1` reply reports on the current connection, waiting up to `timeout`.
    func awaitFirmwareVersion(timeout: TimeInterval) async -> String?
}

/// Why an install stopped. `retryable`: the screen offers "Try again" (the ring resumes where it stopped).
/// Same cases and copy as Android `InstallFailure`.
enum InstallFailure: String, CaseIterable, Equatable, Sendable {
    case blocked, sameFirmware, wrongKey, wrongCRC, refused, deviceError, noChannel, timeout, linkLost,
         notConfirmed, versionMismatch, cancelled

    var message: String {
        switch self {
        case .blocked: return "The update can't start right now."
        case .sameFirmware: return "The ring already has this firmware — it's up to date."
        case .wrongKey: return "The ring rejected this file: it isn't firmware for this ring."
        case .wrongCRC: return "The ring rejected this file: its check didn't match. Download it again and retry."
        case .refused: return "The ring declined the update. Try again in a moment."
        case .deviceError: return "The ring reported an update error. Try again from this screen."
        case .noChannel: return "The ring's update channel isn't available. Reconnect the ring and try again."
        case .timeout: return "The ring stopped responding. Keep it next to the phone and try again from this screen."
        case .linkLost:
            return "Lost the connection to the ring. Keep it on its charger next to the phone and try again from this "
                + "screen — it continues where it stopped."
        case .notConfirmed:
            return "The ring didn't come back after restarting, so the update couldn't be confirmed. Reconnect it and "
                + "check the firmware version."
        case .versionMismatch: return "The ring restarted but doesn't report the new version, so the update didn't take."
        case .cancelled: return "Update cancelled. Nothing was written to the ring."
        }
    }

    var retryable: Bool {
        switch self {
        case .sameFirmware, .wrongKey: return false
        default: return true
        }
    }
}

/// Where an install stands, for the full-screen progress. Same states as Android `InstallState`.
enum InstallState: Equatable, Sendable {
    case idle
    /// Handshake with the ring; nothing written to flash yet, so Cancel is still possible.
    case preparing(resuming: Bool)
    case transferring(sent: Int, total: Int, block: Int, blocks: Int)
    /// The ring asked for a pause (`90 fd`) and will say when to continue.
    case paused(sent: Int, total: Int)
    /// The link dropped mid-transfer; reconnecting to resume from where the ring stopped.
    case reconnecting(attempt: Int, maxAttempts: Int, sent: Int, total: Int)
    /// Transfer done (`90 ff`); waiting for the ring to restart, reconnect and report its version.
    case verifying(target: String)
    case succeeded(version: String)
    case failed(InstallFailure, detail: String?)

    static func failed(_ failure: InstallFailure) -> InstallState { .failed(failure, detail: nil) }

    /// 0…100 for the states that carry a byte count.
    var percent: Int {
        let sent: Int, total: Int
        switch self {
        case let .transferring(s, t, _, _): (sent, total) = (s, t)
        case let .paused(s, t): (sent, total) = (s, t)
        case let .reconnecting(_, _, s, t): (sent, total) = (s, t)
        default: return 0
        }
        guard total > 0 else { return 0 }
        return max(0, min(100, sent * 100 / total))
    }

    /// True while the ring may be mid-flash — the screen can't be left and stays on.
    var busy: Bool {
        switch self {
        case .preparing, .transferring, .paused, .reconnecting, .verifying: return true
        case .idle, .succeeded, .failed: return false
        }
    }

    var failure: InstallFailure? {
        if case let .failed(failure, _) = self { return failure }
        return nil
    }

    /// The failure's words: the specific detail when there is one, else the failure's message.
    var failureMessage: String? {
        if case let .failed(failure, detail) = self { return detail ?? failure.message }
        return nil
    }
}

/// Timeouts (seconds) and limits. Block ack, stall, reconnects and the reboot wait come from the shared
/// catalog (`AgaraConfig.Ring.firmware*`); the rest match Android's `OtaTimings` defaults.
struct OtaTimings: Sendable {
    var replyTimeout: TimeInterval = 10
    var blockAckTimeout: TimeInterval = TimeInterval(AgaraConfig.Ring.firmwareBlockAckTimeoutS)
    var stallTimeout: TimeInterval = TimeInterval(AgaraConfig.Ring.firmwareStallTimeoutS)
    var identifySettle: TimeInterval = 0.2
    var reconnectTimeout: TimeInterval = 45
    var maxReconnects: Int = AgaraConfig.Ring.firmwareMaxReconnects
    /// How long the ring may take to drop the link after `90 ff` before we check its version anyway.
    var rebootDropTimeout: TimeInterval = 15
    var rebootReconnectTimeout: TimeInterval = TimeInterval(AgaraConfig.Ring.firmwareRebootTimeoutS)
    var versionTimeout: TimeInterval = 20
}

/// The events the installer has not consumed yet, with a single async reader that can time out.
@MainActor
private final class OtaInbox {
    private var events: [OtaLinkEvent] = []
    private var waiter: CheckedContinuation<OtaLinkEvent?, Never>?
    private var waiterID = 0

    func push(_ event: OtaLinkEvent) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    func drain() { events.removeAll() }

    /// The next event, or nil after `timeout` seconds with none.
    func next(timeout: TimeInterval) async -> OtaLinkEvent? {
        if !events.isEmpty { return events.removeFirst() }
        guard timeout > 0 else { return nil }
        waiterID += 1
        let id = waiterID
        return await withCheckedContinuation { continuation in
            waiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.waiterID == id, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.resume(returning: nil)
            }
        }
    }
}

/// The install state machine: handshake → blocks → `90 ff` → restart → `a1` version check. Resumes from the
/// ring's reported start address after a link drop (up to `OtaTimings.maxReconnects` reconnects). Success
/// **only** when the ring, after restarting, reports the target version. A line-for-line port of Android
/// `AbOtaInstaller`; frames are built by `AbOta` exactly as the emulator's `ota.py` does.
@MainActor
final class AbOtaInstaller {
    nonisolated deinit {}

    private let link: OtaLink
    private let timings: OtaTimings
    private let log: (String) -> Void
    /// Runs once, right before the first block is written: returns why the install must not start (a gate
    /// that no longer holds), or nil to go ahead.
    private let preflight: (@MainActor () async -> String?)?
    private let inbox = OtaInbox()

    private var cancelRequested = false
    private var preflightDone = false

    /// True once the first block has gone out — from then on the install can't be cancelled.
    private(set) var started = false

    init(link: OtaLink, timings: OtaTimings? = nil, log: @escaping (String) -> Void = { _ in },
         preflight: (@MainActor () async -> String?)? = nil) {
        self.link = link
        self.timings = timings ?? OtaTimings()
        self.log = log
        self.preflight = preflight
    }

    /// Ask to stop. Honoured only before the first block; returns whether it will be.
    @discardableResult
    func cancel() -> Bool {
        if started { return false }
        cancelRequested = true
        return true
    }

    private enum Abort: Error {
        case stop(InstallState)
        case drop
    }

    func install(image: Data, targetVersion: String, onState: @escaping (InstallState) -> Void) async -> InstallState {
        precondition(!image.isEmpty, "empty image")
        link.setListener { [inbox] event in inbox.push(event) }
        defer { link.setListener(nil) }
        let result = await run(image: image, target: targetVersion, onState: onState)
        onState(result)
        return result
    }

    private func run(image: Data, target: String, onState: @escaping (InstallState) -> Void) async -> InstallState {
        let total = image.count
        let prefix = AbOta.md5Prefix(image)
        var reconnects = 0
        var sent = 0
        while true {
            do {
                if !link.isConnected { throw Abort.drop }
                onState(.preparing(resuming: reconnects > 0))
                try await transfer(image: image, prefix: prefix, total: total, onState: onState) { sent = $0 }
                break
            } catch Abort.drop {
                if cancelRequested, !started { return .failed(.cancelled) }
                if reconnects >= timings.maxReconnects {
                    log("OTA: link lost, \(reconnects) reconnects used — giving up")
                    return .failed(.linkLost)
                }
                reconnects += 1
                log("OTA: link lost — reconnect \(reconnects)/\(timings.maxReconnects)")
                onState(.reconnecting(attempt: reconnects, maxAttempts: timings.maxReconnects, sent: sent, total: total))
                if !(await link.reconnect(timeout: timings.reconnectTimeout)) {
                    if reconnects >= timings.maxReconnects { return .failed(.linkLost) }
                    // A failed attempt still counts; the loop tries again (isConnected is false → drop).
                }
            } catch let Abort.stop(state) {
                return state
            } catch {
                return .failed(.deviceError)
            }
        }
        return await verify(target: target, onState: onState)
    }

    /// One connection's worth: identify → info → version → update query → blocks until `90 ff`.
    private func transfer(image: Data, prefix: Data, total: Int, onState: @escaping (InstallState) -> Void,
                          onSent: (Int) -> Void) async throws {
        inbox.drain()
        guard let channel = await link.openChannel() else { throw Abort.stop(.failed(.noChannel)) }
        var seq = 0
        try send(AbOta.identify)
        try? await Task.sleep(nanoseconds: UInt64(timings.identifySettle * 1_000_000_000))
        try send(AbOta.getAllInfo(seq: seq)); seq += 1
        _ = try await awaitReply(timings.replyTimeout) { if case .info = $0 { return true }; return false }
        try checkCancel()

        var (reply, nextSeq) = try await queryStart(prefix: prefix, seq: seq)
        seq = nextSeq
        var packet = try effectivePacket(reply, channelMax: channel)
        var block = reply.blockSize > 0 ? reply.blockSize : AbOta.defaultBlockSize
        var offset = reply.start
        if offset > image.count {
            log("OTA: ring start \(offset) is past the image (\(image.count)) — starting over at 0")
            offset = 0
        }
        let blocks = (image.count + block - 1) / block
        onSent(offset)
        if offset > 0 { log("OTA: resuming at \(offset)") }
        try checkCancel()

        while true {
            if offset >= image.count {
                // Everything is on the ring but no `ff` yet (e.g. resumed exactly at the end): ask once more.
                let code = try await awaitStatus(timings.blockAckTimeout)
                if code == AbOta.statusDone { return }
                try handleFailureCode(code)
            }
            let b = AbOta.blockFrames(seq: seq, image: image, start: offset, blockSize: block, packetSize: packet)
            if !started {
                try checkCancel()
                if !preflightDone {
                    preflightDone = true
                    if let reason = await preflight?() {
                        log("OTA: preflight blocked the first block — \(reason)")
                        throw Abort.stop(.failed(.blocked, detail: reason))
                    }
                }
            }
            started = true
            for frame in b.frames { try send(frame) }
            seq = b.nextSeq & 0xFF
            var code = try await awaitStatus(timings.blockAckTimeout)
            if code == AbOta.statusPause {
                onState(.paused(sent: offset + b.length, total: total))
                log("OTA: ring paused at \(offset + b.length)")
                code = try await awaitStatus(timings.stallTimeout)
            }
            switch code {
            case AbOta.statusOK?:
                offset += b.length
                onSent(offset)
                onState(.transferring(sent: offset, total: total, block: min(offset / block, blocks), blocks: blocks))
            case AbOta.statusDone?:
                onSent(total)
                onState(.transferring(sent: total, total: total, block: blocks, blocks: blocks))
                return
            case AbOta.statusContinue?:
                // Continue/resume: start again at "get version"; the ring says where.
                log("OTA: ring said continue — re-querying the start address")
                (reply, nextSeq) = try await queryStart(prefix: prefix, seq: seq)
                seq = nextSeq
                packet = try effectivePacket(reply, channelMax: channel)
                block = reply.blockSize > 0 ? reply.blockSize : block
                offset = min(reply.start, image.count)
                onSent(offset)
                onState(.transferring(sent: offset, total: total, block: min(offset / block, blocks), blocks: blocks))
            default:
                try handleFailureCode(code)
            }
        }
    }

    private struct UpdateReply {
        let start: Int
        let blockSize: Int
        let packetSize: Int
    }

    /// `91 01` then `91 02`; returns the update reply and the next seq. Fails on `allowed = 0`.
    private func queryStart(prefix: Data, seq seqIn: Int) async throws -> (UpdateReply, Int) {
        var seq = seqIn
        try send(AbOta.getVersion(seq: seq & 0xFF)); seq += 1
        _ = try await awaitReply(timings.replyTimeout) { if case .version = $0 { return true }; return false }
        try send(AbOta.updateQuery(seq: seq & 0xFF, md5Prefix: prefix)); seq += 1
        let reply = try await awaitReply(timings.replyTimeout) { if case .update = $0 { return true }; return false }
        guard case let .update(_, start, blockSize, packetSize, allowed) = reply else {
            throw Abort.stop(.failed(.timeout))
        }
        log("OTA: update reply start=\(start) block=\(blockSize) packet=\(packetSize) allowed=\(allowed)")
        if !allowed { throw Abort.stop(.failed(.refused)) }
        return (UpdateReply(start: start, blockSize: blockSize, packetSize: packetSize), seq & 0xFF)
    }

    /// Never larger than the ring's packet size or the link's own limit.
    private func effectivePacket(_ reply: UpdateReply, channelMax: Int) throws -> Int {
        let granted = reply.packetSize > 0 ? reply.packetSize : AbOta.defaultPacketSize
        let packet = min(granted, channelMax)
        if packet <= AbOta.blockHeaderSize {
            throw Abort.stop(.failed(.noChannel, detail: "The link to the ring is too small for an update (\(packet) B)."))
        }
        return packet
    }

    private func handleFailureCode(_ code: Int?) throws -> Never {
        let failure: InstallFailure?
        switch code {
        case nil: failure = .timeout
        case AbOta.statusSameFirmware?: failure = .sameFirmware
        case AbOta.statusWrongKey?: failure = .wrongKey
        case AbOta.statusWrongCRC?: failure = .wrongCRC
        default: failure = nil
        }
        if let failure { throw Abort.stop(.failed(failure)) }
        throw Abort.stop(.failed(.deviceError, detail: String(
            format: "The ring reported update error %02x. Try again from this screen.", code ?? 0)))
    }

    /// After `90 ff`: the ring restarts; reconnect and require its `a1` to report `target`.
    private func verify(target: String, onState: (InstallState) -> Void) async -> InstallState {
        onState(.verifying(target: target))
        if link.isConnected, !(await link.awaitDisconnect(timeout: timings.rebootDropTimeout)) {
            log("OTA: the ring didn't drop the link after the transfer — checking its version on this link")
        }
        if !link.isConnected, !(await link.reconnect(timeout: timings.rebootReconnectTimeout)) {
            return .failed(.notConfirmed)
        }
        guard let version = await link.awaitFirmwareVersion(timeout: timings.versionTimeout) else {
            return .failed(.notConfirmed)
        }
        log("OTA: after restart the ring reports \(version) (target \(target))")
        if FirmwareUpdateLogic.sameVersion(version, target) { return .succeeded(version: version) }
        return .failed(.versionMismatch,
                       detail: "The ring restarted but reports \(version), not \(target), so the update didn't take.")
    }

    // MARK: plumbing

    private func checkCancel() throws {
        if cancelRequested, !started { throw Abort.stop(.failed(.cancelled)) }
    }

    private func send(_ frame: Data) throws {
        guard link.isConnected else { throw Abort.drop }
        link.write(frame)
    }

    /// The next status code, or nil on timeout. A drop throws.
    private func awaitStatus(_ timeout: TimeInterval) async throws -> Int? {
        let reply = try await awaitReplyOrNil(timeout) { if case .status = $0 { return true }; return false }
        if case let .status(_, code)? = reply { return code }
        return nil
    }

    private func awaitReply(_ timeout: TimeInterval, _ match: (AbOta.Reply) -> Bool) async throws -> AbOta.Reply {
        guard let reply = try await awaitReplyOrNil(timeout, match) else { throw Abort.stop(.failed(.timeout)) }
        return reply
    }

    private func awaitReplyOrNil(_ timeout: TimeInterval, _ match: (AbOta.Reply) -> Bool) async throws -> AbOta.Reply? {
        let deadline = Date().addingTimeInterval(timeout)
        var dropped = false
        var reply: AbOta.Reply?
        loop: while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let event = await inbox.next(timeout: remaining) else { break }
            switch event {
            case .dropped:
                dropped = true
                break loop
            case let .notify(frame):
                guard let parsed = AbOta.parse(frame) else { continue }
                if match(parsed) { reply = parsed; break loop }
            }
        }
        if dropped || (reply == nil && !link.isConnected) { throw Abort.drop }
        return reply
    }
}
