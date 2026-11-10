import XCTest
@testable import PulseLoop

/// The cloud override of the EV40 share card's address (plan `ev40-share-card-v2`, D1/D4). Mirrors Android's
/// `ShareCardConfigTest` (Rule 2): a server value may change the address printed on other people's screens, so every
/// rejection path is asserted, not just the happy one — and a rejection must always land on the catalog fallback.
final class ShareCardConfigTests: XCTestCase {

    private func good() -> [String: Any] {
        ["display_url": "agaralife.com", "qr_url": "https://www.agaralife.com/", "qr": false]
    }

    private func parse(_ value: [String: Any]?, model: Int = 1, version: Int = 1) -> Any {
        ShareCardConfig.parse(value: value, model: model, version: version, now: Date(timeIntervalSince1970: 1_000))
    }

    private func rejected(_ value: [String: Any]?, model: Int = 1) -> Bool { parse(value, model: model) is ShareCardConfig.Rejected }

    // MARK: Accept

    func testAWellFormedPayloadIsAccepted() throws {
        let accepted = try XCTUnwrap(parse(good()) as? ShareCardConfig.Accepted)
        XCTAssertEqual(accepted.card.displayUrl, "agaralife.com")
        XCTAssertEqual(accepted.card.qrUrl, "https://www.agaralife.com/")
        XCTAssertEqual(accepted.card.qr, false)
        XCTAssertEqual(accepted.version, 1)
    }

    func testTheQrIsOffUnlessTheRecordSaysOtherwise() throws {
        var value = good()
        value["qr"] = nil
        XCTAssertEqual(try XCTUnwrap(parse(value) as? ShareCardConfig.Accepted).card.qr, false)
        value["qr"] = true
        XCTAssertEqual(try XCTUnwrap(parse(value) as? ShareCardConfig.Accepted).card.qr, true)
    }

    /// D4 ships the QR behind the flag: a record with no `qr_url` is still a usable address, it just cannot draw one.
    func testAnAbsentQrUrlIsAcceptedWithNoQr() throws {
        let accepted = try XCTUnwrap(parse(["display_url": "agaralife.com/ev40"]) as? ShareCardConfig.Accepted)
        XCTAssertEqual(accepted.card.displayUrl, "agaralife.com/ev40")
        XCTAssertNil(accepted.card.qrUrl)
        XCTAssertFalse(accepted.card.qr)
    }

    /// The contract's own example: a leading `www.` on either side is ignored when the hosts are compared.
    func testWwwIsIgnoredWhenComparingHosts() throws {
        XCTAssertTrue(parse(["display_url": "www.agaralife.com",
                             "qr_url": "https://agaralife.com/ev40"]) is ShareCardConfig.Accepted)
        XCTAssertTrue(parse(["display_url": "agaralife.com/ev40",
                             "qr_url": "https://www.agaralife.com/ev40"]) is ShareCardConfig.Accepted)
    }

    // MARK: Reject — display_url

    func testADisplayUrlOutsideThreeToFortyCharactersIsRejected() {
        XCTAssertTrue(rejected(["display_url": "ab"]))
        XCTAssertTrue(rejected(["display_url": "a" + String(repeating: "b", count: 40)]))     // 41
        // The boundaries themselves are fine.
        XCTAssertTrue(parse(["display_url": "a.b"]) is ShareCardConfig.Accepted)              // 3
        XCTAssertTrue(parse(["display_url": String(repeating: "a", count: 36) + ".com"]) is ShareCardConfig.Accepted)   // 40
    }

    func testAMissingDisplayUrlIsRejected() {
        XCTAssertTrue(rejected(["qr_url": "https://www.agaralife.com/"]))
        XCTAssertTrue(rejected(nil))
        XCTAssertTrue(rejected(["display_url": 42]))
    }

    func testUppercaseOrACharacterOutsideTheSetIsRejected() {
        XCTAssertTrue(rejected(["display_url": "AgaraLife.com"]))
        XCTAssertTrue(rejected(["display_url": "agaralife_com"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com?x=1"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com/ev40#top"]))
    }

