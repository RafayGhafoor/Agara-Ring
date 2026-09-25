import Foundation
import CryptoKit

/// The Agara ring's firmware-update protocol on GATT service `F003` (plan firmware-update, stage 4): the
/// app writes every frame **without response** to `F032`, the ring answers on `F031`. Pure — frame builders,
/// reply parsers and a log summary — so every byte is unit-tested against the ring emulator
/// (`ring-emulator/emulator/ota.py`), which is the contract. Same names and bytes as Android `AbOta`.
///
///     app → ring  cc aa 55 ee 12 19 e4                         identify (no seq, no reply)
///     app → ring  92 seq 01 00 03 00 04 00 06 00               get all info
///     ring → app  92 seq 01 02 <ver u16> 03 02 <caps> 04 02 <status> 06 01 <channel>
///     app → ring  91 seq 01                                    get version
///     ring → app  91 seq 01 <ver u16>
///     app → ring  91 seq 02 <ffff> <md5(file)[0:4]>            update query
///     ring → app  91 seq 02 <start u32> <block u32> <packet u16> <allowed u8>
///     app → ring  a0 seq <start u32> <block-len u32> <data…>   block start (header + data ≤ packet size)
///     app → ring  20 seq <data…>                               until the block is complete
///     ring → app  90 seq <status>                              per block
///
/// Multi-byte fields are little-endian. `seq` is a u8 that increments per frame (wrapping) and restarts
/// at 0 on every new connection.
enum AbOta {
    static let serviceUUID = "0000F003-0000-1000-8000-00805F9B34FB"
    static let notifyUUID = "0000F031-0000-1000-8000-00805F9B34FB"
    static let writeUUID = "0000F032-0000-1000-8000-00805F9B34FB"

    static let identify = Data([0xCC, 0xAA, 0x55, 0xEE, 0x12, 0x19, 0xE4])

    static let cmdStatus: UInt8 = 0x90
    static let cmdGetInfo: UInt8 = 0x91
    static let cmdGetInfoTLV: UInt8 = 0x92
    static let cmdBlockStart: UInt8 = 0xA0
    static let cmdData: UInt8 = 0x20

    static let infoVersion: UInt8 = 0x01
    static let infoUpdate: UInt8 = 0x02
    static let infoCapabilities: UInt8 = 0x03
    static let infoStatus: UInt8 = 0x04
    static let infoChannel: UInt8 = 0x06

    static let statusOK = 0x00
    static let statusDone = 0xFF
    static let statusContinue = 0xFE
    static let statusPause = 0xFD
    static let statusSameFirmware = 0x01
    static let statusWrongKey = 0x02
    static let statusWrongCRC = 0x0B

    /// The vendor SDK's defaults, used only when the update reply leaves a field at 0.
    static let defaultBlockSize = 4096
    static let defaultPacketSize = 240

    /// `a0 seq start(4) length(4)` — the block-start header in front of its data.
    static let blockHeaderSize = 10

    /// `otaFwVer` in the update query; the vendor app never sets it.
    static let otaVersionUnset = 0xFFFF

    // MARK: app → ring

    static func getAllInfo(seq: Int) -> Data {
        Data([cmdGetInfoTLV, UInt8(seq & 0xFF), infoVersion, 0, infoCapabilities, 0, infoStatus, 0, infoChannel, 0])
    }

    static func getVersion(seq: Int) -> Data {
        Data([cmdGetInfo, UInt8(seq & 0xFF), infoVersion])
    }

    /// `91 seq 02 <ffff> <md5(image)[0:4]>` — the ring identifies the image by the MD5 prefix.
    static func updateQuery(seq: Int, md5Prefix: Data, otaVersion: Int = otaVersionUnset) -> Data {
        precondition(md5Prefix.count == 4, "md5 prefix must be 4 bytes")
        return Data([cmdGetInfo, UInt8(seq & 0xFF), infoUpdate, UInt8(otaVersion & 0xFF), UInt8((otaVersion >> 8) & 0xFF)])
            + md5Prefix
    }

    static func md5Prefix(_ image: Data) -> Data {
        Data(Insecure.MD5.hash(data: image).prefix(4))
    }

    /// One block's frames and the seq after them (not masked — the caller keeps counting).
    struct Block: Equatable {
        let frames: [Data]
        let nextSeq: Int
        let start: Int
        let length: Int
    }

    /// One block exactly as the emulator's `app_block_frames` builds it: `a0` start (header + as much data as
    /// fits in `packetSize`) then `20` frames of up to `packetSize − 2` data bytes until the block is complete.
    static func blockFrames(seq: Int, image: Data, start: Int, blockSize: Int, packetSize: Int) -> Block {
        precondition(start >= 0 && start < image.count, "start \(start) outside the image")
        precondition(packetSize > blockHeaderSize, "packet size \(packetSize) too small")
        precondition(blockSize > 0, "block size must be positive")
        let bytes = [UInt8](image)
        let length = min(blockSize, bytes.count - start)
        var out: [Data] = []
        var s = seq
        let first = min(length, packetSize - blockHeaderSize)
        var head = Data([cmdBlockStart, UInt8(s & 0xFF)])
        head.append(u32(start))
        head.append(u32(length))
        head.append(contentsOf: bytes[start..<(start + first)])
        out.append(head)
        s += 1
        var offset = start + first
        while offset < start + length {
            let chunk = min(packetSize - 2, start + length - offset)
            var frame = Data([cmdData, UInt8(s & 0xFF)])
            frame.append(contentsOf: bytes[offset..<(offset + chunk)])
            out.append(frame)
            s += 1
            offset += chunk
        }
        return Block(frames: out, nextSeq: s, start: start, length: length)
    }

