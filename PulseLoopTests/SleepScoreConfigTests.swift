import XCTest
@testable import PulseLoop

/// The cloud override of the sleep model (plan asana-heart-bugs-2026-11-01, F3). Mirrors Android's
/// `SleepScoreConfigTest` / `SleepScoreConfigRefreshTest` (Rule 2): a server value may tune the score, it may never
/// make it lie — so every rejection path is asserted, not just the happy one.
final class SleepScoreConfigTests: XCTestCase {

    private func good() -> [String: Any] {
        ["durationWeight": 42.0, "deepWeight": 21.0, "remWeight": 12.0, "lightWeight": 12.0, "awakeWeight": 13.0,
         "coverageFull": 0.9, "floorHours": 7.0, "floorAwakePct": 12.0, "floorScore": 72,
         "shortHours6": 6.0, "capUnder6h": 69, "shortHours5": 5.0, "capUnder5h": 54]
    }

    private func parse(_ value: [String: Any]?, model: Int = 2, version: Int = 3) -> Any {
        SleepScoreConfig.parse(value: value, model: model, version: version, now: Date(timeIntervalSince1970: 1_000))
    }

    func testAWellFormedPayloadIsAccepted() throws {
        let accepted = try XCTUnwrap(parse(good()) as? SleepScoreConfig.Accepted)
        XCTAssertEqual(accepted.model.durationWeight, 42, accuracy: 0.001)
        XCTAssertEqual(accepted.model.deepWeight, 21, accuracy: 0.001)
        XCTAssertEqual(accepted.model.coverageFull, 0.9, accuracy: 0.001)
        XCTAssertEqual(accepted.model.floorScore, 72)
        XCTAssertEqual(accepted.model.id, "sleep-v2@cloud")
        XCTAssertEqual(accepted.version, 3)
    }

    func testOmittedKeysKeepTheCompiledValue() throws {
        let accepted = try XCTUnwrap(parse(["deepWeight": 25.0]) as? SleepScoreConfig.Accepted)
        XCTAssertEqual(accepted.model.deepWeight, 25, accuracy: 0.001)
        XCTAssertEqual(accepted.model.durationWeight, SleepScore.Model().durationWeight, accuracy: 0.001)
    }

    func testAnUnimplementedModelIsRefused() {
        XCTAssertTrue(parse(good(), model: 3) is SleepScoreConfig.Rejected)
    }

    func testOutOfRangeAndInvertedValuesAreRefusedWhole() {
        var v = good(); v["durationWeight"] = 500.0
        XCTAssertTrue(parse(v) is SleepScoreConfig.Rejected)
        v = good(); v["coverageFull"] = 0.2
        XCTAssertTrue(parse(v) is SleepScoreConfig.Rejected)
        v = good(); v["floorScore"] = 140
        XCTAssertTrue(parse(v) is SleepScoreConfig.Rejected)
        // Gates out of order: a 7-hour night capped harder than a 5-hour one would be nonsense.
        v = good(); v["shortHours5"] = 8.0
        XCTAssertTrue(parse(v) is SleepScoreConfig.Rejected)
        v = good(); v["capUnder5h"] = 90
        XCTAssertTrue(parse(v) is SleepScoreConfig.Rejected)
        // All weights zero: nothing to score with.
        XCTAssertTrue(parse(["durationWeight": 0.0, "deepWeight": 0.0, "remWeight": 0.0,
                             "lightWeight": 0.0, "awakeWeight": 0.0]) is SleepScoreConfig.Rejected)
        XCTAssertTrue(parse(["deepWeight": "not-a-number"]) is SleepScoreConfig.Rejected)
    }

