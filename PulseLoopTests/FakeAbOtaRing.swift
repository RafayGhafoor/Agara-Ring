import Foundation
import CryptoKit
@testable import PulseLoop

/// A line-for-line Swift port of the ring emulator's `AbOtaRing` (`ring-emulator/emulator/ota.py`) — the same
/// port Android's tests use (`FakeAbOtaRing.kt`) — so the installer's state machine is tested against the ring
/// behaviour the emulator gives the app: identify gate, info/version/update replies, per-block acks, resume
/// from the kept bytes after a drop, `--ota-reject same|key|crc`, `--ota-fail-at`, `--ota-pause-at`, and the
/// version change after `90 ff`.
final class FakeAbOtaRing {
    enum Event {
        case notify(Data)
        case drop
        case reboot
        case later(TimeInterval, Data)
    }

    var firmware: String
    private let image: Data
    private let newVersion: String
    private let blockSize: Int
    var packetSize: Int
    private let reject: String?
    private var failAt: Double?
    private var pauseAt: Double?
    let pause: TimeInterval
    /// Test knob the emulator lacks: grant `allowed = 0` in the update reply.
    private let refuse: Bool

    private let imagePrefix: Data
    private var installedPrefix: Data?
    private var stagedPrefix: Data?
    private(set) var staged = Data()
    private(set) var updates = 0

    private var identified = false
    private var accepting = false
    private var blockStart = 0
    private var blockLen = 0
    private var block: Data?
    private var prefix: Data?

    /// Every frame the app wrote, for byte-level assertions.
    private(set) var received: [Data] = []

    init(firmware: String, image: Data, newVersion: String = "00.12.10", blockSize: Int = 4096, packetSize: Int = 240,
         reject: String? = nil, failAt: Double? = nil, pauseAt: Double? = nil, pause: TimeInterval = 0.05,
         refuse: Bool = false) {
        self.firmware = firmware
        self.image = image
        self.newVersion = newVersion
        self.blockSize = blockSize
        self.packetSize = packetSize
        self.reject = reject
        self.failAt = failAt
        self.pauseAt = pauseAt
        self.pause = pause
        self.refuse = refuse
        imagePrefix = Self.md5(image).prefix(4)
        disconnected()
    }

    func disconnected() {
        identified = false
        accepting = false
        blockStart = 0
        blockLen = 0
        block = nil
        prefix = nil
    }

    private var total: Int { image.count }
    func progress() -> Double { Double(staged.count + (block?.count ?? 0)) * 100 / Double(total) }

    func handle(_ frame: Data) -> [Event] {
        received.append(frame)
        if frame == AbOta.identify { identified = true; return [] }
        let b = [UInt8](frame)
        guard identified, b.count >= 2 else { return [] }
        let cmd = b[0], seq = Int(b[1])
        switch cmd {
        case 0x92:
            let requested = stride(from: 2, to: b.count - 1, by: 2).map { Int(b[$0]) }
            return [.notify(Self.infoReply(seq: seq, requested: requested, version: firmware))]
        case 0x91 where b.count >= 3 && b[2] == 0x01:
            return [.notify(Self.versionReply(seq: seq, version: firmware))]
        case 0x91 where b.count >= 9 && b[2] == 0x02:
            return updateQuery(seq: seq, prefix: Data(b[5..<9]))
        case 0xA0 where b.count >= 10:
            return blockStartFrame(seq: seq, b)
        case 0x20:
            return dataFrame(seq: seq, Data(b[2...]))
        default:
            return []
        }
    }

    private func updateQuery(seq: Int, prefix p: Data) -> [Event] {
        if stagedPrefix != p {
            staged = Data()
            stagedPrefix = p
        }
        prefix = p
        accepting = true
        return [.notify(Self.updateReply(seq: seq, start: staged.count, block: blockSize, packet: packetSize, allowed: !refuse))]
    }

    private func blockStartFrame(seq: Int, _ b: [UInt8]) -> [Event] {
        guard accepting else { return [] }
        let start = Self.u32(b, 2), length = Self.u32(b, 6)
        if start > staged.count || length == 0 || length > blockSize { return fail(seq, AbOta.statusWrongCRC) }
        staged = staged.prefix(start)
        blockStart = start
        blockLen = length
        block = Data()
        return dataFrame(seq: seq, Data(b[10...]))
    }

    private func dataFrame(seq: Int, _ data: Data) -> [Event] {
        guard block != nil else { return [] }
        block!.append(data)
        if block!.count > blockLen { return fail(seq, AbOta.statusWrongCRC) }
        if let f = failAt, progress() >= f {
            failAt = nil
            disconnected()
            return [.drop]
        }
        if block!.count < blockLen { return [] }
        return blockComplete(seq: seq)
    }

    private func blockComplete(seq: Int) -> [Event] {
        let data = block!
        block = nil
        if blockStart == 0 {
            if reject == "same" || (reject == nil && installedPrefix == prefix) { return fail(seq, AbOta.statusSameFirmware) }
            if reject == "key" || (reject == nil && prefix != imagePrefix) { return fail(seq, AbOta.statusWrongKey) }
        }
        staged.append(data)
        let progress = progress()
        if staged.count >= total {
            if reject == "crc" || staged != image { return fail(seq, AbOta.statusWrongCRC) }
            firmware = newVersion
            installedPrefix = prefix
            staged = Data(); stagedPrefix = nil; accepting = false
            updates += 1
            return [.notify(Self.status(seq, AbOta.statusDone)), .reboot]
        }
        if let p = pauseAt, progress >= p {
            pauseAt = nil
            return [.notify(Self.status(seq, AbOta.statusPause)), .later(pause, Self.status(seq, AbOta.statusContinue))]
        }
        return [.notify(Self.status(seq, AbOta.statusOK))]
    }

    private func fail(_ seq: Int, _ code: Int) -> [Event] {
        staged = Data(); stagedPrefix = nil; accepting = false; block = nil
        return [.notify(Self.status(seq, code))]
    }

    // MARK: frames (emulator `ota.py`)

    static func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }

    static func versionU16(_ v: String) -> Int {
        let p = v.split(separator: ".").map { Int($0, radix: 16) ?? 0 }
        return (p[1] << 8) | p[2]
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    static func infoReply(seq: Int, requested: [Int], version: String) -> Data {
        let tlvs: [Int: [UInt8]] = [
            1: [1, 2] + le16(versionU16(version)),
            3: [3, 2, 0, 0],
            4: [4, 2, 0, 0],
            6: [6, 1, 0],
        ]
        return Data([0x92, UInt8(seq & 0xFF)] + requested.compactMap { tlvs[$0] }.flatMap { $0 })
    }

    static func versionReply(seq: Int, version: String) -> Data {
        Data([0x91, UInt8(seq & 0xFF), 1] + le16(versionU16(version)))
    }

    static func updateReply(seq: Int, start: Int, block: Int, packet: Int, allowed: Bool) -> Data {
        Data([0x91, UInt8(seq & 0xFF), 2] + le32(start) + le32(block) + le16(packet) + [allowed ? 1 : 0])
    }

    static func status(_ seq: Int, _ code: Int) -> Data { Data([0x90, UInt8(seq & 0xFF), UInt8(code & 0xFF)]) }
}
