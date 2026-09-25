import Foundation
import CryptoKit
import Observation

// Ring firmware update, stages 1–2 (docs/process/plans/firmware-update.md): check the vendor's public version
// endpoint and download + verify the file. No ring writes here — installing (stage 4) is `FirmwareInstallController`.
// Contract: docs/ring/research/05-firmware-update.md §1a. Same names as Android's `FirmwareUpdateChecker`.

/// A firmware release as the vendor's `Version3` reply describes it.
struct FirmwareRelease: Codable, Equatable, Sendable {
    /// Dotted version, e.g. "00.12.10".
    let version: String
    /// Download URL of the image.
    let url: String
    /// Lower-case hex MD5 of the image.
    let md5: String
    /// Image size in bytes.
    let size: Int64
    /// Release notes (`Des`); may be empty.
    let notes: String
}

/// What the Wearable › Firmware row shows.
enum FirmwareStatus: Equatable, Sendable {
    case unknown
    case checking
    case upToDate
    case available(FirmwareRelease)
    case downloading(FirmwareRelease)
    /// Downloaded, size and MD5 verified, stored in app-private storage.
    case ready(FirmwareRelease)
    /// A quiet, user-facing message (no transport detail).
    case error(String)
}

/// The lookup key the ring reports in its `a1` reply.
struct FirmwareIdentity: Equatable, Sendable {
    /// Device number (2526 for the Agara ring), sent as `devicetype`.
    let deviceNumber: Int
    /// Release version the ring runs ("00.12.09"); compared against the server's `NewVersion`.
    let version: String
    /// Test version ("00.12.09.00"), sent as `testVersion`.
    let testVersion: String
}

/// Pure helpers: URL building, `Version3` parsing, version comparison, verification.
enum FirmwareUpdateLogic {
    /// The platform value the vendor endpoint is known to accept. The research only documents the vendor's
    /// Android app (`type=android`); an iOS value was never observed, so both apps send `android`.
    nonisolated static let platformType = "android"

    /// `<base>?type=android&devicetype=<device number>&testVersion=<test version>` — query items already on
    /// `base` are kept.
    nonisolated static func checkURL(base: String, identity: FirmwareIdentity) -> URL? {
        guard var components = URLComponents(string: base), components.scheme != nil, components.host != nil else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "type", value: platformType))
        items.append(URLQueryItem(name: "devicetype", value: String(identity.deviceNumber)))
        items.append(URLQueryItem(name: "testVersion", value: identity.testVersion))
        components.queryItems = items
        return components.url
    }

    /// Numeric components of a dotted version; a component's non-digits are ignored ("V12" → 12).
    nonisolated static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    /// True when `candidate` is higher than `current`, comparing component by component (a missing
    /// component counts as 0, so "00.12.10.00" vs "00.12.09" works). An empty candidate is never newer.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The same release, compared component by component ("00.12.09" == "00.12.09.00"). An empty version
    /// never matches.
    nonisolated static func sameVersion(_ a: String, _ b: String) -> Bool {
        guard !components(a).isEmpty, !components(b).isEmpty else { return false }
        return !isNewer(a, than: b) && !isNewer(b, than: a)
    }

    enum ParseError: Error { case notJSON }

    /// Parse the reply `{"Version3": {"DeviceType", "NewVersion", "NewMD5", "NewUrl", "NewSize", "Des"}}` — the
    /// vendor SDK's shape: the object nested under `Version3`, every value a string, `NewSize` in bytes. Tolerant
    /// of an unwrapped object (or one under `data`), numeric values and other key casing. Returns nil — "no update" — when any of version/url/md5/size is empty, like the
    /// vendor app. Throws only when the body is not a JSON object.
    nonisolated static func parseVersion3(_ data: Data) throws -> FirmwareRelease? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.notJSON
        }
        for wrapper in ["version3", "data"] {
            if let key = object.keys.first(where: { $0.lowercased() == wrapper }),
               let inner = object[key] as? [String: Any] {
                object = inner
            }
        }
        func field(_ name: String) -> String {
            guard let key = object.keys.first(where: { $0.lowercased() == name.lowercased() }) else { return "" }
            switch object[key] {
            case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        let version = field("NewVersion"), url = field("NewUrl"), md5 = field("NewMD5")
        guard !version.isEmpty, !url.isEmpty, !md5.isEmpty, let size = Int64(field("NewSize")), size > 0 else {
            return nil
        }
        return FirmwareRelease(version: version, url: url, md5: md5.lowercased(), size: size, notes: field("Des"))
    }

    nonisolated static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The file is the release: exact size and matching MD5 (case-insensitive).
    nonisolated static func verify(_ data: Data, against release: FirmwareRelease) -> Bool {
        Int64(data.count) == release.size && md5Hex(data) == release.md5.lowercased()
    }

    /// The stored file name for a release, e.g. `agara-2526-00.12.10.bin`.
    nonisolated static func fileName(deviceNumber: Int, release: FirmwareRelease) -> String {
        let safe = release.version.filter { $0.isNumber || $0 == "." }
        return "agara-\(deviceNumber)-\(safe.isEmpty ? "unknown" : safe).bin"
    }
}

