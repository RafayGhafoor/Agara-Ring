import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// The Today coach card must not contradict the tiles beside it (plan `asana-heart-bugs-2026-11-01`, item C).
///
/// `CoachSummaryService.refreshTodayIfNeeded()` regenerates the stored card only when the data signature changed
/// **and** two hours have passed, so between refreshes the stored text describes an older day: the 2026-10-28
/// screenshot showed "1,238 steps … latest reading is 100 bpm" beside tiles reading 2,247 steps and 98 bpm.
///
/// Policy (D12, 2026-11-01): the card keeps the stored summary's own numbers — the generated prose embeds them, so a
/// live headline beside that prose would print two disagreeing sets of figures on one card — and instead states its
/// age ("Updated 47m ago", owner D2) from the same timestamp the heart-rate tile shows. Making the numbers live needs
/// the generator to stop embedding values in the prose; that is the follow-up in `docs/features/coach-card.md`.
final class CoachTodayCardTests: XCTestCase {

    @MainActor
    private func heartRateTile(_ value: Double, at timestamp: Date, now: Date) -> VitalCardViewModel {
        VitalsCardFactory.card(
            .heartRate,
            inputs: .init(hr: [MetricSample(timestamp: timestamp, value: value)], now: now),
            profile: .unknown,
            calibration: Calibration()
        )
    }

    @MainActor
    private func storedSummary(context: ModelContext, title: String, body: String,
                              chips: [String] = ["Why?"]) -> CoachSummary {
        let row = CoachSummary(kind: "today", scopeKey: CoachDataAccess.localDateString(AppClock.now),
                               title: title, body: body, chips: chips, dataSignature: "stale")
        context.insert(row)
        try? context.save()
        return row
    }

    // MARK: - One set of figures on the card

    /// The regression the item was filed for: a card whose numbers disagree with themselves as well as the tiles.
    @MainActor
    func testTheCardKeepsTheStoredSummarysNumbersAndProse() throws {
        let context = try TestSupport.makeContext()
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let summary = storedSummary(
            context: context, title: "Building momentum",
            body: "You're at 1,238 steps, and your latest reading is 100 bpm."
        )
        let card = CoachTodayCard.make(
            summary: summary,
            heartRate: heartRateTile(98, at: now.addingTimeInterval(-47 * 60), now: now),
            showAge: true
        )
        XCTAssertEqual(card.headline, "Building momentum", "the stored title stands")
        XCTAssertEqual(card.body, summary.body, "the prose — and the figures inside it — stay the summary's")
        XCTAssertTrue(card.body.contains("1,238 steps"), "no second, live figure set is introduced")
        XCTAssertEqual(card.chips, ["Why?"])
        XCTAssertEqual(card.freshness, "Updated 47m ago",
                       "D2: the caption states the age of the reading behind the card, from the tile's own text")
    }

    /// The caption is the tile's own age text plus the catalog prefix — never a second clock over the timestamp.
    @MainActor
    func testTheCaptionIsTheTilesOwnAgeText() throws {
        let context = try TestSupport.makeContext()
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let tile = heartRateTile(98, at: now.addingTimeInterval(-2 * 3600), now: now)
        let summary = storedSummary(context: context, title: "Steady build", body: "Body.")
        let card = CoachTodayCard.make(summary: summary, heartRate: tile, showAge: true)

        let updated = try XCTUnwrap(tile.lastUpdatedText)
        XCTAssertEqual(card.freshness, "\(AgaraCopy.coachUpdatedPrefix) \(TodayTileContext.age(updated))")
        XCTAssertEqual(card.freshness, "Updated 2h ago")
    }

    /// Sample data carries invented timestamps, so the tiles hide their age — and so must the card.
    @MainActor
    func testSampleDataHidesTheCaption() throws {
        let context = try TestSupport.makeContext()
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let summary = storedSummary(context: context, title: "Building momentum", body: "Body.")
        let card = CoachTodayCard.make(
            summary: summary,
            heartRate: heartRateTile(98, at: now.addingTimeInterval(-47 * 60), now: now),
            showAge: false
        )
        XCTAssertNil(card.freshness)
        XCTAssertEqual(card.headline, "Building momentum")
    }

    /// No reading yet: nothing to state, and no invented age.
    @MainActor
    func testNoReadingMeansNoCaption() throws {
        let context = try TestSupport.makeContext()
        let summary = storedSummary(context: context, title: "Waiting for first sync", body: "Body.")
        let empty = VitalsCardFactory.card(
            .heartRate, inputs: .init(now: Date(timeIntervalSince1970: 1_792_000_000)),
            profile: .unknown, calibration: Calibration()
        )
        let card = CoachTodayCard.make(summary: summary, heartRate: empty, showAge: true)
        XCTAssertEqual(card.headline, "Waiting for first sync")
        XCTAssertNil(card.freshness)
    }

    /// The caption formatting itself, without a whole tile model.
    func testFreshnessFormatting() {
        XCTAssertEqual(CoachTodayCard.freshness(updatedText: "Updated 12m ago", showAge: true), "Updated 12m ago")
        XCTAssertNil(CoachTodayCard.freshness(updatedText: "Updated 12m ago", showAge: false))
        XCTAssertNil(CoachTodayCard.freshness(updatedText: nil, showAge: true))
    }

    /// Coach on, nothing generated yet: the card must make no data claims.
    @MainActor
    func testThePlaceholderMakesNoDataClaims() {
        let placeholder = CoachTodayCard.placeholder(isCalibrating: false)
        XCTAssertEqual(placeholder.headline, "Want a recap?")
        XCTAssertNil(placeholder.freshness)
        XCTAssertTrue(placeholder.chips.isEmpty)

        let calibrating = CoachTodayCard.placeholder(isCalibrating: true)
        XCTAssertEqual(calibrating.headline, "Baseline in progress")
        XCTAssertNil(calibrating.freshness)
    }
}
