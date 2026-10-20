import XCTest
@testable import PulseLoop

/// The empty conversation's chips and the "always three follow-ups" rule.
@MainActor
final class CoachStarterPromptTests: XCTestCase {

    // MARK: - Exactly three follow-ups

    func testAnAnswerKeepsItsOwnThreeChips() {
        let chips = CoachFollowUpChips.balanced(["a", "b", "c"], fallback: ["x", "y"])
        XCTAssertEqual(chips, ["a", "b", "c"])
    }

    func testAShortAnswerIsToppedUpFromTheStarterPrompts() {
        XCTAssertEqual(CoachFollowUpChips.balanced(["only"], fallback: ["p", "q", "r"]), ["only", "p", "q"])
    }

    func testMoreThanThreeAreTruncated() {
        XCTAssertEqual(CoachFollowUpChips.balanced(["a", "b", "c", "d", "e"]).count, 3)
    }

    func testDuplicatesAndBlanksDoNotUseUpASlot() {
        let chips = CoachFollowUpChips.balanced(["a", " a ", ""], fallback: ["a", "b", "b", "c"])
        XCTAssertEqual(chips, ["a", "b", "c"])
    }

    func testNoChipsAnywhereIsAnEmptyRow() {
        XCTAssertEqual(CoachFollowUpChips.balanced([], fallback: []), [])
    }

    // MARK: - Starter prompts come from the data

    func testPromptsNameTheUsersOwnNumbers() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertActivity(date: Date(), steps: 4210, into: context)
        TestSupport.insertMeasurement(kind: .heartRate, value: 62, timestamp: Date(), into: context)

        let packet = CoachContextBuilder.build(context: context)
        let prompts = CoachStarterPrompts.make(packet: packet)

        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.contains { $0.contains("4,210") }, "got: \(prompts)")
        XCTAssertTrue(prompts.contains { $0.contains("62 bpm") }, "got: \(prompts)")
        XCTAssertFalse(prompts.contains(CoachCopy.starterNoData), "the ring delivered data — do not ask what is missing")
        XCTAssertEqual(prompts.count, Set(prompts).count, "no duplicate prompts")
    }

    func testAnEmptyDaySaysWhatIsMissingAndCapsAtTheLimit() throws {
        let context = try TestSupport.makeContext()
        let packet = CoachContextBuilder.build(context: context)
        let prompts = CoachStarterPrompts.make(packet: packet)

        XCTAssertEqual(prompts.first, CoachCopy.starterNoData, "no data at all — say so first")
        XCTAssertLessThanOrEqual(prompts.count, 4)
        XCTAssertTrue(prompts.contains(CoachCopy.starterWeek))
        // `limit` is honoured and never returns nothing.
        XCTAssertEqual(CoachStarterPrompts.make(packet: packet, limit: 1).count, 1)
    }
}
