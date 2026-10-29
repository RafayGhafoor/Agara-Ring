import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The `a1` session handshake's status byte (BUG-109).
///
/// `a1 00 00 06 …` is "authenticated, time set"; `a1 00 00 00 …` is the ring **refusing** the password
/// (protocol §2). The driver used to emit `.commandAck(0xA1)` for both, and the sync engine flips
/// `authenticated` on that ack alone — so a refusal started the whole post-auth sequence against a ring
/// that had not authenticated us, and the user saw "connected" over a permanently empty history.
@MainActor
final class VeepooDriverAuthTests: XCTestCase {

    private final class Writer: RingCommandWriter {
        var deviceIdentifier: String? { "00000000-0000-4000-8000-00000000000B" }
        var commands: [Data] = []
        var emitted: [RingDecodedEvent] = []
        func enqueue(_ command: Data) { commands.append(command) }
        func emit(_ event: RingDecodedEvent) { emitted.append(event) }
    }

    private var writer = Writer()

    private func driverEvents(_ hex: String) -> [RingDecodedEvent] {
        let driver = VeepooDriver(writer: writer)
        return driver.ingest(hexData(hex), from: CBUUID(string: VeepooUUIDs.commandNotify))
    }

    private func hexData(_ value: String) -> Data {
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            data.append(UInt8(value[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    func testARefusedHandshakeIsNotAnAuthAck() {
        // Status byte 0 = "wrong password". No firmware, no identity — and no ack either.
        let events = driverEvents("a1000000" + String(repeating: "00", count: 16))
        XCTAssertFalse(events.contains { if case .commandAck = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .firmware = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .ringIdentity = $0 { return true }; return false })
        // The refusal is still *reported*, so the UI can say the ring rejected the app.
        XCTAssertTrue(events.contains { if case .historySyncProgress = $0 { return true }; return false })
    }

    /// The real ack (capture, 54 frames): `a1 00 00 06 09 de 00 12 09 …` — status 6, device 0x09de.
    func testARealHandshakeStillAcksAndCarriesTheIdentity() {
        let events = driverEvents("a100000609de00120900000114401e1c42410000")
        XCTAssertTrue(events.contains { if case .commandAck(0xA1) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .firmware("00.12.09", _, _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .ringIdentity = $0 { return true }; return false })
    }

    /// End to end: a refusal must not authenticate the session, so the history loop never starts.
    func testTheSyncEngineDoesNotStartADayLoopOnARefusedHandshake() {
        let writer = Writer()
        let driver = VeepooDriver(writer: writer)
        let engine = driver.makeSyncEngine()
        engine.connectionDidStart()
        driver.connectionDidStart()
        engine.runStartup()
        for event in driver.ingest(hexData("a1000000" + String(repeating: "00", count: 16)),
                                  from: CBUUID(string: VeepooUUIDs.commandNotify)) {
            engine.handle(event)
        }
        XCTAssertTrue(engine.isHistorySyncing == false)
        XCTAssertFalse(writer.commands.contains(VeepooEncoder.sleepHistory(dayOffset: 0)))
    }
}