    func testTheCacheRoundTripsAndACorruptCacheFallsBack() {
        let raw = SleepScoreConfig.Cache.encode(value: good(), model: 2, version: 3, appliedAt: Date())
        XCTAssertEqual(SleepScoreConfig.Cache.model(raw: raw).durationWeight, 42, accuracy: 0.001)
        XCTAssertEqual(SleepScoreConfig.Cache.model(raw: "not json"), SleepScore.Model())
        XCTAssertEqual(SleepScoreConfig.Cache.model(raw: nil), SleepScore.Model())
        let bad = SleepScoreConfig.Cache.encode(value: ["durationWeight": 999.0], model: 2, version: 4, appliedAt: Date())
        XCTAssertEqual(SleepScoreConfig.Cache.model(raw: bad), SleepScore.Model())
    }

    func testTheCacheIsFreshForTwelveHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SleepScoreConfig.Cache.isFresh(appliedAt: now, now: now))
        XCTAssertTrue(SleepScoreConfig.Cache.isFresh(appliedAt: now.addingTimeInterval(-11 * 3600), now: now))
        XCTAssertFalse(SleepScoreConfig.Cache.isFresh(appliedAt: now.addingTimeInterval(-13 * 3600), now: now))
        XCTAssertFalse(SleepScoreConfig.Cache.isFresh(appliedAt: now.addingTimeInterval(3600), now: now),
                       "a clock that went backwards must not look fresh forever")
    }

    // MARK: - The refresh step

    func testAFreshCacheMeansNoFetch() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cached = SleepScoreConfig.Cache.encode(value: good(), model: 2, version: 3,
                                                   appliedAt: now.addingTimeInterval(-3600))
        var calls = 0
        let next = await SleepScoreConfig.refresh(fetch: { _ in calls += 1; return ["model": 2, "version": 4, "value": good()] },
                                                  raw: cached, now: now)
        XCTAssertNil(next)
        XCTAssertEqual(calls, 0, "the 12 h throttle must not call the server")
    }

    func testAnAcceptedRecordBecomesTheModelInForceAndIsCached() async {
        SleepScoreConfig.install(nil)
        let raw = await SleepScoreConfig.refresh(fetch: { _ in ["model": 2, "version": 3, "value": good()] },
                                                 raw: nil, now: Date())
        XCTAssertEqual(SleepScoreConfig.active().durationWeight, 42, accuracy: 0.001)
        XCTAssertEqual(SleepScoreConfig.Cache.model(raw: raw).durationWeight, 42, accuracy: 0.001)

        // …and the scorer really uses it.
        let inputs = SleepScore.Inputs(deep: 100, rem: 100, light: 300, awake: 10, asleep: 500, span: 510,
                                       hasAwakeSignal: true)
        let withOverride = SleepScore.score(inputs, v2: true).score
        SleepScoreConfig.install(nil)
        let compiled = SleepScore.score(inputs, v2: true).score
        XCTAssertNotEqual(withOverride, compiled, "an installed override must be able to move the score")
        SleepScoreConfig.install(nil)
    }

    func testAFailedFetchKeepsThePreviousModel() async {
        let cached = SleepScoreConfig.Cache.encode(value: good(), model: 2, version: 3, appliedAt: Date(timeIntervalSince1970: 0))
        SleepScoreConfig.install(SleepScoreConfig.Cache.model(raw: cached))
        let next = await SleepScoreConfig.refresh(fetch: { _ in nil }, raw: cached, now: Date())
        XCTAssertNil(next, "nothing is written when the fetch fails")
        XCTAssertEqual(SleepScoreConfig.active().durationWeight, 42, accuracy: 0.001)
        SleepScoreConfig.install(nil)
    }

    func testAnUnimplementedModelVersionDropsBackToTheCompiledDefault() async {
        SleepScoreConfig.install(SleepScore.Model(durationWeight: 99))
        let next = await SleepScoreConfig.refresh(
            fetch: { _ in ["model": 3, "version": 9, "value": ["durationWeight": 10.0]] }, raw: nil, now: Date())
        XCTAssertNotNil(next, "the rejection is cached so we do not re-fetch every launch")
        XCTAssertEqual(SleepScoreConfig.active().durationWeight, SleepScore.Model().durationWeight, accuracy: 0.001)
        SleepScoreConfig.install(nil)
    }
}