    func testADisplayUrlWithoutADotOrWithASchemeOrASpaceIsRejected() {
        XCTAssertTrue(rejected(["display_url": "agaralife"]))
        XCTAssertTrue(rejected(["display_url": "https://agaralife.com"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com ev40"]))
    }

    // MARK: Reject — qr_url

    func testAQrUrlThatIsNotHttpsIsRejected() {
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": "http://www.agaralife.com/"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": "agaralife.com/"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": 12]))
    }

    func testAQrUrlOverOneHundredAndTwentyCharactersIsRejected() {
        let long = "https://www.agaralife.com/" + String(repeating: "a", count: 95)   // 121
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": long]))
        let fits = "https://www.agaralife.com/" + String(repeating: "a", count: 94)   // 120
        XCTAssertTrue(parse(["display_url": "agaralife.com", "qr_url": fits]) is ShareCardConfig.Accepted)
    }

    func testAQrUrlWithWhitespaceIsRejected() {
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": "https://www.agaralife.com/ev 40"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": "https://www.agaralife.com/ev\n40"]))
    }

    func testAQrUrlOnADifferentHostRejectsTheWholeRecord() throws {
        // Not "keep the address, drop the QR": the two must agree, so the address goes too — the card never prints one
        // domain while the QR points at another.
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": "https://agaraheart.app/"]))
        XCTAssertTrue(rejected(["display_url": "agaralife.com", "qr_url": "https://www.agaralife.comevil.io/"]))
    }

    // MARK: Reject — model and shape

    func testAFutureModelIsRejected() {
        XCTAssertTrue(rejected(good(), model: 2))
        XCTAssertTrue(rejected(good(), model: 0))
        XCTAssertTrue(rejected(good(), model: -1))
    }

    // MARK: Cache

    func testTheCacheRoundTripsAndFallsBackOnGarbage() {
        let raw = ShareCardConfig.Cache.encode(value: good(), model: 1, version: 3,
                                               appliedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: raw).displayUrl, "agaralife.com")
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: raw).qrUrl, "https://www.agaralife.com/")
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: "not json").displayUrl, AgaraCopy.ev40ShareUrlFallback)
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: nil).displayUrl, AgaraCopy.ev40ShareUrlFallback)
        let bad = ShareCardConfig.Cache.encode(value: ["display_url": "CHEAT.EXAMPLE"],
                                               model: 1, version: 4, appliedAt: Date())
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: bad).displayUrl, AgaraCopy.ev40ShareUrlFallback)
    }

    func testTheCacheIsFreshForTwelveHoursAndStaleAfter() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ShareCardConfig.Cache.isFresh(appliedAt: now, now: now))
        XCTAssertTrue(ShareCardConfig.Cache.isFresh(appliedAt: now.addingTimeInterval(-11 * 3600), now: now))
        XCTAssertFalse(ShareCardConfig.Cache.isFresh(appliedAt: now.addingTimeInterval(-13 * 3600), now: now))
        XCTAssertFalse(ShareCardConfig.Cache.isFresh(appliedAt: now.addingTimeInterval(3600), now: now),
                       "a cache stamped in the future is not trusted")
    }

    /// One refresh step: a fresh cache is not fetched again, a stale one is, and both write what they learned. The clock
    /// is a fixed instant: `Date()` round-trips through JSON with a sub-microsecond wobble, which the freshness rule
    /// (correctly) reads as "stamped in the future".
    func testRefreshFetchesAtMostOncePerTwelveHours() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = ShareCardConfig.Cache.encode(value: good(), model: 1, version: 1, appliedAt: now)
        var calls = 0
        let skipped = await ShareCardConfig.refresh(fetch: { _ in calls += 1; return good() }, raw: fresh, now: now)
        XCTAssertNil(skipped)
        XCTAssertEqual(calls, 0)

        let stale = ShareCardConfig.Cache.encode(value: good(), model: 1, version: 1,
                                                 appliedAt: now.addingTimeInterval(-13 * 3600))
        let next = await ShareCardConfig.refresh(
            fetch: { key in calls += 1; XCTAssertEqual(key, "share_card")
                      return ["model": 1, "version": 2, "value": ["display_url": "agaralife.com/ev40"]] },
            raw: stale, now: now)
        XCTAssertEqual(calls, 1)
        let written = try? XCTUnwrap(next)
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: written).displayUrl, "agaralife.com/ev40")
    }

    func testARefreshWithNoRecordKeepsWhatWeHave() async {
        let now = Date()
        let stale = ShareCardConfig.Cache.encode(value: good(), model: 1, version: 1,
                                                 appliedAt: now.addingTimeInterval(-13 * 3600))
        let next = await ShareCardConfig.refresh(fetch: { _ in nil }, raw: stale, now: now)
        XCTAssertNil(next, "a nil fetch (offline, or no enabled record) writes nothing")
    }

    /// A record the console switched off goes back to the catalog address — it does not keep the value it replaced.
    func testADisabledRecordFallsBackAndIsNotRefetchedForTwelveHours() async {
        let now = Date()
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40", qrUrl: nil, qr: false))
        let next = await ShareCardConfig.refresh(
            fetch: { _ in ["model": 1, "version": 2, "enabled": false, "value": good()] }, raw: nil, now: now)
        XCTAssertEqual(ShareCardConfig.active(), ShareCardConfig.fallback)
        let written = try? XCTUnwrap(next)
        XCTAssertEqual(ShareCardConfig.Cache.card(raw: written), ShareCardConfig.fallback)
        ShareCardConfig.install(nil)
    }

    // MARK: Installed value

    /// The card prints `ShareCardConfig.active()`, so this is the test behind "the address comes from the config".
    func testTheInstalledCardIsWhatIsActiveAndNilRestoresTheFallback() {
        ShareCardConfig.install(nil)
        XCTAssertEqual(ShareCardConfig.active().displayUrl, AgaraCopy.ev40ShareUrlFallback)
        ShareCardConfig.install(ShareCard(displayUrl: "agaralife.com/ev40", qrUrl: nil, qr: true))
        XCTAssertEqual(ShareCardConfig.active().displayUrl, "agaralife.com/ev40")
        XCTAssertTrue(ShareCardConfig.active().qr)
        ShareCardConfig.install(nil)
        XCTAssertEqual(ShareCardConfig.active(), ShareCard(displayUrl: AgaraCopy.ev40ShareUrlFallback,
                                                           qrUrl: AgaraCopy.ev40ShareQrFallback, qr: false))
    }

    // MARK: Parity with Android (the same payload must draw the same card on both platforms)

    /// Parsed from real JSON text, because a Swift literal boxes differently from what `JSONSerialization` gives the app.
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testTheQrFlagIsOnlyAJsonBooleanTrue() throws {
        let base = #""display_url":"agaralife.com","qr_url":"https://www.agaralife.com/""#
        XCTAssertEqual(try XCTUnwrap(parse(try json("{\(base),\"qr\":true}")) as? ShareCardConfig.Accepted).card.qr, true)
        XCTAssertEqual(try XCTUnwrap(parse(try json("{\(base),\"qr\":1}")) as? ShareCardConfig.Accepted).card.qr, false,
                       "a number is not a boolean — Android reads 1 as false")
        XCTAssertEqual(try XCTUnwrap(parse(try json("{\(base),\"qr\":\"true\"}")) as? ShareCardConfig.Accepted).card.qr, false,
                       "a string is not a boolean — iOS and Android must agree")
    }

    func testTheHostComparisonIgnoresCase() throws {
        let value = try json(#"{"display_url":"agaralife.com","qr_url":"https://WWW.AgaraLife.com/ev40","qr":true}"#)
        let accepted = try XCTUnwrap(parse(value) as? ShareCardConfig.Accepted, "hosts are case-insensitive, as on Android")
        XCTAssertEqual(accepted.card.qrUrl, "https://WWW.AgaraLife.com/ev40")
    }
}
