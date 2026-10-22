import XCTest
@testable import PulseLoop

/// `docs/process/plans/rebrand-measure-1.0.md` behaviour spec, iOS side (Android runs the same cases):
/// item 1 live heart rate (default off, off → `D0 00` once), item 3 the once-per-ring default schedule (flags
/// respected), item 4 the short-interval list. Plus the shared row-visibility rule (item 2) and the theme rule
/// behind the background-snapshot crash fix.
@MainActor
final class RebrandMeasureTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RebrandMeasureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Item 1: live heart rate

    func testLiveHeartRateUnsetReadsTheCatalogDefaultOff() {
        XCTAssertEqual(AgaraConfig.Ring.liveHrDefaultOn, 0)
        XCTAssertFalse(VeepooLivePrefsStore.defaultEnabled)
        XCTAssertFalse(VeepooLivePrefsStore(defaults: defaults).liveHeartRateEnabled, "unset must read as off")
    }

    func testLiveHeartRateStoredChoiceWinsAndPersists() {
        let store = VeepooLivePrefsStore(defaults: defaults)
        store.liveHeartRateEnabled = true
        XCTAssertEqual(defaults.object(forKey: VeepooLivePrefsStore.key) as? Bool, true)
        XCTAssertTrue(VeepooLivePrefsStore(defaults: defaults).liveHeartRateEnabled)
        store.liveHeartRateEnabled = false
        XCTAssertFalse(VeepooLivePrefsStore(defaults: defaults).liveHeartRateEnabled)
    }

    func testLiveHeartRateChangePostsTheNotification() {
        let store = VeepooLivePrefsStore(defaults: defaults)
        let posted = expectation(forNotification: VeepooLivePrefsStore.didChangeNotification, object: store)
        store.liveHeartRateEnabled = true
        wait(for: [posted], timeout: 1)
    }

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

    /// An authenticated engine whose one-day startup history pass has finished.
    private func engineAfterHistory(live: @escaping () -> Bool) -> VeepooSyncEngine {
        writer = RecordingWriter()
        let engine = VeepooSyncEngine(writer: writer, decoder: VeepooDecoder(), historyDays: 1)
        engine.wantsLiveHeartRate = live
        engine.connectionDidStart()
        engine.handle(.commandAck(commandId: 0xA1))
        let sleepNoData = Data([0xE0, 0, 0, 0] + [UInt8](repeating: 0, count: 16))
        let dailyEnd = Data([0xDF, 0xFF, 0xFF, 0x58] + [UInt8](repeating: 0, count: 16))
        engine.handle(.unknown(commandId: 0xE0, raw: sleepNoData))
        engine.handle(.unknown(commandId: 0xDF, raw: dailyEnd))
        XCTAssertFalse(engine.isHistorySyncing)
        return engine
    }

    func testLiveStreamNeverStartsWhenThePreferenceIsOff() {
        let engine = engineAfterHistory(live: { false })
        engine.pollTickFired()
        engine.pollTickFired()
        XCTAssertFalse(writer.commands.contains(VeepooEncoder.heartRateStart()), "D0 01 sent with live HR off")
        XCTAssertFalse(writer.commands.contains(VeepooEncoder.heartRateStop()))
        engine.connectionDidEnd()
    }

    func testTurningLiveOffSendsTheStopOnceAndAtOnce() {
        var live = true
        let engine = engineAfterHistory(live: { live })
        XCTAssertEqual(writer.commands.last, VeepooEncoder.heartRateStart(), "live on: the stream starts after history")
        writer.commands.removeAll()

        live = false
        engine.liveHeartRatePreferenceChanged()            // no poll tick needed
        XCTAssertEqual(writer.commands, [VeepooEncoder.heartRateStop()])
        engine.liveHeartRatePreferenceChanged()
        engine.pollTickFired()
        XCTAssertEqual(writer.commands.filter { $0 == VeepooEncoder.heartRateStop() }.count, 1, "stop sent more than once")
        XCTAssertFalse(writer.commands.contains(VeepooEncoder.heartRateStart()))

        live = true
        engine.liveHeartRatePreferenceChanged()
        XCTAssertEqual(writer.commands.last, VeepooEncoder.heartRateStart(), "turning it back on restarts at once")
        engine.connectionDidEnd()
    }

    /// Pref on → stream started by the engine; a workout (or spot test) then holds the stream; turning the pref off
    /// must not send `D0 00` under it — only the app's own stop ends it.
    func testTurningLiveOffNeverKillsAStreamTheAppHolds() {
        for hold in [{ (e: VeepooSyncEngine) in e.startHeartRate() }, { (e: VeepooSyncEngine) in e.measureHeartRateSpot() }] {
            var live = true
            let engine = engineAfterHistory(live: { live })
            hold(engine)
            writer.commands.removeAll()
            live = false
            engine.liveHeartRatePreferenceChanged()
            engine.pollTickFired()
            engine.pollTickFired()
            XCTAssertFalse(writer.commands.contains(VeepooEncoder.heartRateStop()), "D0 00 killed the app's stream")
            engine.stopHeartRate()
            XCTAssertEqual(writer.commands.filter { $0 == VeepooEncoder.heartRateStop() }.count, 1, "the app's own stop")
            engine.pollTickFired()
            XCTAssertFalse(writer.commands.contains(VeepooEncoder.heartRateStart()), "live off: nothing restarts")
            engine.connectionDidEnd()
        }
    }

    // MARK: - Item 2: the Auto-measure row

    func testAutoMeasureRowShowsWhenTheRingSupportsItEvenWithoutASchedule() {
        XCTAssertTrue(AutoMeasure.showsSettingsRow(flagOn: true, schedule: [], supportsAutoMeasure: true))
        XCTAssertTrue(AutoMeasure.showsSettingsRow(flagOn: true, schedule: [entry(0, step: 30)], supportsAutoMeasure: false))
        XCTAssertFalse(AutoMeasure.showsSettingsRow(flagOn: true, schedule: [], supportsAutoMeasure: false))
        XCTAssertFalse(AutoMeasure.showsSettingsRow(flagOn: false, schedule: [entry(0, step: 30)], supportsAutoMeasure: true))
    }

    // MARK: - Item 4: short intervals

    private func entry(_ type: Int, enabled: Bool = false, interval: Int = 60, step: Int,
                       modifiable: Bool = true) -> AutoMeasureEntry {
        AutoMeasureEntry(type: type, enabled: enabled, intervalMinutes: interval, startHour: 0, startMinute: 0,
                         endHour: 0, endMinute: 0, stepMinutes: step, windowModifiable: true,
                         intervalModifiable: modifiable)
    }

    func testIntervalsWithoutShortValuesAreTheStepMultiples() {
        let hr = entry(0, interval: 30, step: 30)
        XCTAssertEqual(AutoMeasure.intervals(for: hr, shortIntervals: ""), [30, 60, 90, 120, 150, 180, 210, 240])
        XCTAssertEqual(AutoMeasure.optionLabel(minutes: 30, for: hr), "30 min · most battery")
    }

    func testShortIntervalsBelowTheStepAreOfferedFirst() {
        let hr = entry(0, interval: 30, step: 30)
        let values = AutoMeasure.intervals(for: hr, shortIntervals: "5, 10,15,45,x,0")
        XCTAssertEqual(Array(values.prefix(5)), [5, 10, 15, 30, 60], "45 is not below the step; junk ignored")
        XCTAssertFalse(values.contains(45))
        let spo2 = entry(4, interval: 60, step: 60)
        XCTAssertEqual(Array(AutoMeasure.intervals(for: spo2, shortIntervals: "5,45").prefix(3)), [5, 45, 60])
    }

    func testShippedCatalogHasNoShortIntervalsYet() {
        // Filled only from the real-ring probe; until then the list is unchanged.
        let hr = entry(0, interval: 30, step: 30)
        XCTAssertEqual(AutoMeasure.intervals(for: hr), AutoMeasure.intervals(for: hr, shortIntervals: ""))
    }

    // MARK: - Item 3: default schedule, once per ring

    private let allOff: (AgaraFeature) -> Bool = { _ in false }

    func testDefaultIntervalIsTheSmallestAcceptedValueAtOrAboveThirty() {
        XCTAssertEqual(AutoMeasure.defaultInterval(for: entry(0, step: 30), defaultMinutes: 30, shortIntervals: ""), 30)
        XCTAssertEqual(AutoMeasure.defaultInterval(for: entry(4, step: 60), defaultMinutes: 30, shortIntervals: ""), 60)
        XCTAssertEqual(AutoMeasure.defaultInterval(for: entry(0, step: 30), defaultMinutes: 30, shortIntervals: "5,10"), 30)
    }

    func testDefaultWritesRespectFlagsLocksAndRowsAlreadyAtTheDefault() {
        let schedule = [
            entry(0, enabled: false, interval: 60, step: 30),               // HR off, 60 → on, 30
            entry(1, enabled: false, interval: 60, step: 30),               // BP: flag off → untouched
            entry(2, enabled: false, interval: 60, step: 30),               // glucose: flag off → untouched
            entry(3, enabled: true, interval: 30, step: 30),                // stress: already default → nothing
            entry(4, enabled: false, interval: 120, step: 60),              // SpO₂ → on, 60
            entry(6, enabled: true, interval: 10, step: 5, modifiable: false), // Lorenz locked → untouched
        ]
        let writes = AutoMeasure.defaultWrites(for: schedule, isOn: allOff, defaultMinutes: 30, shortIntervals: "")
        XCTAssertEqual(writes.map(\.type), [0, 4])
        XCTAssertEqual(writes.map(\.intervalMinutes), [30, 60])
        XCTAssertTrue(writes.allSatisfy(\.enabled))
        XCTAssertEqual(writes[0].startHour, schedule[0].startHour, "window kept")

        let withBP = AutoMeasure.defaultWrites(for: schedule, isOn: { $0 == .vitalsBp }, defaultMinutes: 30, shortIntervals: "")
        XCTAssertEqual(withBP.map(\.type), [0, 1, 4], "BP row joins once its flag is on")
    }

    private func store(address: String, sent: @escaping (AutoMeasureEntry) -> Void) -> AutoMeasureStore {
        let store = AutoMeasureStore()
        store.defaults = defaults
        store.isFeatureOn = allOff
        store.ringAddress = { address }
        store.timeout = 60
        store.sender = { sent($0); return true }
        return store
    }

    func testDefaultsAreWrittenOncePerRingOneAtATime() {
        var sent: [AutoMeasureEntry] = []
        var schedule = [entry(0, enabled: false, interval: 60, step: 30),
                        entry(1, enabled: false, interval: 60, step: 30),
                        entry(4, enabled: false, interval: 120, step: 60)]
        let first = store(address: "ring-A") { sent.append($0) }
        first.handle(.autoMeasureSchedule(schedule))
        XCTAssertEqual(sent.map(\.type), [0], "one write at a time")
        XCTAssertTrue(first.defaultsApplied(for: "ring-A"))

        // The read-back confirms HR → the SpO₂ default goes out next.
        schedule[0].enabled = true
        schedule[0].intervalMinutes = 30
        first.handle(.autoMeasureSchedule(schedule))
        XCTAssertEqual(sent.map(\.type), [0, 4])
        schedule[2].enabled = true
        schedule[2].intervalMinutes = 60
        first.handle(.autoMeasureSchedule(schedule))
        XCTAssertEqual(sent.count, 2, "BP (flag off) is never written")

        // The user later turns HR off; a reconnect (new session, same ring) must not overwrite it.
        schedule[0].enabled = false
        sent.removeAll()
        let again = store(address: "ring-A") { sent.append($0) }
        again.handle(.autoMeasureSchedule(schedule))
        XCTAssertTrue(sent.isEmpty, "defaults re-applied to a ring that already had them")

        // Another ring gets its own defaults.
        let other = store(address: "ring-B") { sent.append($0) }
        other.handle(.autoMeasureSchedule(schedule))
        XCTAssertEqual(sent.map(\.type), [0])
    }

    func testARefusedDefaultIsNotRetriedAndTheNextOneGoesOut() {
        var sent: [AutoMeasureEntry] = []
        let schedule = [entry(0, enabled: false, interval: 60, step: 30), entry(4, enabled: false, interval: 120, step: 60)]
        let store = store(address: "virtual") { sent.append($0) }
        store.handle(.autoMeasureSchedule(schedule))
        XCTAssertEqual(sent.map(\.type), [0])
        store.handle(.decodedPacket(.settingAck(commandId: 0xB3, ok: false)))
        XCTAssertEqual(sent.map(\.type), [0, 4], "moved on after the refusal")
        store.handle(.autoMeasureSchedule(schedule))           // read-back: SpO₂ kept its old value
        XCTAssertEqual(sent.count, 2, "refused rows are not retried")
        XCTAssertTrue(store.pendingDefaults.isEmpty)
    }

    func testADisconnectDropsTheRemainingDefaults() {
        var sent: [AutoMeasureEntry] = []
        let schedule = [entry(0, enabled: false, interval: 60, step: 30), entry(4, enabled: false, interval: 120, step: 60)]
        let store = store(address: "ring-C") { sent.append($0) }
        store.handle(.autoMeasureSchedule(schedule))
        XCTAssertEqual(store.pendingDefaults.map(\.type), [4])
        store.handle(.deviceStateChanged(state: .disconnected, address: nil))
        XCTAssertTrue(store.pendingDefaults.isEmpty)
        XCTAssertEqual(sent.count, 1)
    }

    func testNoDefaultsWithoutARingAddress() {
        var sent: [AutoMeasureEntry] = []
        let store = store(address: "") { sent.append($0) }
        store.handle(.autoMeasureSchedule([entry(0, step: 30)]))
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Background-snapshot crash: the theme follows the OS only while active

    func testThemeIsNotSwappedWhileTheSceneIsNotActive() {
        XCTAssertTrue(ThemeApplyPolicy.shouldApply(scenePhase: .active, current: "ember-dark", resolved: "ember-light"))
        XCTAssertFalse(ThemeApplyPolicy.shouldApply(scenePhase: .background, current: "ember-dark", resolved: "ember-light"))
        XCTAssertFalse(ThemeApplyPolicy.shouldApply(scenePhase: .inactive, current: "ember-dark", resolved: "ember-light"))
        XCTAssertFalse(ThemeApplyPolicy.shouldApply(scenePhase: .active, current: "ember-dark", resolved: "ember-dark"))
    }

    /// The rule behind the 1.0.0 (1) TestFlight crash, enforced: every presentation root re-injects the ring objects.
    /// Per source file, `.agaraRingEnvironment()` calls must be at least the presentations (`.sheet`, `.fullScreenCover`,
    /// `.popover`, `.navigationDestination`). Merging 1.1 into the review branch found three 1.1 presentations without
    /// it (coach consent, nudge inbox, breathing) — 2026-10-22.
    func testEveryPresentationRootReinjectsTheRingObjects() throws {
        let appSources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PulseLoop")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        var short: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
            let presentations = text.matches(of: /\.(sheet|fullScreenCover|popover|navigationDestination)\(/).count
            let reinjections = text.matches(of: /\.agaraRingEnvironment\(\)/).count
            scanned += presentations
            if presentations > reinjections { short.append("\(url.lastPathComponent): \(presentations) vs \(reinjections)") }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found the app's presentations")
        XCTAssertEqual(short, [], "presentation roots without .agaraRingEnvironment()")
    }

    func testRingEnvironmentHolderIsSetByTheApp() {
        // The app host's `AgaraApp.init` runs before the tests: every presentation root injects from this holder.
        XCTAssertNotNil(AgaraRingEnvironment.current)
    }
}
