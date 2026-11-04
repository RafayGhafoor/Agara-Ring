import XCTest
import CryptoKit
@testable import PulseLoop

private func hex(_ h: String) -> Data {
    var data = Data()
    var i = h.startIndex
    while i < h.endIndex {
        let n = h.index(i, offsetBy: 2)
        data.append(UInt8(h[i..<n], radix: 16)!)
        i = n
    }
    return data
}

private func md5Hex(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// Frame builders and reply parsers byte-for-byte against the ring emulator (`ring-emulator/emulator/ota.py`
/// and `tests/test_ota.py`). Every expected hex string was printed by the emulator's own functions; the same
/// fixtures as Android `AbOtaTest`.
@MainActor
final class AbOtaTests: XCTestCase {
    /// `bytes((i*7+3) & 0xff for i in range(5000))` — the fixture image the hashes below were made from.
    private let image = Data((0..<5000).map { UInt8(($0 * 7 + 3) & 0xFF) })

    func testIdentifyIsExactlyTheVendorMagic() {
        XCTAssertEqual(AbOta.hex(AbOta.identify), "ccaa55ee1219e4")
    }

    func testGetAllInfoGetVersionAndUpdateQueryMatchTheEmulator() {
        XCTAssertEqual(AbOta.hex(AbOta.getAllInfo(seq: 0)), "92000100030004000600")
        XCTAssertEqual(AbOta.hex(AbOta.getVersion(seq: 1)), "910101")
        XCTAssertEqual(md5Hex(image), "33d9712cc5eb0bf18a41ed54a908e412")
        // app_update_query(2, image)
        XCTAssertEqual(AbOta.hex(AbOta.updateQuery(seq: 2, md5Prefix: AbOta.md5Prefix(image))), "910202ffff33d9712c")
        // seq wraps as a u8
        XCTAssertEqual(AbOta.hex(AbOta.getAllInfo(seq: 257)), "92010100030004000600")
    }

    func testBlockFramesAtStartZeroMatchAppBlockFrames() {
        let b = AbOta.blockFrames(seq: 3, image: image, start: 0, blockSize: 4096, packetSize: 240)
        XCTAssertEqual(b.frames.count, 18)
        XCTAssertEqual(b.nextSeq, 21)
        XCTAssertEqual(b.length, 4096)
        XCTAssertEqual(AbOta.hex(b.frames[0].prefix(16)), "a0030000000000100000030a11181f26")
        XCTAssertEqual(AbOta.hex(b.frames[1].prefix(6)), "20044d545b62")
        XCTAssertEqual(b.frames.prefix(3).map(\.count), [240, 240, 240])
        XCTAssertEqual(b.frames.last?.count, 60)
        XCTAssertTrue(AbOta.hex(b.frames.last!).hasPrefix("20146d747b828990979e"))
        XCTAssertEqual(md5Hex(b.frames.reduce(Data(), +)), "4e6757445b7f2ea88ae9b16f9dcf7b2d")
        XCTAssertTrue(b.frames.allSatisfy { $0.count <= 240 })
    }

    func testTheShortLastBlockMatchesToo() {
        let b = AbOta.blockFrames(seq: 21, image: image, start: 4096, blockSize: 4096, packetSize: 240)
        XCTAssertEqual(b.frames.map(\.count), [240, 240, 240, 200])
        XCTAssertEqual(b.nextSeq, 25)
        XCTAssertEqual(b.length, 904)
        XCTAssertTrue(AbOta.hex(b.frames[0]).hasPrefix("a0150010000088030000030a11181f"))
        XCTAssertEqual(md5Hex(b.frames.reduce(Data(), +)), "1700c4b61475ba06177e76f065dfa8b8")
    }

    func testATwentyBytePacketChunksLikeTheEmulatorAndWrapsSeq() {
        let b = AbOta.blockFrames(seq: 250, image: image, start: 0, blockSize: 4096, packetSize: 20)
        XCTAssertEqual(b.frames.count, 228)
        XCTAssertEqual(b.nextSeq & 0xFF, 478 & 0xFF)
        XCTAssertEqual(AbOta.hex(b.frames[0]), "a0fa0000000000100000030a11181f262d343b42")
        XCTAssertEqual(AbOta.hex(b.frames[1]), "20fb4950575e656c737a81888f969da4abb2b9c0")
        XCTAssertEqual(md5Hex(b.frames.reduce(Data(), +)), "6cd9f924e103bfe7afc77fe57509d8f4")
    }

    func testDataReassemblesToTheImage() {
        var offset = 0, seq = 0
        var out = Data()
        while offset < image.count {
            let b = AbOta.blockFrames(seq: seq, image: image, start: offset, blockSize: 4096, packetSize: 100)
            out.append(b.frames[0].dropFirst(10))
            for f in b.frames.dropFirst() { out.append(f.dropFirst(2)) }
            offset += b.length
            seq = b.nextSeq
        }
        XCTAssertEqual(out, image)
    }

    func testParsesTheEmulatorsReplies() {
        // info_reply(0, [1,3,4,6], "00.12.07")
        XCTAssertEqual(AbOta.parse(hex("9200010207120302000004020000060100")), .info(seq: 0, version: 0x1207, tws: false))
        // version_reply(1, "00.12.07")
        XCTAssertEqual(AbOta.parse(hex("9101010712")), .version(seq: 1, version: 0x1207))
        // update_reply(2, 8192, 4096, 240, True) / allowed False
        XCTAssertEqual(AbOta.parse(hex("9102020020000000100000f00001")),
                       .update(seq: 2, start: 8192, blockSize: 4096, packetSize: 240, allowed: true))
        XCTAssertEqual(AbOta.parse(hex("9102020000000000100000f00000")),
                       .update(seq: 2, start: 0, blockSize: 4096, packetSize: 240, allowed: false))
        // status(7, 0xff), status(300, 0x0b)
        XCTAssertEqual(AbOta.parse(hex("9007ff")), .status(seq: 7, code: 0xFF))
        XCTAssertEqual(AbOta.parse(hex("902c0b")), .status(seq: 0x2C, code: 0x0B))
        XCTAssertEqual(AbOta.parse(hex("9101010912")), .version(seq: 1, version: 0x1209))
    }

    func testTruncatedOrForeignFramesParseToNil() {
        XCTAssertNil(AbOta.parse(hex("90")))
        XCTAssertNil(AbOta.parse(hex("9102020000")))
        XCTAssertNil(AbOta.parse(hex("a1000000")))
    }

    func testTheLogKeepsHeadersOffsetsAndStatusesNeverPayloads() {
        let b = AbOta.blockFrames(seq: 3, image: image, start: 4096, blockSize: 4096, packetSize: 240)
        XCTAssertEqual(AbOta.hex(AbOta.logBytes(b.frames[0], outgoing: true)), "a0030010000088030000")
        XCTAssertEqual(AbOta.logBytes(b.frames[1], outgoing: true).count, 2)
        XCTAssertEqual(AbOta.hex(AbOta.logBytes(AbOta.identify, outgoing: true)), "ccaa55ee1219e4")
        XCTAssertEqual(AbOta.hex(AbOta.logBytes(AbOta.updateQuery(seq: 2, md5Prefix: AbOta.md5Prefix(image)), outgoing: true)),
                       "910202ffff33d9712c")
        XCTAssertEqual(AbOta.summary(b.frames[0], outgoing: true), "a0 #3 start=4096 len=904 (+230 B)")
        XCTAssertEqual(AbOta.summary(b.frames[1], outgoing: true), "20 #4 (+238 B)")
        XCTAssertEqual(AbOta.summary(hex("9007ff"), outgoing: false), "90 #7 status=ff done")
        XCTAssertEqual(AbOta.summary(hex("902c0b"), outgoing: false), "90 #44 status=0b wrong crc")
        XCTAssertEqual(AbOta.summary(hex("9102020020000000100000f00001"), outgoing: false),
                       "91 #2 update start=8192 block=4096 packet=240 allowed=true")
        XCTAssertEqual(AbOta.summary(AbOta.identify, outgoing: true), "identify")
    }

    /// The fake ring the installer tests use speaks exactly what the emulator's `ota.py` replies.
    func testFakeRingRepliesMatchTheEmulator() {
        XCTAssertEqual(AbOta.hex(FakeAbOtaRing.infoReply(seq: 0, requested: [1, 3, 4, 6], version: "00.12.07")),
                       "9200010207120302000004020000060100")
        XCTAssertEqual(AbOta.hex(FakeAbOtaRing.updateReply(seq: 2, start: 8192, block: 4096, packet: 240, allowed: true)),
                       "9102020020000000100000f00001")
    }
}

/// The install state machine against `FakeAbOtaRing` (a port of the emulator's ring) over a scripted link:
/// clean install, resume after drops at 10/50/99 %, each rejection, pause/continue, timeouts, the post-restart
/// version check, cancel and the preflight gate. Same cases as Android `AbOtaInstallerTest`; timeouts are
/// scaled down so they cost milliseconds.
@MainActor
final class AbOtaInstallerTests: XCTestCase {
    /// 32 whole blocks + 1000 B, like the emulator's dummy image, so the short last block is exercised.
    private let image = Data((0..<(32 * 4096 + 1000)).map { UInt8(truncatingIfNeeded: ($0 * 31 + 7) ^ ($0 >> 8)) })

    private static let fast = OtaTimings(replyTimeout: 0.3, blockAckTimeout: 0.3, stallTimeout: 0.6, identifySettle: 0,
                                         reconnectTimeout: 0.4, maxReconnects: 3, rebootDropTimeout: 0.3,
                                         rebootReconnectTimeout: 0.4, versionTimeout: 0.3)

    final class FakeLink: OtaLink {
        let ring: FakeAbOtaRing
        var channelMax: Int? = 512 - 3
        private var listener: ((OtaLinkEvent) -> Void)?
        var connected = true
        var reconnects = 0
        /// Reconnect attempts that fail before one succeeds (Int.max: never comes back).
        var failingReconnects = 0
        /// Stop answering after this many status notifications (a ring that goes silent).
        var muteAfterStatuses: Int?
        private var statuses = 0
        /// What `a1` reports after the post-update restart, instead of the ring's own firmware.
        var versionAfterRestart: String?
        /// The restarted ring never comes back.
        var neverReturnsAfterRestart = false
        /// Nothing reaches the ring.
        var silent = false
        private var restarted = false
        private(set) var written: [Data] = []
        private(set) var sessions: [[Data]] = [[]]

        init(ring: FakeAbOtaRing) { self.ring = ring }

        func setListener(_ listener: ((OtaLinkEvent) -> Void)?) { self.listener = listener }
        var isConnected: Bool { connected }
        func openChannel() async -> Int? { channelMax }

        func write(_ frame: Data) {
            guard connected, !silent else { return }
            written.append(frame)
            sessions[sessions.count - 1].append(frame)
            for event in ring.handle(frame) {
                switch event {
                case let .notify(f): deliver(f)
                case .drop: drop()
                case .reboot: restarted = true; drop()
                case let .later(delay, f):
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if self?.connected == true { self?.deliver(f) }
                    }
                }
            }
        }

        private func deliver(_ frame: Data) {
            if frame.first == 0x90 {
                if let limit = muteAfterStatuses, statuses >= limit { return }
                statuses += 1
            }
            listener?(.notify(frame))
        }

        private func drop() {
            connected = false
            ring.disconnected()
            listener?(.dropped)
        }

        func reconnect(timeout: TimeInterval) async -> Bool {
            reconnects += 1
            if failingReconnects > 0 || (restarted && neverReturnsAfterRestart) {
                failingReconnects -= 1
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            connected = true
            sessions.append([])
            return true
        }

        func awaitDisconnect(timeout: TimeInterval) async -> Bool {
            if !connected { return true }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return !connected
        }

        func awaitFirmwareVersion(timeout: TimeInterval) async -> String? {
            restarted ? (versionAfterRestart ?? ring.firmware) : ring.firmware
        }
    }

    private struct Run {
        let result: InstallState
        let states: [InstallState]
        let link: FakeLink
    }

    private func install(_ ring: FakeAbOtaRing, target: String = "00.12.10", image img: Data? = nil,
                         configure: (FakeLink) -> Void = { _ in }, preflight: (@MainActor () async -> String?)? = nil,
                         onState: ((AbOtaInstaller, InstallState) -> Void)? = nil) async -> Run {
        let link = FakeLink(ring: ring)
        configure(link)
        var states: [InstallState] = []
        let installer = AbOtaInstaller(link: link, timings: Self.fast, preflight: preflight)
        let result = await installer.install(image: img ?? image, targetVersion: target) { s in
            states.append(s)
            onState?(installer, s)
        }
        return Run(result: result, states: states, link: link)
    }

    private func ring(firmware: String = "00.12.07", image img: Data? = nil, reject: String? = nil, failAt: Double? = nil,
                      pauseAt: Double? = nil, pause: TimeInterval = 0.05, refuse: Bool = false,
                      packetSize: Int = 240) -> FakeAbOtaRing {
        FakeAbOtaRing(firmware: firmware, image: img ?? image, packetSize: packetSize, reject: reject, failAt: failAt,
                      pauseAt: pauseAt, pause: pause, refuse: refuse)
    }

    private func blockStarts(_ frames: [Data]) -> [Int] {
        frames.filter { $0.first == 0xA0 }.map { f in
            let b = [UInt8](f)
            return Int(b[2]) | (Int(b[3]) << 8) | (Int(b[4]) << 16) | (Int(b[5]) << 24)
        }
    }

    // MARK: clean

    func testCleanInstallSendsTheHandshakeEveryBlockAndSucceedsOnTheNewVersion() async {
        let r = ring()
        let run = await install(r)
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
        XCTAssertEqual(r.updates, 1)
        let w = run.link.written
        XCTAssertEqual(w[0], AbOta.identify)
        XCTAssertEqual(AbOta.hex(w[1]), "92000100030004000600")
        XCTAssertEqual(AbOta.hex(w[2]), "910101")
        XCTAssertEqual(w[3], AbOta.updateQuery(seq: 2, md5Prefix: AbOta.md5Prefix(image)))
        // Blocks exactly as app_block_frames builds them, seq continuing from 3.
        var seq = 3, offset = 0, i = 4
        while offset < image.count {
            let b = AbOta.blockFrames(seq: seq, image: image, start: offset, blockSize: 4096, packetSize: 240)
            for f in b.frames { XCTAssertEqual(f, w[i]); i += 1 }
            seq = b.nextSeq & 0xFF
            offset += b.length
        }
        XCTAssertEqual(w.count, i)
        XCTAssertEqual(blockStarts(w).count, 33)
        XCTAssertTrue(run.states.contains { if case .transferring = $0 { return $0.percent == 100 }; return false })
        XCTAssertTrue(run.states.contains(.verifying(target: "00.12.10")))
        XCTAssertTrue(run.states.contains(.transferring(sent: 16 * 4096, total: image.count, block: 16, blocks: 33)))
        XCTAssertEqual(run.link.reconnects, 1, "one reconnect: after the restart")
    }

    func testFramesNeverExceedTheLinkLimitEvenWhenTheRingGrantsMore() async {
        let run = await install(ring(packetSize: 240), configure: { $0.channelMax = 20 })
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
        XCTAssertTrue(run.link.written.allSatisfy { $0.count <= 20 })
    }

    // MARK: resume

    func testADropAt10_50Or99PercentReconnectsAndResumesFromTheRingsStartAddress() async {
        for at in [10.0, 50.0, 99.0] {
            let r = ring(failAt: at)
            let run = await install(r)
            XCTAssertEqual(run.result, .succeeded(version: "00.12.10"), "drop at \(at)")
            XCTAssertEqual(r.updates, 1, "drop at \(at): CRC matched")
            // Session 2 (after the drop) restarts at identify and its first block starts at the kept offset.
            let second = run.link.sessions[1]
            XCTAssertEqual(second[0], AbOta.identify)
            XCTAssertEqual(AbOta.hex(second[1]), "92000100030004000600", "drop at \(at): seq restarts")
            let resumedAt = blockStarts(second).first
            let droppedIn = blockStarts(run.link.sessions[0]).last
            XCTAssertEqual(resumedAt, droppedIn, "drop at \(at): resumes at the unfinished block")
            XCTAssertTrue((resumedAt ?? 0) > 0 && (resumedAt ?? 1) % 4096 == 0, "drop at \(at)")
            XCTAssertTrue(run.states.contains { if case .reconnecting(1, _, _, _) = $0 { return true }; return false })
            XCTAssertTrue(run.states.contains(.preparing(resuming: true)))
        }
    }

    func testTheLinkLostMoreThanThreeTimesFailsRetryably() async {
        let run = await install(ring(failAt: 30), configure: { $0.failingReconnects = .max })
        XCTAssertEqual(run.result.failure, .linkLost)
        XCTAssertTrue(InstallFailure.linkLost.retryable)
        XCTAssertEqual(run.link.reconnects, 3)
    }

    func testTwoFailedReconnectsThenSuccessStillResumes() async {
        let run = await install(ring(failAt: 50), configure: { $0.failingReconnects = 2 })
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
        XCTAssertEqual(run.link.reconnects, 4, "3 for the drop (2 failed) + 1 after the restart")
    }

    // MARK: rejections

    func testSameFirmwareWrongKeyAndWrongCRCMapToTheirFailures() async {
        for (reject, failure) in [("same", InstallFailure.sameFirmware), ("key", .wrongKey), ("crc", .wrongCRC)] {
            let r = ring(reject: reject)
            let run = await install(r)
            XCTAssertEqual(run.result.failure, failure, reject)
            XCTAssertEqual(r.firmware, "00.12.07", reject)
            XCTAssertEqual(run.link.reconnects, 0, reject)
            if reject != "crc" { XCTAssertEqual(blockStarts(run.link.written).count, 1, "\(reject) is judged on the first block") }
        }
        XCTAssertFalse(InstallFailure.sameFirmware.retryable)
        XCTAssertFalse(InstallFailure.wrongKey.retryable)
        XCTAssertTrue(InstallFailure.wrongCRC.retryable)
    }

    func testAnImageTheRingDoesntKnowIsAWrongKey() async {
        var other = image
        other[5] = other[5] &+ 1
        let run = await install(ring(), image: other)
        XCTAssertEqual(run.result.failure, .wrongKey)
    }

    func testInstallingTheSameImageTwiceGetsSameFirmware() async {
        let r = ring()
        let first = await install(r)
        XCTAssertEqual(first.result, .succeeded(version: "00.12.10"))
        let again = await install(r)
        XCTAssertEqual(again.result.failure, .sameFirmware)
    }

    func testARingThatRefusesTheUpdateQueryFailsWithoutSendingABlock() async {
        let run = await install(ring(refuse: true))
        XCTAssertEqual(run.result.failure, .refused)
        XCTAssertTrue(blockStarts(run.link.written).isEmpty)
    }

    // MARK: pause / timeout

    func testPauseWaitsForContinueRequeriesFromGetVersionAndFinishes() async {
        let run = await install(ring(pauseAt: 25))
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
        XCTAssertTrue(run.states.contains { if case .paused = $0 { return true }; return false })
        // fe → "get version" then the update query again, on the same link.
        XCTAssertEqual(run.link.written.filter { $0.count >= 3 && $0[0] == 0x91 && $0[2] == 0x01 }.count, 2)
        XCTAssertEqual(run.link.written.filter { $0.count >= 3 && $0[0] == 0x91 && $0[2] == 0x02 }.count, 2)
        XCTAssertEqual(run.link.reconnects, 1)
    }

    func testARingThatStopsAckingTimesOut() async {
        let started = Date()
        let run = await install(ring(), configure: { $0.muteAfterStatuses = 5 })
        XCTAssertEqual(run.result.failure, .timeout)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), Self.fast.blockAckTimeout)
    }

    func testAPauseThatNeverContinuesTimesOutAfterTheStallLimit() async {
        let run = await install(ring(pauseAt: 25, pause: 60))
        XCTAssertEqual(run.result.failure, .timeout)
    }

    func testNoReplyToTheHandshakeTimesOut() async {
        let run = await install(ring(), configure: { $0.silent = true })
        XCTAssertEqual(run.result.failure, .timeout)
    }

    // MARK: after the restart

    func testSuccessOnlyWhenTheRestartedRingReportsTheTargetVersion() async {
        let run = await install(ring(), configure: { $0.versionAfterRestart = "00.12.07" })
        XCTAssertEqual(run.result.failure, .versionMismatch)
        let message = run.result.failureMessage ?? ""
        XCTAssertTrue(message.contains("00.12.07") && message.contains("00.12.10"), message)
    }

    func testTheTargetMatchesAcrossVersionSpellings() async {
        let run = await install(ring(), target: "00.12.10.00")
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
    }

    func testARingThatDoesntComeBackAfterRestartingIsNotConfirmed() async {
        let r = ring()
        let run = await install(r, configure: { $0.neverReturnsAfterRestart = true })
        XCTAssertEqual(r.updates, 1)
        XCTAssertEqual(run.result.failure, .notConfirmed)
    }

    // MARK: cancel, preflight, channel

    func testCancelBeforeTheFirstBlockWritesNothingToFlash() async {
        let run = await install(ring(), onState: { installer, s in
            if case .preparing = s { XCTAssertTrue(installer.cancel()) }
        })
        XCTAssertEqual(run.result.failure, .cancelled)
        XCTAssertTrue(blockStarts(run.link.written).isEmpty)
    }

    func testCancelIsRefusedOnceTheFirstBlockHasGoneOut() async {
        var refused = false
        let run = await install(ring(), onState: { installer, s in
            if case .transferring(_, _, 1, _) = s { refused = !installer.cancel() }
        })
        XCTAssertTrue(refused)
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
    }

    func testThePreflightGateRunsOnceRightBeforeTheFirstBlockAndCanStopIt() async {
        var calls = 0
        var blocksBefore = -1
        var link: FakeLink?
        let run = await install(ring(), configure: { link = $0 }, preflight: {
            calls += 1
            blocksBefore = self.blockStarts(link?.written ?? []).count
            return "Charge the ring to at least 40 % first."
        })
        XCTAssertEqual(run.result.failure, .blocked)
        XCTAssertEqual(run.result.failureMessage, "Charge the ring to at least 40 % first.")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(blocksBefore, 0)
        XCTAssertTrue(blockStarts(run.link.written).isEmpty)
        // The handshake had run (the gate is re-checked after it, just before flashing starts).
        XCTAssertTrue(run.link.written.contains { AbOta.hex($0).hasPrefix("910202") })
    }

    func testAPassingPreflightLetsTheInstallRun() async {
        var calls = 0
        let run = await install(ring(failAt: 50), preflight: { calls += 1; return nil })
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
        XCTAssertEqual(calls, 1, "once, even across the drop")
    }

    func testARingWithoutTheUpdateServiceFailsWithNoChannel() async {
        let run = await install(ring(), configure: { $0.channelMax = nil })
        XCTAssertEqual(run.result.failure, .noChannel)
        XCTAssertTrue(run.link.written.isEmpty)
    }

    func testNotConnectedAtTheStartReconnectsFirst() async {
        let run = await install(ring(), configure: { $0.connected = false })
        XCTAssertEqual(run.result, .succeeded(version: "00.12.10"))
        XCTAssertEqual(run.link.reconnects, 2)
    }

    func testTimingsComeFromTheSharedCatalog() {
        let t = OtaTimings()
        XCTAssertEqual(t.blockAckTimeout, TimeInterval(AgaraConfig.Ring.firmwareBlockAckTimeoutS))
        XCTAssertEqual(t.stallTimeout, TimeInterval(AgaraConfig.Ring.firmwareStallTimeoutS))
        XCTAssertEqual(t.maxReconnects, AgaraConfig.Ring.firmwareMaxReconnects)
        XCTAssertEqual(t.rebootReconnectTimeout, TimeInterval(AgaraConfig.Ring.firmwareRebootTimeoutS))
    }
}

