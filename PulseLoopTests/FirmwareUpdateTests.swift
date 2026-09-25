import XCTest
import CryptoKit
@testable import PulseLoop

/// Firmware update stages 1–2 (docs/process/plans/firmware-update.md). The `Version3` shape and the query come
/// from docs/ring/research/05-firmware-update.md §1a; no reply was ever captured, so the sample body below is
/// built from the documented field names. Android's tests use the same sample.
@MainActor
final class FirmwareUpdateTests: XCTestCase {
    private let ring = FirmwareIdentity(deviceNumber: 2526, version: "00.12.09", testVersion: "00.12.09.00")
    private let image = Data((0..<4096).map { UInt8($0 % 251) })
    private var defaults: UserDefaults!
    private var storage: URL!

    override func setUp() {
        super.setUp()
        let suite = "FirmwareUpdateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        storage = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storage)
        super.tearDown()
    }

    private func version3(version: String = "00.12.10", md5: String? = nil, size: Int? = nil) -> Data {
        // The vendor SDK's shape: a `Version3` object nested in the reply, every value a string.
        let body = """
        {"Version3":{"DeviceType":"2526","NewVersion":"\(version)","NewMD5":"\(md5 ?? FirmwareUpdateLogic.md5Hex(image).uppercased())",
         "NewUrl":"http://127.0.0.1:9911/firmware/2526-\(version).bin","NewSize":"\(size ?? image.count)",
         "Des":"Improves sleep detection."}}
        """
        return Data(body.utf8)
    }

    // MARK: URL

    func testCheckURLCarriesTheDocumentedQuery() throws {
        let url = try XCTUnwrap(FirmwareUpdateLogic.checkURL(base: AgaraConfig.Ring.firmwareCheckUrl, identity: ring))
        XCTAssertEqual(url.absoluteString,
                       "https://www.vphband.com:9001/api/Version/GetVersionForSport?type=android&devicetype=2526&testVersion=00.12.09.00")
    }

    func testCheckURLKeepsOverrideHostAndExistingQuery() throws {
        let url = try XCTUnwrap(FirmwareUpdateLogic.checkURL(base: "http://127.0.0.1:9911/api/Version/GetVersionForSport?x=1", identity: ring))
        XCTAssertEqual(url.absoluteString,
                       "http://127.0.0.1:9911/api/Version/GetVersionForSport?x=1&type=android&devicetype=2526&testVersion=00.12.09.00")
        XCTAssertNil(FirmwareUpdateLogic.checkURL(base: "not a url", identity: ring))
    }

    // MARK: Version comparison

    func testVersionComparisonIsPerComponent() {
        XCTAssertTrue(FirmwareUpdateLogic.isNewer("00.12.10", than: "00.12.09"))
        XCTAssertTrue(FirmwareUpdateLogic.isNewer("00.13.00", than: "00.12.99"))
        XCTAssertTrue(FirmwareUpdateLogic.isNewer("01.00.00", than: "00.12.09"))
        XCTAssertFalse(FirmwareUpdateLogic.isNewer("00.12.09", than: "00.12.09"))
        XCTAssertFalse(FirmwareUpdateLogic.isNewer("00.12.07", than: "00.12.09"))
        XCTAssertTrue(FirmwareUpdateLogic.isNewer("00.12.10.00", than: "00.12.09"))
        XCTAssertFalse(FirmwareUpdateLogic.isNewer("00.12.09.00", than: "00.12.09"))
        XCTAssertFalse(FirmwareUpdateLogic.isNewer("", than: "00.12.09"))
    }

    // MARK: Version3 parsing

    func testParsesVersion3() throws {
        let release = try XCTUnwrap(try FirmwareUpdateLogic.parseVersion3(version3()))
        XCTAssertEqual(release.version, "00.12.10")
        XCTAssertEqual(release.url, "http://127.0.0.1:9911/firmware/2526-00.12.10.bin")
        XCTAssertEqual(release.md5, FirmwareUpdateLogic.md5Hex(image))   // lower-cased
        XCTAssertEqual(release.size, 4096)
        XCTAssertEqual(release.notes, "Improves sleep detection.")
    }

