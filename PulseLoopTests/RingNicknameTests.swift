import XCTest
import SwiftData
@testable import PulseLoop

/// "Name your ring": the nickname rules (trim, 1–24 chars, blank → model name), which name each surface
/// shows, and that the name survives the store, a reconnect, an archive round trip, and dies with Forget.
@MainActor
final class RingNicknameTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private let ringA = "11111111-AAAA-4000-8000-000000000001"
    private let ringB = "22222222-BBBB-4000-8000-000000000002"

    private func identified(_ advertisedName: String?, ring: String? = nil) -> AgaraEvent {
        .deviceIdentified(deviceType: .veepoo, wearableModelID: "tk20", advertisedName: advertisedName,
                          capabilities: [], peripheralIdentifier: ring)
    }

    /// The per-ring map lives in `UserDefaults.standard` (the subscriber's store); start and end clean.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: RingNicknameMemory.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: RingNicknameMemory.defaultsKey)
        super.tearDown()
    }

    // MARK: - Validation

    func testNormalizedTrimsWhitespace() {
        XCTAssertEqual(RingNickname.normalized("  Left hand \n"), "Left hand")
    }

    func testBlankNormalizesToNilSoTheModelNameShows() {
        XCTAssertNil(RingNickname.normalized(""))
        XCTAssertNil(RingNickname.normalized("   \t\n"))
    }

    func testNormalizedCapsAtTwentyFourCharacters() {
        let long = String(repeating: "a", count: 30)
        XCTAssertEqual(RingNickname.normalized(long)?.count, 24)
        XCTAssertEqual(RingNickname.normalized(String(repeating: "b", count: 24)), String(repeating: "b", count: 24))
    }

    func testIsValidAcceptsOneToTwentyFourTrimmedCharactersAndBlank() {
        XCTAssertTrue(RingNickname.isValid("A"))
        XCTAssertTrue(RingNickname.isValid(String(repeating: "x", count: 24)))
        XCTAssertTrue(RingNickname.isValid("  " + String(repeating: "x", count: 24) + "  "), "length is measured after trimming")
        XCTAssertTrue(RingNickname.isValid(""), "blank resets to the model name")
        XCTAssertFalse(RingNickname.isValid(String(repeating: "x", count: 25)))
    }

    func testClampInputStopsTypingAtTheLimit() {
        XCTAssertEqual(RingNickname.clampInput(String(repeating: "x", count: 30)).count, 24)
        XCTAssertEqual(RingNickname.clampInput("Left "), "Left ", "trailing space survives while typing")
    }

    func testSuggestionsAndDefaultMatchThePlan() {
        XCTAssertEqual(RingNickname.suggestions, ["Left hand", "Right hand", "Sleep ring", "Spare"])
        XCTAssertEqual(RingNickname.defaultName, AgaraCopy.ringDisplayName)
        XCTAssertEqual(RingNickname.maxLength, 24)
    }

    // MARK: - Display-name resolution

    func testDisplayNamePrefersNickname() {
        XCTAssertEqual(RingNickname.displayName(nickname: "Sleep ring", modelName: "Agara Ring"), "Sleep ring")
    }

    func testDisplayNameFallsBackToModelThenDefault() {
        XCTAssertEqual(RingNickname.displayName(nickname: nil, modelName: "Agara Ring"), "Agara Ring")
        XCTAssertEqual(RingNickname.displayName(nickname: "   ", modelName: "Agara Ring"), "Agara Ring")
        XCTAssertEqual(RingNickname.displayName(nickname: nil, modelName: nil), RingNickname.defaultName)
    }

    func testHeroCardTitleUsesNicknameButKeepsPairedState() {
        let named = DeviceHeroStatus.make(state: .disconnected, connectedName: nil, knownName: "Agara Ring",
            nickname: "Left hand", batteryPercent: nil, lastSync: nil, now: now)
        XCTAssertEqual(named.title, "Left hand")
        XCTAssertEqual(named.action, .connect)

        let unpaired = DeviceHeroStatus.make(state: .idle, connectedName: nil, knownName: nil,
            nickname: "Left hand", batteryPercent: nil, lastSync: nil, now: now)
        XCTAssertEqual(unpaired.title, "No ring connected", "a stale nickname never makes a ring look paired")

        let unnamed = DeviceHeroStatus.make(state: .connected, connectedName: "Agara Ring", knownName: "Agara Ring",
            batteryPercent: nil, lastSync: nil, now: now)
        XCTAssertEqual(unnamed.title, "Agara Ring")
    }

    func testHeaderChipSpeaksTheRingName() {
        XCTAssertEqual(
            RingStatusChip.accessibilityLabel(ringName: "Sleep ring", statusLabel: "Connected", battery: 80, charging: false),
            "Sleep ring connected, battery 80 percent"
        )
        XCTAssertEqual(
            RingStatusChip.accessibilityLabel(ringName: nil, statusLabel: "Disconnected", battery: nil, charging: false),
            "Ring disconnected"
        )
        XCTAssertEqual(
            RingStatusChip.accessibilityLabel(ringName: "Spare", statusLabel: "Connected", battery: 40, charging: true),
            "Spare charging, battery 40 percent"
        )
    }

    // MARK: - Persistence

    func testSetNicknameRoundTripsThroughTheStore() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))

        DeviceRepository.setNickname("  Right hand ", context: context)

        // A fresh context on the same container reads what was saved, not a cached object.
        let reread = ModelContext(context.container)
        let device = try XCTUnwrap(DeviceRepository.current(context: reread))
        XCTAssertEqual(device.nickname, "Right hand")
        XCTAssertEqual(device.displayName, "Right hand")
        XCTAssertEqual(device.modelDisplayName, AgaraCopy.ringDisplayName)
    }

    func testBlankNicknameResetsToModelName() throws {
        let context = try TestSupport.makeContext()
        DeviceRepository.setNickname("Spare", context: context)
        let device = DeviceRepository.setNickname("   ", context: context)
        XCTAssertNil(device.nickname)
        XCTAssertEqual(device.displayName, AgaraCopy.ringDisplayName)
    }

    func testSetNicknameBeforeTheConnectRowExistsIsReusedByTheSubscriber() throws {
        let context = try TestSupport.makeContext()
        DeviceRepository.setNickname("Sleep ring", context: context)
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))

        XCTAssertEqual(DeviceRepository.devices(context: context).count, 1)
        XCTAssertEqual(DeviceRepository.current(context: context)?.nickname, "Sleep ring")
    }

    func testReconnectKeepsTheNickname() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))
        DeviceRepository.setNickname("Left hand", context: context)

        subscriber.persist(.deviceStateChanged(state: .connected, address: nil))
        subscriber.persist(identified("TK20 3B00"))

        XCTAssertEqual(DeviceRepository.current(context: context)?.displayName, "Left hand")
    }

    func testForgettingTheRingClearsTheNickname() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))
        DeviceRepository.setNickname("Left hand", context: context)

        subscriber.persist(.deviceForgotten)

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertNil(device.nickname)
        XCTAssertEqual(device.displayName, AgaraCopy.ringDisplayName)
    }

    func testArchiveCarriesTheNicknameAndOldArchivesStillDecode() throws {
        let source = try TestSupport.makeContext()
        let device = Device(name: "TK20 3B00", wearableModelID: "tk20")
        device.nickname = "Spare"
        source.insert(device)

        let data = try JSONEncoder().encode(ArchiveDevice(device))
        let decoded = try JSONDecoder().decode(ArchiveDevice.self, from: data)
        XCTAssertEqual(decoded.nickname, "Spare")

        let target = try TestSupport.makeContext()
        decoded.insert(into: target)
        XCTAssertEqual(DeviceRepository.current(context: target)?.nickname, "Spare")

        // An archive written before ring naming has no `nickname` key at all.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "nickname")
        let legacy = try JSONDecoder().decode(ArchiveDevice.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.nickname)
    }

    // MARK: - Per-ring memory (several rings share the one Device row)

    func testNicknameMapRoundTripsThroughUserDefaultsAsJSON() throws {
        let suite = "RingNicknameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = RingNicknameMemory(defaults: defaults)

        memory.set("  Left hand ", for: ringA)
        memory.set("Sleep ring", for: ringB)
        memory.set(RingNickname.defaultName, for: "model-name-is-no-nickname")

        // A fresh reader over the same defaults sees the same map, stored as a JSON dictionary string.
        let reread = RingNicknameMemory(defaults: defaults)
        XCTAssertEqual(reread.all, [ringA: "Left hand", ringB: "Sleep ring"])
        let json = try XCTUnwrap(defaults.string(forKey: "ringNicknames"))
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [ringA: "Left hand", ringB: "Sleep ring"])

        reread.remove(identifier: ringA)
        XCTAssertEqual(RingNicknameMemory(defaults: defaults).all, [ringB: "Sleep ring"])
        XCTAssertNil(reread.nickname(for: ringA))
    }

    func testConnectingRingBAfterNamingAKeepsAsEntryAndShowsBUnnamed() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)

        subscriber.persist(identified("TK20 7C11", ring: ringB))

        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertEqual(DeviceRepository.devices(context: context).count, 1, "still one reused row")
        XCTAssertEqual(device.peripheralIdentifier, ringB)
        XCTAssertNil(device.nickname)
        XCTAssertEqual(device.displayName, AgaraCopy.ringDisplayName)
        XCTAssertEqual(RingNicknameMemory().all, [ringA: "Left hand"], "A's name is remembered, not overwritten")
    }

    func testReconnectingRingARestoresItsName() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)
        subscriber.persist(identified("TK20 7C11", ring: ringB))
        DeviceRepository.setNickname("Right hand", context: context)

        subscriber.persist(identified("TK20 3B00", ring: ringA))
        XCTAssertEqual(DeviceRepository.current(context: context)?.displayName, "Left hand")

        subscriber.persist(identified("TK20 7C11", ring: ringB))
        XCTAssertEqual(DeviceRepository.current(context: context)?.displayName, "Right hand")
        XCTAssertEqual(RingNicknameMemory().all, [ringA: "Left hand", ringB: "Right hand"])
    }

    func testForgetRemovesThatRingsEntryOnly() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 7C11", ring: ringB))
        DeviceRepository.setNickname("Spare", context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)

        subscriber.persist(.deviceForgotten)

        XCTAssertEqual(RingNicknameMemory().all, [ringB: "Spare"])
        let device = try XCTUnwrap(DeviceRepository.current(context: context))
        XCTAssertNil(device.nickname)
        XCTAssertNil(device.peripheralIdentifier)

        // Re-pairing the forgotten ring starts unnamed; the other ring still has its name.
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        XCTAssertNil(DeviceRepository.current(context: context)?.nickname)
        subscriber.persist(identified("TK20 7C11", ring: ringB))
        XCTAssertEqual(DeviceRepository.current(context: context)?.nickname, "Spare")
    }

    /// A name saved before per-ring memory existed (row has no identity) belongs to the ring that
    /// connects next: it is migrated into the map rather than wiped.
    func testALegacyRowNicknameIsAdoptedByTheFirstIdentifiedRing() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00"))
        DeviceRepository.setNickname("Sleep ring", context: context)
        XCTAssertTrue(RingNicknameMemory().all.isEmpty, "no identity yet, nothing to key the map by")

        subscriber.persist(identified("TK20 3B00", ring: ringA))

        XCTAssertEqual(DeviceRepository.current(context: context)?.nickname, "Sleep ring")
        XCTAssertEqual(RingNicknameMemory().all, [ringA: "Sleep ring"])
    }

    /// The pairing step can save before ring B's connect event reaches the store; passing the live
    /// identity files the name under B and leaves A's untouched.
    func testPairingStepSavesUnderTheLiveRingBeforeItsConnectEventLands() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)

        XCTAssertNil(RingNicknameMemory().nickname(forConnected: ringB, row: DeviceRepository.current(context: context)),
                     "the naming step does not prefill A's name for B")
        DeviceRepository.setNickname("Right hand", peripheralIdentifier: ringB, context: context)
        subscriber.persist(identified("TK20 7C11", ring: ringB))

        XCTAssertEqual(DeviceRepository.current(context: context)?.nickname, "Right hand")
        XCTAssertEqual(RingNicknameMemory().all, [ringA: "Left hand", ringB: "Right hand"])
    }

    /// Re-pairing ring A while the row still shows ring B: the naming step / Rename sheet prefill A's
    /// remembered name, and saving that prefill unedited keeps A's name (and B's).
    func testPrefillUsesTheConnectedRingsRememberedNameSoAnUneditedSaveKeepsIt() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)
        subscriber.persist(identified("TK20 7C11", ring: ringB))
        DeviceRepository.setNickname("Right hand", context: context)

        let row = DeviceRepository.current(context: context)
        let prefill = RingNickname.prefill(identifier: ringA, row: row)
        XCTAssertEqual(prefill, "Left hand")
        DeviceRepository.setNickname(prefill, peripheralIdentifier: ringA, context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))

        XCTAssertEqual(DeviceRepository.current(context: context)?.displayName, "Left hand")
        XCTAssertEqual(RingNicknameMemory().all, [ringA: "Left hand", ringB: "Right hand"])

        // No live identifier (disconnected): the row's ring is the one being renamed.
        XCTAssertEqual(RingNickname.prefill(identifier: nil, row: DeviceRepository.current(context: context)), "Left hand")
        // A ring nobody named falls back to the model name.
        XCTAssertEqual(RingNickname.prefill(identifier: "33333333-CCCC-4000-8000-000000000003", row: row),
                       RingNickname.defaultName)
        XCTAssertEqual(RingNickname.prefill(identifier: nil, row: nil), RingNickname.defaultName)
    }

    func testBlankRenameDropsTheRingsEntry() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)
        DeviceRepository.setNickname("  ", context: context)

        XCTAssertTrue(RingNicknameMemory().all.isEmpty)
        subscriber.persist(identified("TK20 3B00", ring: ringA))
        XCTAssertNil(DeviceRepository.current(context: context)?.nickname)
    }

    // MARK: - A ring named after its person (D5/D6)

    func testAPersonNameBecomesTheRingsPossessiveName() {
        XCTAssertEqual(RingNickname.forPerson("Hayden"), "Hayden\u{2019}s Ring")
    }

    func testOnlyTheFirstWordIsUsedAndItsFirstLetterIsCapitalised() {
        XCTAssertEqual(RingNickname.forPerson("  hayden  smith "), "Hayden\u{2019}s Ring")
        XCTAssertEqual(RingNickname.forPerson("Hayden Smith"), "Hayden\u{2019}s Ring")
    }

    func testANameEndingInSTakesTheApostropheS() {
        // One style, stated in the plan: modern possessive, never "James\u{2019} Ring".
        XCTAssertEqual(RingNickname.forPerson("James"), "James\u{2019}s Ring")
    }

    func testSurroundingPunctuationIsDropped() {
        XCTAssertEqual(RingNickname.forPerson("Hayden,"), "Hayden\u{2019}s Ring")
        XCTAssertEqual(RingNickname.forPerson("\"Hayden\""), "Hayden\u{2019}s Ring")
        XCTAssertEqual(RingNickname.forPerson("(Hayden)"), "Hayden\u{2019}s Ring")
    }

    func testNoUsablePersonNameYieldsNoDerivedName() {
        XCTAssertNil(RingNickname.forPerson(nil))
        XCTAssertNil(RingNickname.forPerson(""))
        XCTAssertNil(RingNickname.forPerson("   \t\n"))
        XCTAssertNil(RingNickname.forPerson("123"))
        XCTAssertNil(RingNickname.forPerson("--"))
    }

    func testAVeryLongPersonNameIsShortenedButKeepsTheSuffix() {
        let derived = RingNickname.forPerson(String(repeating: "a", count: 40))
        let name = try? XCTUnwrap(derived)
        XCTAssertEqual(name?.count, RingNickname.maxLength, "the whole name fits the field's limit")
        XCTAssertEqual(name?.hasSuffix(RingNickname.possessiveSuffix), true, "the suffix is never what gets cut")
        XCTAssertEqual(derived?.count, RingNickname.maxLength)
    }

    func testADerivedNameIsDeterministic() {
        XCTAssertEqual(RingNickname.forPerson("Hayden"), RingNickname.forPerson("Hayden"))
        // And it must survive the store's own normalisation unchanged: it is a real name, not a placeholder.
        XCTAssertEqual(RingNickname.normalized("Hayden\u{2019}s Ring"), "Hayden\u{2019}s Ring")
    }

    func testThePersonsNameIsTheFirstSuggestionChip() {
        let chips = RingNickname.suggestions(forPerson: "Hayden")
        XCTAssertEqual(chips.first, "Hayden\u{2019}s Ring")
        XCTAssertEqual(Array(chips.dropFirst()), RingNickname.suggestions, "the standing chips are unchanged behind it")
        XCTAssertEqual(RingNickname.suggestions(forPerson: nil), RingNickname.suggestions)
        XCTAssertEqual(RingNickname.suggestions(forPerson: "  "), RingNickname.suggestions)
    }

    func testPrefillOffersThePersonsNameOnlyWhenTheRingHasNone() {
        XCTAssertEqual(RingNickname.prefill(identifier: ringA, row: nil, personName: "Hayden"), "Hayden\u{2019}s Ring")
        XCTAssertEqual(RingNickname.prefill(identifier: ringA, row: nil, personName: nil), RingNickname.defaultName)
        RingNicknameMemory().set("Left hand", for: ringA)
        XCTAssertEqual(RingNickname.prefill(identifier: ringA, row: nil, personName: "Hayden"), "Left hand",
                       "a name the user chose always wins over the derived one")
    }

    // MARK: - The scan row (D1/D2)

    func testAnUnnamedRingShowsTheProductNamePlusItsTag() {
        let row = RingScanName.row(identity: ringA, nickname: nil, advertisedName: "TK20",
                                   isMatched: true, pairedIdentity: nil)
        XCTAssertEqual(row.text, AgaraCopy.ringDisplayName + RingScanName.tagSeparator + RingScanName.tag(identity: ringA))
        XCTAssertEqual(row.spokenText, AgaraCopy.ringDisplayName + ", " + RingScanName.tag(identity: ringA))
        XCTAssertFalse(row.isKnown)
        XCTAssertFalse(row.text.contains("TK20"), "the advertised hardware name never shows on a matched ring")
    }

    func testANamedRingShowsItsNameAndIsKnown() {
        RingNicknameMemory().set("Hayden\u{2019}s Ring", for: ringA)
        let row = RingScanName.row(identity: ringA, nickname: RingNicknameMemory().nickname(for: ringA),
                                   advertisedName: "TK20", isMatched: true, pairedIdentity: nil)
        XCTAssertEqual(row.text, "Hayden\u{2019}s Ring")
        XCTAssertEqual(row.spokenText, "Hayden\u{2019}s Ring")
        XCTAssertTrue(row.isKnown)
    }

    func testAnotherRingsNameIsNeverShownOnThisRow() {
        RingNicknameMemory().set("Sleep ring", for: ringB)
        let row = RingScanName.row(identity: ringA, nickname: RingNicknameMemory().nickname(for: ringA),
                                   advertisedName: "TK20", isMatched: true, pairedIdentity: nil)
        XCTAssertFalse(row.text.contains("Sleep ring"), "one ring's name must never label another ring")
        XCTAssertTrue(row.text.hasPrefix(AgaraCopy.ringDisplayName))
    }

    func testTheTagIsStableFourUppercaseHexAndDiffersBetweenRings() {
        let a = RingScanName.tag(identity: ringA)
        XCTAssertEqual(a, RingScanName.tag(identity: ringA), "stable across calls, so the row does not flicker")
        XCTAssertNotEqual(a, RingScanName.tag(identity: ringB))
        XCTAssertEqual(a.count, RingScanName.tagLength)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit && !$0.isLowercase })
        XCTAssertEqual(RingScanName.tag(identity: ringA.lowercased()), a, "the identity's case is irrelevant")
    }

    func testTheTagMatchesTheSharedFormula() {
        // FNV-1a 32-bit over the uppercased identity, low 16 bits, uppercase hex — the same vectors Android's
        // `RingScanNameTest` pins, so a port drift is a red test on one side or the other. (The identity each
        // platform hashes differs: the peripheral UUID here, the BLE address there.)
        XCTAssertEqual(RingScanName.tag(identity: "AA:BB:CC:DD:EE:01"), "B9CC")
        XCTAssertEqual(RingScanName.tag(identity: "aa:bb:cc:dd:ee:02"), "BE85")
        XCTAssertEqual(RingScanName.tag(identity: ""), "9DC5")
    }

    func testAnUnmatchedPeripheralKeepsItsAdvertisedNameAndGetsNoTag() {
        let row = RingScanName.row(identity: ringA, nickname: nil, advertisedName: "  My Scale  ",
                                   isMatched: false, pairedIdentity: nil)
        XCTAssertEqual(row.text, "My Scale")
        XCTAssertFalse(row.isKnown)
        let unnamed = RingScanName.row(identity: ringA, nickname: nil, advertisedName: "   ",
                                       isMatched: false, pairedIdentity: nil)
        XCTAssertEqual(unnamed.text, AgaraCopy.ringDisplayName, "a blank advertisement still shows something tappable")
    }

    func testThePairedRingWithoutANameIsStillKnown() {
        // Pairing happened, the user skipped naming: the row is theirs, so it sorts first even though unnamed.
        let row = RingScanName.row(identity: ringA, nickname: nil, advertisedName: "TK20",
                                   isMatched: true, pairedIdentity: ringA.lowercased())
        XCTAssertTrue(row.isKnown)
    }

    func testSortKeyPutsAKnownRingAboveEverythingElse() {
        let known = RingScanName.sortKey(isKnown: true, isLikelyRing: true, rssi: -95)
        let strongRing = RingScanName.sortKey(isKnown: false, isLikelyRing: true, rssi: -40)
        let stranger = RingScanName.sortKey(isKnown: false, isLikelyRing: false, rssi: -30)
        XCTAssertLessThan(known, strongRing, "mine first, however weak its signal")
        XCTAssertLessThan(strongRing, stranger, "recognised rings above unrecognised ones")
        XCTAssertLessThan(RingScanName.sortKey(isKnown: false, isLikelyRing: true, rssi: -50),
                          RingScanName.sortKey(isKnown: false, isLikelyRing: true, rssi: -80),
                          "within a group, the stronger signal leads")
    }

    // MARK: - The person's name adopted at profile completion (D5/B2)

    func testSavingTheProfileNamesAnUnnamedRing() throws {
        let context = try TestSupport.makeContext()
        EventPersistenceSubscriber(context: context).persist(identified("TK20 3B00", ring: ringA))

        XCTAssertTrue(DeviceRepository.adoptPersonName("Hayden", context: context))
        XCTAssertEqual(DeviceRepository.current(context: context)?.nickname, "Hayden\u{2019}s Ring")
        XCTAssertEqual(RingNicknameMemory().nickname(for: ringA), "Hayden\u{2019}s Ring",
                       "remembered per ring, so the name follows that ring and not the row")
    }

    func testAdoptingThePersonsNameNeverReplacesAChosenOne() throws {
        let context = try TestSupport.makeContext()
        EventPersistenceSubscriber(context: context).persist(identified("TK20 3B00", ring: ringA))
        DeviceRepository.setNickname("Left hand", context: context)

        XCTAssertFalse(DeviceRepository.adoptPersonName("Hayden", context: context))
        XCTAssertEqual(DeviceRepository.current(context: context)?.nickname, "Left hand")
    }

    func testAdoptingDoesNothingWithoutAPairedRingOrAName() throws {
        let context = try TestSupport.makeContext()
        XCTAssertFalse(DeviceRepository.adoptPersonName("Hayden", context: context), "no ring to name yet")
        EventPersistenceSubscriber(context: context).persist(identified("TK20 3B00", ring: ringA))
        XCTAssertFalse(DeviceRepository.adoptPersonName(nil, context: context))
        XCTAssertFalse(DeviceRepository.adoptPersonName("   ", context: context))
        XCTAssertNil(DeviceRepository.current(context: context)?.nickname, "a skipped profile step leaves the model name")
    }

    // MARK: - Animation curves

    func testAnimationCurvesStayInTheirRanges() {
        for step in 0..<200 {
            let t = Double(step) * 0.05
            XCTAssertLessThanOrEqual(abs(AnimatedRingArt.floatOffset(at: t)), AnimatedRingArt.floatAmplitude + 0.0001)
            XCTAssertTrue(AnimatedRingArt.glowRange.contains(AnimatedRingArt.glowOpacity(at: t)))
            let angle = AnimatedRingArt.sweepDegrees(at: t)
            XCTAssertTrue(angle >= 0 && angle < 360)
        }
        XCTAssertEqual(AnimatedRingArt.speed(for: .searching), 2 * AnimatedRingArt.speed(for: .idle))
        XCTAssertEqual(AnimatedRingArt.glowOpacity(at: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(AnimatedRingArt.glowOpacity(at: AnimatedRingArt.glowHalfPeriod), 0.5, accuracy: 0.0001)
    }

    func testTheUnchangedModelNameIsNoNickname() {
        // Same rule as Android: saving the prefilled model name stores nothing.
        XCTAssertNil(RingNickname.normalized(RingNickname.defaultName))
        XCTAssertNil(RingNickname.normalized("  \(RingNickname.defaultName) "))
        XCTAssertEqual(RingNickname.normalized("Agara Ring 2"), "Agara Ring 2")
    }
}