/// Stage 4 gates (plan firmware-update "Gates"), the OTA type from the ring's own `a7`, the install copy and the
/// sync hold. Same cases as Android `FirmwareInstallGatesTest`.
@MainActor
final class FirmwareInstallGatesTests: XCTestCase {
    private let go = FirmwareInstallInputs(
        flagOn: true, fileVerified: true, connected: true, otaType: 3, otaServicePresent: true,
        batteryPercent: 40, minBatteryPercent: 40, syncing: false, measuring: false
    )

    func testAllGatesOpenMeansGo() {
        XCTAssertEqual(FirmwareInstallGates.evaluate(go), [])
    }

    func testEachGateBlocksOnItsOwn() {
        func with(_ change: (inout FirmwareInstallInputs) -> Void) -> FirmwareInstallInputs {
            var i = go
            change(&i)
            return i
        }
        let cases: [(FirmwareInstallInputs, FirmwareInstallGate)] = [
            // No build gate: since 1.1 the install ships to every build (the flag flip removed `debugBuild` from
            // the inputs), so every remaining field is a live ring/app-state gate. Policy: plan firmware-update "1.1".
            (with { $0.flagOn = false }, .flagOff),
            (with { $0.fileVerified = false }, .noVerifiedFile),
            (with { $0.otaType = 5 }, .unsupportedRing),
            (with { $0.otaType = nil }, .unsupportedRing),
            (with { $0.otaServicePresent = false }, .noUpdateChannel),
            (with { $0.batteryPercent = 39 }, .lowBattery),
            (with { $0.batteryPercent = nil }, .batteryUnknown),
            (with { $0.syncing = true }, .syncing),
            (with { $0.measuring = true }, .measuring),
        ]
        for (inputs, gate) in cases { XCTAssertEqual(FirmwareInstallGates.evaluate(inputs), [gate], "\(gate)") }
    }

