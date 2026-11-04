import XCTest
@testable import PulseLoop

/// The breakdown a tap-through shows (E-P2). It must describe **the score that was actually computed**: only the
/// components in the denominator, points that add up, and an `earned` fraction that cannot disagree with the label.
final class SleepScoreComponentsTests: XCTestCase {

    private func inputs(deep: Double = 86, rem: Double = 120, light: Double = 274, awake: Double = 10,
                        asleep: Double = 480, span: Double = 490, hasAwake: Bool = true) -> SleepScore.Inputs {
        SleepScore.Inputs(deep: deep, rem: rem, light: light, awake: awake, asleep: asleep, span: span,
                          hasAwakeSignal: hasAwake)
    }

    func testEveryComponentAddsUpToTheScore() {
        let r = SleepScore.scoreV2(inputs())
        let points = r.components.reduce(0) { $0 + $1.points }
        let weight = r.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(Int(((points / weight) * 100).rounded()), r.score)
        XCTAssertEqual(r.components.map(\.id), ["duration", "deep", "rem", "light", "awake"])
    }

    func testAComponentTheRingCannotReportHasNoLineAtAll() {
        let noRem = SleepScore.scoreV2(inputs(rem: 0, light: 394))
        XCTAssertEqual(noRem.components.map(\.id), ["duration", "deep", "light", "awake"])
        let noAwake = SleepScore.scoreV2(inputs(hasAwake: false))
        XCTAssertEqual(noAwake.components.map(\.id), ["duration", "deep", "rem", "light"])
    }

    func testEarnedIsTheFractionOfTheWeightAndStaysInRange() {
        let r = SleepScore.scoreV2(inputs())
        for c in r.components {
            XCTAssertTrue(c.earned >= 0 && c.earned <= 1, "\(c.id): \(c.earned)")
            XCTAssertEqual(c.earned, c.points / c.weight, accuracy: 1e-9)
        }
        let perfect = SleepScore.scoreV2(inputs(deep: 96, rem: 110, light: 254, awake: 10))
        XCTAssertGreaterThan(perfect.components.first { $0.id == "deep" }!.earned, 0.99)
    }

    func testV1ExposesNoBreakdownRatherThanAWrongOne() {
        XCTAssertTrue(SleepScore.scoreV1(inputs()).components.isEmpty)
    }
}