    // MARK: ring → app

    enum Reply: Equatable {
        case info(seq: Int, version: Int?, tws: Bool)
        case version(seq: Int, version: Int)
        case update(seq: Int, start: Int, blockSize: Int, packetSize: Int, allowed: Bool)
        case status(seq: Int, code: Int)
    }

    /// A notification on `F031`, or nil when it is none of the replies above (or truncated).
    static func parse(_ frame: Data) -> Reply? {
        let b = [UInt8](frame)
        guard b.count >= 2 else { return nil }
        let cmd = b[0]
        let seq = Int(b[1])
        if cmd == cmdStatus, b.count >= 3 { return .status(seq: seq, code: Int(b[2])) }
        if cmd == cmdGetInfo, b.count >= 5, b[2] == infoVersion { return .version(seq: seq, version: u16(b, 3)) }
        if cmd == cmdGetInfo, b.count >= 14, b[2] == infoUpdate {
            return .update(seq: seq, start: u32(b, 3), blockSize: u32(b, 7), packetSize: u16(b, 11), allowed: b[13] == 1)
        }
        if cmd == cmdGetInfoTLV {
            var version: Int?
            var tws = false
            var i = 2
            while i + 1 < b.count {
                let tag = b[i]
                let len = Int(b[i + 1])
                if i + 2 + len > b.count { break }
                if tag == infoVersion, len >= 2 { version = u16(b, i + 2) }
                if tag == infoCapabilities, len >= 1 { tws = (b[i + 2] & 1) == 1 }
                i += 2 + len
            }
            return .info(seq: seq, version: version, tws: tws)
        }
        return nil
    }

    // MARK: audit log

    /// What the raw-packet log keeps of an OTA frame: headers, offsets and statuses, never block payloads.
    /// `a0` keeps its 10-byte header, `20` its `cmd seq`, everything else is short and kept whole.
    static func logBytes(_ frame: Data, outgoing: Bool) -> Data {
        guard outgoing, let first = frame.first else { return frame }
        if first == cmdBlockStart, frame.count > blockHeaderSize { return Data(frame.prefix(blockHeaderSize)) }
        if first == cmdData, frame.count > 2, frame != identify { return Data(frame.prefix(2)) }
        return frame
    }

    /// A one-line human summary, e.g. `a0 #3 start=4096 len=4096 (+230 B)` or `90 #20 status=ff done`.
    static func summary(_ frame: Data, outgoing: Bool) -> String {
        if frame == identify { return "identify" }
        let b = [UInt8](frame)
        guard b.count >= 2 else { return "short \(hex(frame))" }
        let cmd = b[0]
        let seq = Int(b[1])
        if outgoing {
            if cmd == cmdBlockStart, b.count >= blockHeaderSize {
                return "a0 #\(seq) start=\(u32(b, 2)) len=\(u32(b, 6)) (+\(b.count - blockHeaderSize) B)"
            }
            if cmd == cmdData { return "20 #\(seq) (+\(b.count - 2) B)" }
            if cmd == cmdGetInfoTLV { return "92 #\(seq) get info" }
            if cmd == cmdGetInfo, b.count >= 3, b[2] == infoVersion { return "91 #\(seq) get version" }
            if cmd == cmdGetInfo, b.count >= 9, b[2] == infoUpdate {
                return "91 #\(seq) update query md5=\(hex(Data(b[5..<9])))"
            }
            return hex(frame)
        }
        switch parse(frame) {
        case let .status(_, code)?:
            return "90 #\(seq) status=\(String(format: "%02x", code)) \(statusName(code))"
        case let .update(_, start, block, packet, allowed)?:
            return "91 #\(seq) update start=\(start) block=\(block) packet=\(packet) allowed=\(allowed)"
        case let .version(_, version)?:
            return "91 #\(seq) version=\(String(format: "%04x", version))"
        case let .info(_, version, tws)?:
            return "92 #\(seq) info version=\(version.map { String(format: "%04x", $0) } ?? "null") tws=\(tws)"
        case nil:
            return hex(frame)
        }
    }

    static func statusName(_ code: Int) -> String {
        switch code {
        case statusOK: return "ok"
        case statusDone: return "done"
        case statusContinue: return "continue"
        case statusPause: return "pause"
        case statusSameFirmware: return "same firmware"
        case statusWrongKey: return "wrong key"
        case statusWrongCRC: return "wrong crc"
        default: return "error"
        }
    }

    // MARK: helpers

    private static func u32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