    func testDisconnectedHidesTheRingStateGates() {
        var i = go
        i.connected = false
        i.batteryPercent = nil
        i.otaServicePresent = false
        XCTAssertEqual(FirmwareInstallGates.evaluate(i), [.notConnected])
    }

    func testTheBatteryGateSaysTheCatalogMinimum() {
        XCTAssertEqual(FirmwareInstallGate.lowBattery.text(minBattery: 40), "Charge the ring to at least 40 % first.")
        var i = go
        i.batteryPercent = 49
        i.minBatteryPercent = 50
        XCTAssertEqual(FirmwareInstallGates.evaluate(i), [.lowBattery])
        XCTAssertEqual(FirmwareInstallController().minBattery, AgaraConfig.Ring.firmwareMinBatteryPercent)
    }

    /// Package 3 exactly as our ring sends it (emulator frames.py / research 05 §2): byte 16 = 03.
    func testTheRingsCapabilityPackage3CarriesOtaType3() {
        let frames = [
            "a701000001020100081400020000000100fe0301",
            "a700030400030000060005010006020005000002",
            "a702000000010000010000000100000403000203",
            "a702000000000000000000000101000000000004",
        ].map { [UInt8](hex($0)) }
        var raw: [Int: [UInt8]] = [:]
        for f in frames { raw[Int(f[19])] = f }
        let caps = RingCapabilities.decode(packages: raw)
        XCTAssertEqual(caps.otaType, 3)
        XCTAssertEqual(RingCapabilities(json: caps.json), caps)
        raw[3] = nil
        XCTAssertNil(RingCapabilities.decode(packages: raw).otaType, "unknown until package 3 arrives")
        // A row stored before the field existed still decodes (otaType unknown).
        var legacy = caps.json
        legacy = legacy.replacingOccurrences(of: #","otaType":3"#, with: "").replacingOccurrences(of: #""otaType":3,"#, with: "")
        XCTAssertFalse(legacy.contains("otaType"))
        XCTAssertNotNil(RingCapabilities(json: legacy))
        XCTAssertNil(RingCapabilities(json: legacy)?.otaType)
    }

    /// The driver's `a7` decode path reaches the client, which the gates read.
    func testTheClientKeepsTheLiveCapabilitiesBatteryAndA1Firmware() {
        let client = RingBLEClient(startManager: false)
        var raw: [Int: [UInt8]] = [:]
        raw[3] = [UInt8](hex("a702000000010000010000000100000403000203"))
        client.emit(.ringCapabilities(RingCapabilities.decode(packages: raw)))
        client.emit(.battery(percent: 77))
        client.emit(.firmware(version: "00.12.09", deviceNumber: 2526, testVersion: "00.12.09.00"))
        XCTAssertEqual(client.ringCapabilities?.otaType, 3)
        XCTAssertEqual(client.ringBatteryPercent, 77)
        XCTAssertEqual(client.firmwareSinceConnect, "00.12.09")
        XCTAssertFalse(client.otaServiceAvailable, "no F003 without a link")
    }

    func testInstallCopySaysAgaraNeverAVendorAndShowsProgress() {
        let body = FirmwareInstallText.confirmBody(version: "00.12.09", minBattery: 40)
        XCTAssertTrue(body.contains("AGARA Heart") && body.contains("00.12.09") && body.contains("40 %"))
        XCTAssertTrue(body.contains("charger") && body.contains("stop working"))
        let t = InstallState.transferring(sent: 66_036, total: 132_072, block: 16, blocks: 33)
        XCTAssertEqual(FirmwareInstallText.headline(t), "Installing · 50 %")
        XCTAssertTrue(FirmwareInstallText.detail(t).hasPrefix("Block 16 of 33"))
        XCTAssertEqual(FirmwareInstallText.fraction(t), 0.5)
        XCTAssertEqual(FirmwareInstallText.headline(.succeeded(version: "00.12.09")), "Updated to 00.12.09")
        XCTAssertEqual(FirmwareInstallText.detail(.failed(.sameFirmware)), InstallFailure.sameFirmware.message)
        XCTAssertEqual(FirmwareInstallText.headline(.reconnecting(attempt: 1, maxAttempts: 3, sent: 1, total: 2)),
                       "Connection lost — reconnecting (1 of 3)")
        XCTAssertNil(FirmwareInstallText.fraction(.verifying(target: "00.12.09")))
        let all = InstallFailure.allCases.map(\.message).joined(separator: " ") + body
            + FirmwareInstallGate.allCases.map { $0.text(minBattery: 40) }.joined(separator: " ")
        for vendor in ["Veepoo", "Bluetrum", "VPH", "vphband", "TK20"] {
            XCTAssertFalse(all.localizedCaseInsensitiveContains(vendor), vendor)
        }
    }

    func testBusyCoversEveryStateWhereTheRingMayBeMidFlash() {
        XCTAssertTrue(InstallState.preparing(resuming: false).busy)
        XCTAssertTrue(InstallState.transferring(sent: 0, total: 1, block: 0, blocks: 1).busy)
        XCTAssertTrue(InstallState.paused(sent: 0, total: 1).busy)
        XCTAssertTrue(InstallState.reconnecting(attempt: 1, maxAttempts: 3, sent: 0, total: 1).busy)
        XCTAssertTrue(InstallState.verifying(target: "x").busy)
        XCTAssertFalse(InstallState.idle.busy)
        XCTAssertFalse(InstallState.succeeded(version: "x").busy)
        XCTAssertFalse(InstallState.failed(.timeout).busy)
    }

    func testTheControllerRefusesWithoutAVerifiedDownload() {
        let controller = FirmwareInstallController(
            checker: FirmwareUpdateChecker(defaults: UserDefaults(suiteName: "FirmwareInstallGatesTests")!,
                                           storageDirectory: FileManager.default.temporaryDirectory
                                               .appendingPathComponent("fw-gates-\(UUID().uuidString)"),
                                           isOn: { _ in true })
        )
        XCTAssertFalse(controller.start())
        XCTAssertEqual(controller.state.failure, .blocked)
        XCTAssertEqual(controller.state.failureMessage, "Download the update first.")
        XCTAssertFalse(controller.cancellable)
        controller.dismiss()
        XCTAssertEqual(controller.state, .idle)
    }
}

/// The sync engine goes quiet while a firmware install holds the ring, and resumes after — Android's
/// `FirmwareUpdateHold` behaviour.
@MainActor
final class FirmwareHoldEngineTests: XCTestCase {
    private final class RecordingWriter: RingCommandWriter {
        var deviceIdentifier: String? { nil }
        var commands: [Data] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func enqueueTracked(_ command: Data, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            commands.append(command)
            completion(.success(()))
        }
        func emit(_ event: RingDecodedEvent) {}
    }

