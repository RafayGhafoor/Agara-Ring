import XCTest
import SwiftData
@testable import PulseLoop

/// The store → card seam, which is where a capture with 42,106 stored rows still rendered "No heart rate yet".
///
/// Two captures of the same binary disagreed (`VITALS init hr=0` vs `hr=480`), and in the second the frame was empty even
/// though `VitalsCardFactory.heartRate` marks a card empty only when `samples.count < 2`. This pins the code path so the
/// next investigation starts from "the seam is correct, so it is timing" rather than from a guess.
@MainActor
final class VitalsStoreCardTests: XCTestCase {

    /// Five ring samples inside the 24 h window produce a non-empty HR card, with the latest value on it.
    func testFiveRingSamplesMakeANonEmptyHeartRateCard() throws {
        try TestSupport.withClock("2026-09-24T19:30:00") {
            let context = try TestSupport.makeContext()
            let base = AppClock.now.addingTimeInterval(-3600)
            for i in 0..<5 {
                TestSupport.insertMeasurement(
                    kind: .heartRate, value: 60 + Double(i), timestamp: base.addingTimeInterval(Double(i * 60)),
                    source: .history, into: context
                )
            }

            let store = VitalsStore(modelContext: context)
            XCTAssertEqual(store.hrSamples.count, 5, "the store must load the window's samples")
            let card = try XCTUnwrap(store.cards[.heartRate], "a card exists for every metric")
            XCTAssertFalse(card.isEmpty, "five samples is past the `count < 2` gate, so the chart must render")
            XCTAssertEqual(card.valueText, "64", "the newest sample is the number on the card")
            XCTAssertEqual(card.unitText, "bpm")
        }
    }

    /// The boundary the gate encodes: one sample is NOT enough (a range of one is not context), two is.
    func testTheEmptyGateIsExactlyTwoSamples() throws {
        try TestSupport.withClock("2026-09-24T19:30:00") {
            let context = try TestSupport.makeContext()
            let now = AppClock.now
            TestSupport.insertMeasurement(kind: .heartRate, value: 61, timestamp: now.addingTimeInterval(-120),
                                               source: .history, into: context)
            XCTAssertTrue(VitalsStore(modelContext: context).cards[.heartRate]?.isEmpty ?? true,
                          "one sample stays empty")

            TestSupport.insertMeasurement(kind: .heartRate, value: 63, timestamp: now.addingTimeInterval(-60),
                                               source: .history, into: context)
            let two = VitalsStore(modelContext: context).cards[.heartRate]
            XCTAssertEqual(two?.isEmpty, false, "the second sample crosses the gate")
            XCTAssertEqual(two?.valueText, "63")
        }
    }

    /// A sample outside the window must not resurrect an empty card.
    func testSamplesOutsideTheWindowDoNotCount() throws {
        try TestSupport.withClock("2026-09-24T19:30:00") {
            let context = try TestSupport.makeContext()
            let longAgo = AppClock.now.addingTimeInterval(-3 * 24 * 3600)
            for i in 0..<5 {
                TestSupport.insertMeasurement(kind: .heartRate, value: 70, timestamp: longAgo.addingTimeInterval(Double(i)),
                                                   source: .history, into: context)
            }
            let store = VitalsStore(modelContext: context)
            XCTAssertTrue(store.hrSamples.isEmpty, "the 24 h window excludes them")
            XCTAssertEqual(store.cards[.heartRate]?.isEmpty, true)
        }
    }
}