/// Checks for newer ring firmware (flag `firmwareCheck`) and downloads + verifies it (flag `firmwareDownload`).
///
/// * Automatically once a day at most, when the ring's `a1` identity arrives after a connect; manually via the
///   Firmware row's "Check".
/// * The last result is cached, so between checks the row still says "Update available" / "Up to date".
/// * Debug builds honour `-firmwareCheckUrl <url>` (UserDefaults) — the emulator's fake server.
@MainActor
@Observable
final class FirmwareUpdateChecker {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = FirmwareUpdateChecker()

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The launch-argument / UserDefaults key for the debug endpoint override.
    static let urlOverrideKey = "firmwareCheckUrl"
    static let lastCheckKey = "agara.firmware.lastCheckAt"
    static let cacheKey = "agara.firmware.cache"
    static let checkTimeout: TimeInterval = 15
    static let downloadTimeout: TimeInterval = 60
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var status: FirmwareStatus = .unknown
    /// The newest release the server reported for this ring (kept through a failed download so it can be retried).
    private(set) var latestRelease: FirmwareRelease?
    private(set) var lastCheckedAt: Date?
    private(set) var identity: FirmwareIdentity?

    /// The last server answer, per device number (nil release = up to date).
    private struct Cache: Codable {
        let deviceNumber: Int
        let release: FirmwareRelease?
    }