    private var writer = RecordingWriter()

    override func tearDown() {
        FirmwareUpdateHold.active = false
        super.tearDown()
    }

    func testAReconnectDuringTheHoldOnlyAsksForTheBatteryThenResumes() {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 2)
        FirmwareUpdateHold.active = true
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        XCTAssertEqual(writer.commands, [VeepooEncoder.battery()], "only the battery while held")
        XCTAssertFalse(engine.isHistorySyncing)
        engine.pollTickFired()
        engine.pollTickFired()
        engine.syncHistory()
        XCTAssertEqual(writer.commands, [VeepooEncoder.battery()], "no poll, no history pass while held")

        FirmwareUpdateHold.active = false
        engine.resumeAfterFirmwareHold()
        XCTAssertTrue(writer.commands.contains(VeepooEncoder.session()))
        XCTAssertTrue(writer.commands.contains(VeepooEncoder.sleepHistory(dayOffset: 0)))
        XCTAssertTrue(engine.isHistorySyncing)
        engine.connectionDidEnd()
    }

    func testTheHoldSilencesThePollTickOfAnAuthenticatedEngine() {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 2)
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        let before = writer.commands.count
        FirmwareUpdateHold.active = true
        engine.enterFirmwareHold()
        engine.pollTickFired()
        engine.pollTickFired()
        XCTAssertEqual(writer.commands.count, before)
        FirmwareUpdateHold.active = false
        engine.pollTickFired()
        XCTAssertGreaterThan(writer.commands.count, before)
        engine.connectionDidEnd()
    }
}