    /// Tolerated too: an unwrapped object, numeric values, other key casing.
    func testParsesFlatNumericVariant() throws {
        let body = #"{"newversion":"00.12.10","newmd5":"AB","newurl":"https://x/y.bin","newsize":123,"des":""}"#
        let release = try XCTUnwrap(try FirmwareUpdateLogic.parseVersion3(Data(body.utf8)))
        XCTAssertEqual(release.size, 123)
        XCTAssertEqual(release.md5, "ab")
        XCTAssertEqual(release.notes, "")
    }

    func testEmptyFieldsMeanNoUpdate() throws {
        XCTAssertNil(try FirmwareUpdateLogic.parseVersion3(Data(#"{"Version3":{"DeviceType":"2526","NewVersion":"","NewMD5":"","NewUrl":"","NewSize":"","Des":""}}"#.utf8)))
        XCTAssertNil(try FirmwareUpdateLogic.parseVersion3(version3(md5: "")))
        XCTAssertThrowsError(try FirmwareUpdateLogic.parseVersion3(Data("<html>".utf8)))
    }

    // MARK: MD5

    func testVerifyChecksSizeAndMD5() {
        let md5 = Insecure.MD5.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let good = FirmwareRelease(version: "00.12.10", url: "u", md5: md5.uppercased(), size: Int64(image.count), notes: "")
        XCTAssertTrue(FirmwareUpdateLogic.verify(image, against: good))
        XCTAssertFalse(FirmwareUpdateLogic.verify(image.dropLast(), against: good))
        var corrupt = image
        corrupt[10] ^= 0xFF
        XCTAssertFalse(FirmwareUpdateLogic.verify(corrupt, against: good))
        XCTAssertEqual(FirmwareUpdateLogic.md5Hex(Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
    }

    // MARK: Status transitions

    private func checker(
        check: Data, file: Data? = nil, status: Int = 200, flags: Set<AgaraFeature> = [.firmwareCheck, .firmwareDownload],
        clock: @escaping () -> Date = Date.init, requests: RequestLog? = nil
    ) -> FirmwareUpdateChecker {
        let fileData = file ?? image
        return FirmwareUpdateChecker(
            defaults: defaults, storageDirectory: storage, now: clock, isOn: { flags.contains($0) },
            fetch: { request in
                requests?.append(request.url!)
                let url = request.url!
                let body = url.path.hasSuffix(".bin") ? fileData : check
                return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        )
    }

    final class RequestLog: @unchecked Sendable {
        private(set) var urls: [URL] = []
        private let lock = NSLock()
        func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    }

    func testAvailableThenDownloadedAndVerified() async throws {
        let sut = checker(check: version3())
        XCTAssertEqual(sut.status, .unknown)
        await sut.check(ring)
        guard case let .available(release) = sut.status else { return XCTFail("\(sut.status)") }
        XCTAssertEqual(release.version, "00.12.10")
        await sut.download()
        XCTAssertEqual(sut.status, .ready(release))
        let stored = try XCTUnwrap(sut.storedFileURL())
        XCTAssertEqual(try Data(contentsOf: stored), image)
        XCTAssertEqual(stored.lastPathComponent, "agara-2526-00.12.10.bin")
    }

    func testSameOrOlderVersionIsUpToDate() async {
        let sut = checker(check: version3(version: "00.12.09"))
        await sut.check(ring)
        XCTAssertEqual(sut.status, .upToDate)
        XCTAssertNil(sut.latestRelease)
    }

    func testServerErrorAndBadJSONAreQuietErrors() async {
        let failing = checker(check: version3(), status: 500)
        await failing.check(ring)
        XCTAssertEqual(failing.status, .error("Couldn't check for updates"))
        let garbage = checker(check: Data("<html>".utf8))
        await garbage.check(ring)
        XCTAssertEqual(garbage.status, .error("Couldn't check for updates"))
    }

    func testCorruptDownloadIsRejectedAndNotStored() async throws {
        var corrupt = image
        corrupt[0] ^= 0xFF
        let sut = checker(check: version3(), file: corrupt)
        await sut.check(ring)
        await sut.download()
        guard case .error = sut.status else { return XCTFail("\(sut.status)") }
        XCTAssertNotNil(sut.latestRelease)   // retryable
        let files = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testFlagsGateCheckAndDownload() async {
        let off = checker(check: version3(), flags: [])
        await off.check(ring)
        XCTAssertEqual(off.status, .unknown)
        let checkOnly = checker(check: version3(), flags: [.firmwareCheck])
        await checkOnly.check(ring)
        await checkOnly.download()
        guard case .available = checkOnly.status else { return XCTFail("\(checkOnly.status)") }
    }

    func testAutomaticCheckRunsAtMostOncePerDay() async {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let log = RequestLog()
        let sut = checker(check: version3(), clock: { now }, requests: log)
        await sut.checkIfDue(ring)
        XCTAssertEqual(log.urls.count, 1)
        now.addTimeInterval(3600)
        await sut.checkIfDue(ring)
        XCTAssertEqual(log.urls.count, 1)
        guard case .available = sut.status else { return XCTFail("\(sut.status)") }   // from the cache
        now.addTimeInterval(24 * 3600)
        await sut.checkIfDue(ring)
        XCTAssertEqual(log.urls.count, 2)
    }

    func testCachedReleaseIsRestoredAndVerifiedFileIsReady() async {
        let first = checker(check: version3())
        await first.check(ring)
        await first.download()
        // A fresh instance (app relaunch) restores "ready" from the cache + the stored, verified file.
        let relaunch = checker(check: version3())
        relaunch.restore(ring)
        guard case .ready = relaunch.status else { return XCTFail("\(relaunch.status)") }
        // Once the ring runs the new version, the cache means "up to date" and the stale file is deleted.
        relaunch.restore(FirmwareIdentity(deviceNumber: 2526, version: "00.12.10", testVersion: "00.12.10.00"))
        XCTAssertEqual(relaunch.status, .upToDate)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testNewerReleaseDeletesOlderDownload() async throws {
        let first = checker(check: version3())
        await first.check(ring)
        await first.download()
        let second = checker(check: version3(version: "00.12.11"))
        await second.check(ring)
        guard case .available = second.status else { return XCTFail("\(second.status)") }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: Real vendor reply

    /// The vendor's actual reply for devicetype 2526, fetched 2026-09-25. The server returns the same body
    /// whatever the ring runs, so the comparison against the ring's version decides.
    private let realVendorReply = Data(#"""
    {"Version1":null,"Version2":null,"Version3":{"NewUrl":"https://www.vphband.com/vx/vx12/2526/VX12_2526_00120900_OTA_260824_14.bin","NewVersion":"00.12.09","Version":"","Url":"","Type":"bin","DeviceType":"2526","Des":"","Size":"236544","NewSize":"236544","MD5":"7c9d6afdcdc023605e47b293f13a7501","NewMD5":"7c9d6afdcdc023605e47b293f13a7501","AlertType":"0"}}
    """#.utf8)

    func testRealVendorReplyParsesAndComparesAgainstTheRing() async throws {
        let release = try XCTUnwrap(try FirmwareUpdateLogic.parseVersion3(realVendorReply))
        XCTAssertEqual(release.version, "00.12.09")
        XCTAssertEqual(release.size, 236_544)
        XCTAssertEqual(release.md5, "7c9d6afdcdc023605e47b293f13a7501")
        XCTAssertEqual(release.url, "https://www.vphband.com/vx/vx12/2526/VX12_2526_00120900_OTA_260824_14.bin")
        XCTAssertEqual(release.notes, "")

        let behind = checker(check: realVendorReply)
        await behind.check(FirmwareIdentity(deviceNumber: 2526, version: "00.12.07", testVersion: "00.12.07.00"))
        XCTAssertEqual(behind.status, .available(release))

        let current = checker(check: realVendorReply)
        await current.check(ring)   // 00.12.09
        XCTAssertEqual(current.status, .upToDate)
    }

    // MARK: a1 → identity event

    func testA1FirmwareBridgesToIdentity() {
        let events = RingEventBridge.events(for: .firmware(version: "00.12.09", deviceNumber: 2526, testVersion: "00.12.09.00"))
        XCTAssertEqual(events.count, 2)
        guard case let .firmwareIdentity(number, version, test) = events[1] else { return XCTFail() }
        XCTAssertEqual(number, 2526)
        XCTAssertEqual(version, "00.12.09")
        XCTAssertEqual(test, "00.12.09.00")
    }
}