    private let defaults: UserDefaults
    private let fetch: Fetch
    private let storageDirectory: URL
    private let now: () -> Date
    private let isOn: (AgaraFeature) -> Bool
    private var streamTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        isOn: ((AgaraFeature) -> Bool)? = nil,
        fetch: Fetch? = nil
    ) {
        self.defaults = defaults
        self.now = now
        self.isOn = isOn ?? { AgaraFeatureStore.isOn($0) }
        self.storageDirectory = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firmware", isDirectory: true)
        if let fetch {
            self.fetch = fetch
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.checkTimeout
            let session = URLSession(configuration: configuration)
            self.fetch = { request in try await session.data(for: request) }
        }
        self.lastCheckedAt = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// The version endpoint: the debug override when set, else the catalog value.
    var endpoint: String {
        #if DEBUG
        if let override = defaults.string(forKey: Self.urlOverrideKey), !override.isEmpty { return override }
        #endif
        return AgaraConfig.Ring.firmwareCheckUrl
    }

    /// Subscribe to the bus: each `a1` identity (one per connect) triggers `checkIfDue`.
    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                guard case let .firmwareIdentity(deviceNumber, version, testVersion) = event else { continue }
                await self?.checkIfDue(FirmwareIdentity(deviceNumber: deviceNumber, version: version, testVersion: testVersion))
            }
        }
    }

    // MARK: Check

    /// The automatic path: check when the last check is older than a day (or was for another ring), otherwise
    /// show the cached answer.
    func checkIfDue(_ identity: FirmwareIdentity) async {
        guard isOn(.firmwareCheck) else { return }
        if isDue(for: identity) {
            await check(identity)
        } else {
            restore(identity)
        }
    }

    func isDue(for identity: FirmwareIdentity) -> Bool {
        guard let last = lastCheckedAt, loadCache()?.deviceNumber == identity.deviceNumber else { return true }
        return now().timeIntervalSince(last) >= Self.autoCheckInterval
    }

    /// Show the cached answer for `identity` without a network call (e.g. when the Wearable screen opens).
    func restore(_ identity: FirmwareIdentity) {
        guard isOn(.firmwareCheck), !isBusy else { return }
        self.identity = identity
        guard let cache = loadCache(), cache.deviceNumber == identity.deviceNumber else { return }
        apply(release: cache.release, for: identity)
    }

    /// The manual "Check" (and the due automatic one): one GET, 15 s timeout, quiet error state.
    func check(_ identity: FirmwareIdentity) async {
        guard isOn(.firmwareCheck), !isBusy else { return }
        self.identity = identity
        guard let url = FirmwareUpdateLogic.checkURL(base: endpoint, identity: identity) else {
            status = .error("Update server not configured")
            return
        }
        status = .checking
        stampCheck()
        var request = URLRequest(url: url, timeoutInterval: Self.checkTimeout)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetch(request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                throw URLError(.badServerResponse)
            }
            let release = try FirmwareUpdateLogic.parseVersion3(data)
            saveCache(Cache(deviceNumber: identity.deviceNumber, release: release))
            apply(release: release, for: identity)
        } catch {
            status = .error("Couldn't check for updates")
        }
    }

    private var isBusy: Bool {
        switch status {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// Server answer → status. A release that isn't newer than the ring's firmware means "up to date".
    private func apply(release: FirmwareRelease?, for identity: FirmwareIdentity) {
        guard let release, FirmwareUpdateLogic.isNewer(release.version, than: identity.version) else {
            latestRelease = nil
            status = .upToDate
            deleteStaleFiles(keeping: nil)
            return
        }
        latestRelease = release
        deleteStaleFiles(keeping: FirmwareUpdateLogic.fileName(deviceNumber: identity.deviceNumber, release: release))
        status = storedFileIsValid(release, deviceNumber: identity.deviceNumber) ? .ready(release) : .available(release)
    }

    // MARK: Download

    /// Download the latest release into app-private storage and verify size + MD5. No ring writes.
    func download() async {
        guard isOn(.firmwareDownload), let identity, let release = latestRelease else { return }
        switch status {
        case .available, .error: break
        default: return
        }
        guard let url = URL(string: release.url), url.scheme != nil else {
            status = .error("The download link is invalid")
            return
        }
        status = .downloading(release)
        do {
            let (data, response) = try await fetch(URLRequest(url: url, timeoutInterval: Self.downloadTimeout))
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                throw URLError(.badServerResponse)
            }
            guard FirmwareUpdateLogic.verify(data, against: release) else {
                status = .error("The download didn't verify — try again")
                return
            }
            let name = FirmwareUpdateLogic.fileName(deviceNumber: identity.deviceNumber, release: release)
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            var fileURL = storageDirectory.appendingPathComponent(name)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? fileURL.setResourceValues(values)
            deleteStaleFiles(keeping: name)
            status = .ready(release)
        } catch {
            status = .error("Download failed — try again")
        }
    }

    /// The verified file for the ready release, if any (`FirmwareInstallController` reads it).
    func storedFileURL() -> URL? {
        guard case let .ready(release) = status, let identity else { return nil }
        return storageDirectory.appendingPathComponent(FirmwareUpdateLogic.fileName(deviceNumber: identity.deviceNumber, release: release))
    }

    private func storedFileIsValid(_ release: FirmwareRelease, deviceNumber: Int) -> Bool {
        let url = storageDirectory.appendingPathComponent(FirmwareUpdateLogic.fileName(deviceNumber: deviceNumber, release: release))
        guard let data = try? Data(contentsOf: url) else { return false }
        return FirmwareUpdateLogic.verify(data, against: release)
    }

    /// Remove every stored image except `keeping` (older releases, failed leftovers).
    private func deleteStaleFiles(keeping: String?) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: storageDirectory.path) else { return }
        for file in files where file != keeping {
            try? fm.removeItem(at: storageDirectory.appendingPathComponent(file))
        }
    }

    // MARK: Persistence

    private func stampCheck() {
        let date = now()
        lastCheckedAt = date
        defaults.set(date, forKey: Self.lastCheckKey)
    }

    private func loadCache() -> Cache? {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func saveCache(_ cache: Cache) {
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
    }
}
