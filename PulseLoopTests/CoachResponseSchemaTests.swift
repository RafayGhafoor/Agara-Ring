import Foundation
import XCTest
@testable import PulseLoop

/// `follow_up_chips` is exactly 3 from 1.1 on (contract §8), while already-stored messages written by
/// the 1.0 coach — which allowed 0–2 — must still decode and render.
final class CoachResponseSchemaTests: XCTestCase {
    func testSchemaDemandsExactlyThreeFollowUps() throws {
        let properties = try XCTUnwrap(CoachResponseSchema.jsonSchema["properties"] as? [String: Any])
        let chips = try XCTUnwrap(properties["follow_up_chips"] as? [String: Any])
        XCTAssertEqual(chips["minItems"] as? Int, 3)
        XCTAssertEqual(chips["maxItems"] as? Int, 3)
        XCTAssertEqual(chips["minItems"] as? Int, AgaraConfig.Coach.followups)
        XCTAssertEqual(chips["maxItems"] as? Int, AgaraConfig.Coach.followups)
    }

    func testPromptInstructionStatesTheExactCount() {
        let instruction = CoachResponseSchema.promptInstruction
        XCTAssertTrue(instruction.contains("exactly 3"), instruction)
        XCTAssertTrue(instruction.contains("exactly 3 items"), instruction)
        XCTAssertFalse(instruction.contains("≤ 2 items"), instruction)
    }

    func testStoredTwoChipAnswerStillDecodes() throws {
        let json = """
        {"response_type":"insight","title":"Sleep","summary":"You slept 6h 42m.","bullets":[],\
        "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
        "follow_up_chips":["Why so short?","Tonight's plan"],"actions_taken":[],"confidence":"medium"}
        """
        let response = try XCTUnwrap(CoachResponse.decode(fromJSON: json))
        XCTAssertEqual(response.followUpChips, ["Why so short?", "Tonight's plan"])
    }

    func testThreeChipAnswerDecodesCompletely() throws {
        let json = """
        {"response_type":"insight","title":"Steps","summary":"4120 so far.","bullets":["a"],\
        "chart":null,"safety_note":null,"data_quality_note":null,"sources":[],\
        "follow_up_chips":["Close the gap","Compare with last week","Plan a walk"],\
        "actions_taken":[],"confidence":"high"}
        """
        let response = try XCTUnwrap(CoachResponse.decode(fromJSON: json))
        XCTAssertEqual(response.followUpChips.count, AgaraConfig.Coach.followups)
    }
}
