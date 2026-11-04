import XCTest
@testable import PulseLoop

/// Sleep-score v1 → v2 cross-platform contract, and the evidence for item E of
/// `docs/process/plans/asana-heart-bugs-2026-11-01.md`.
///
/// The expected numbers are **the Android bench's output** (`SleepScoreBenchTest` in PulseLoopAndroid, which
/// writes `app/build/sleep-score-bench.md`). Asserting them here is the parity proof Rule 2 asks for: the two
/// platforms must produce the same score for the same night, under both models.
///
/// The rollout rule (owner 2026-11-01) is covered too: v2 ships behind `sleep_score_v2`, so with the flag off
/// the app must show the v1 column.
final class SleepScoreBenchTests: XCTestCase {

    private struct Night {
        let name: String
        let asleep: Int, awake: Int, deep: Int, rem: Int, light: Int
        var unlabelled = 0
        let v1: Int, v2: Int
        var estimated = false
        var span: Int { asleep + awake + unlabelled }
        var inputs: SleepScore.Inputs {
            SleepScore.Inputs(
                deep: Double(deep), rem: Double(rem), light: Double(light), awake: Double(awake),
                asleep: Double(asleep), span: Double(span),
                // The ring's own heuristic: an AWAKE block exists, or the labelled minutes cover the span.
                hasAwakeSignal: awake > 0 || deep + rem + light >= Int((Double(span) * 0.95).rounded())
            )
        }
    }

    private let nights: [Night] = [
        Night(name: "Ideal 7 h 51 m, deep 16 %, REM 22 %", asleep: 471, awake: 9, deep: 77, rem: 106, light: 288, v1: 81, v2: 98),
        Night(name: "REM-rich: deep 18 % + REM 25 %", asleep: 480, awake: 10, deep: 86, rem: 120, light: 274, v1: 74, v2: 99),
        Night(name: "REM-rich, high SWS: deep 20 % + REM 26 %", asleep: 480, awake: 10, deep: 96, rem: 125, light: 259, v1: 70, v2: 100),
        Night(name: "Short but perfectly balanced: 5 h", asleep: 300, awake: 10, deep: 45, rem: 60, light: 195, v1: 67, v2: 69),
        Night(name: "Short: 4 h 30 m", asleep: 270, awake: 15, deep: 40, rem: 54, light: 176, v1: 64, v2: 54),
        Night(name: "Long: 10 h 30 m", asleep: 630, awake: 20, deep: 108, rem: 145, light: 377, v1: 58, v2: 74),
        Night(name: "No REM reported (capability gap)", asleep: 460, awake: 20, deep: 74, rem: 0, light: 386, v1: 85, v2: 88),
        Night(name: "Unlabelled quarter, never labels awake", asleep: 360, awake: 0, deep: 60, rem: 0, light: 300, unlabelled: 120, v1: 67, v2: 67, estimated: true),
        Night(name: "Zero labelled deep sleep", asleep: 480, awake: 20, deep: 0, rem: 96, light: 384, v1: 89, v2: 71),
        Night(name: "Boundary: 7 h 30 m, deep 23 %, awake 10 %", asleep: 450, awake: 50, deep: 104, rem: 112, light: 234, v1: 70, v2: 100),
    ]

    /// The two models agree with Android, row for row, on every fixture.
    func testScoresMatchAndroidRowForRow() {
        for night in nights {
            XCTAssertEqual(SleepScore.scoreV1(night.inputs).score, night.v1,
                           "\(night.name): v1 must match Android's \(night.v1)")
            let v2 = SleepScore.scoreV2(night.inputs)
            XCTAssertEqual(v2.score, night.v2, "\(night.name): v2 must match Android's \(night.v2)")
            XCTAssertEqual(v2.estimated, night.estimated, "\(night.name): estimated flag")
        }
    }

    /// The rollout rule: `sleep_score_v2` ships off, and the flag really selects the scorer.
    func testFlagSelectsTheScorerAndShipsOff() {
        XCTAssertFalse(SleepScore.v2Enabled, "sleep_score_v2 must ship off (owner 2026-11-01)")
        for night in nights {
            XCTAssertEqual(SleepScore.score(night.inputs).score, night.v1,
                           "\(night.name): flag off must show v1")
            XCTAssertEqual(SleepScore.score(night.inputs, v2: true).score, night.v2,
                           "\(night.name): flag on must show v2")
        }
    }

    /// REM is its own share now — the v1 defect was counting it inside deep as well.
    func testRemIsReportedSeparately() {
        let night = Night(name: "shares", asleep: 500, awake: 0, deep: 75, rem: 100, light: 325, v1: 0, v2: 0)
        let result = SleepScore.scoreV2(night.inputs)
        XCTAssertEqual(result.deepPct, 15, "deep share is DEEP only (75/500)")
        XCTAssertEqual(result.remPct, 20, "REM has its own share (100/500)")
        XCTAssertEqual(result.lightPct, 65, "light share (325/500)")
        XCTAssertNotEqual(result.deepPct, 35, "REM must not be added to the deep share")
        XCTAssertEqual(SleepScore.scoreV1(night.inputs).deepPct, 35, "v1 folded REM in — the documented defect")
    }

    /// A model override changes the score, and the day score applies the model it is given.
    func testModelOverrideIsHonoured() {
        let night = nights[0]
        var model = SleepScore.Model()
        model.lightWeight = 0
        model.floorScore = 0
        model.shortHours6 = 0
        model.shortHours5 = 0
        XCTAssertNotEqual(SleepScore.scoreV2(night.inputs).score,
                          SleepScore.scoreV2(night.inputs, model: model).score,
                          "the weights must matter, or the model is decoration")
    }

    /// No stage blocks at all is missing data, not a perfect night.
    func testNoBlocksScoresLowAndIsNotEstimated() {
        let inputs = SleepScore.Inputs(asleep: 420, span: 420)
        let result = SleepScore.scoreV2(inputs)
        XCTAssertLessThan(result.score, 60, "no stage data must not read as a good night")
        XCTAssertFalse(result.estimated, "missing stage data is not an estimate")
    }
}
