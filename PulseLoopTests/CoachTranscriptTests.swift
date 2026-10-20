import Foundation
import SwiftData
import XCTest
@testable import PulseLoop

/// The turn's `history` + `summary` (contract §6): at most `coach_history_turns` messages, and a
/// rolling summary that is rebuilt every `coach_summary_every_turns` answers and stored on the
/// conversation.
final class CoachTranscriptTests: XCTestCase {
    // MARK: - Window

    func testWindowKeepsTheNewestMessagesInChronologicalOrder() {
        let turns = (1...25).map { CoachTurnText(role: $0.isMultiple(of: 2) ? "assistant" : "user", text: "m\($0)") }
        let transcript = CoachTranscriptWindow.transcript(turns, summary: "Earlier: m0.")
        XCTAssertEqual(transcript.history.count, AgaraConfig.Coach.historyTurns)
        XCTAssertEqual(transcript.history.first?.text, "m\(25 - AgaraConfig.Coach.historyTurns + 1)")
        XCTAssertEqual(transcript.history.last?.text, "m25")
        XCTAssertEqual(transcript.history.map(\.text), transcript.history.map(\.text).sorted { a, b in
            (Int(a.dropFirst()) ?? 0) < (Int(b.dropFirst()) ?? 0)
        })
    }

    func testShortConversationIsSentWholeAndKeepsTheSummary() {
        let turns = [
            CoachTurnText(role: "user", text: "how did I sleep?"),
            CoachTurnText(role: "assistant", text: "You slept 6h 42m."),
        ]
        let transcript = CoachTranscriptWindow.transcript(turns, summary: "Earlier: goals set to 9000 steps.")
        XCTAssertEqual(transcript.history.map(\.role), ["user", "assistant"])
        XCTAssertEqual(transcript.summary, "Earlier: goals set to 9000 steps.")
    }

    func testLimitComesFromTheCatalogAndTheOnDeviceBudget() {
        XCTAssertEqual(CoachTranscriptWindow.limit(for: .full), AgaraConfig.Coach.historyTurns)
        XCTAssertEqual(
            CoachTranscriptWindow.limit(for: .compact),
            min(CoachContextBudget.compact.historyTurns, AgaraConfig.Coach.historyTurns))
        XCTAssertTrue(CoachTranscriptWindow.tail([Int](1...20), limit: 0).isEmpty)
    }

    /// The encoded turn body the client posts: snake_case-free by contract (`role`/`text`), and the
    /// summary rides beside the array.
    func testTranscriptEncodesAsHistoryAndSummary() throws {
        let transcript = CoachTranscriptWindow.transcript(
            [CoachTurnText(role: "user", text: "hi")], summary: "Earlier: nothing yet.")
        let data = try JSONEncoder().encode(transcript)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["summary"] as? String, "Earlier: nothing yet.")
        let history = try XCTUnwrap(object["history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["role"] as? String, "user")
        XCTAssertEqual(history.first?["text"] as? String, "hi")
        XCTAssertEqual(Set(history.first?.keys.map { $0 } ?? []), ["role", "text"])
    }

    // MARK: - Refresh cadence

    func testRefreshIsDueEverySummaryEveryTurnsAnswers() {
        let every = AgaraConfig.Coach.summaryEveryTurns
        XCTAssertEqual(CoachRollingSummary.refreshEveryTurns, every)
        XCTAssertFalse(CoachRollingSummary.shouldRefresh(answerCount: every - 1, summarizedAnswerCount: 0))
        XCTAssertTrue(CoachRollingSummary.shouldRefresh(answerCount: every, summarizedAnswerCount: 0))
        XCTAssertFalse(CoachRollingSummary.shouldRefresh(answerCount: every + 3, summarizedAnswerCount: every))
        XCTAssertTrue(CoachRollingSummary.shouldRefresh(answerCount: every * 2, summarizedAnswerCount: every))
        // Nothing new since the last refresh: never rewrite the stored summary.
        XCTAssertFalse(CoachRollingSummary.shouldRefresh(answerCount: every, summarizedAnswerCount: every))
    }

    func testSummaryQuotesBothSidesAndCarriesThePreviousSummaryForward() {
        let previous = "Earlier: the user set a 9000-step goal."
        let summary = CoachRollingSummary.make(
            previous: previous,
            turns: [
                CoachTurnText(role: "user", text: "how did I sleep?"),
                CoachTurnText(role: "assistant", text: "You slept 6h 42m against an 8h goal.\n\nSecond paragraph."),
            ])
        XCTAssertTrue(summary.contains(previous))
        XCTAssertTrue(summary.contains("- user: how did I sleep?"))
        XCTAssertTrue(summary.contains("- coach: You slept 6h 42m against an 8h goal. Second paragraph."))
        XCTAssertLessThanOrEqual(summary.count, CoachRollingSummary.summaryCharacters)
    }

    func testSummaryBoundsAreEnforcedOnLongConversations() {
        let turns = (1...80).map {
            CoachTurnText(role: $0.isMultiple(of: 2) ? "assistant" : "user", text: String(repeating: "word ", count: 60))
        }
        let summary = CoachRollingSummary.make(previous: String(repeating: "p", count: 2000), turns: turns)
        XCTAssertLessThanOrEqual(summary.count, CoachRollingSummary.summaryCharacters)
        XCTAssertTrue(summary.contains("- coach:"), "the newest exchanges stay in the summary")
    }

    // MARK: - Stored on the conversation, and sent with the turn

    @MainActor
    func testViewModelStoresTheSummaryAndSendsItWithTheNextTurn() async throws {
        let context = try TestSupport.makeContext()
        let conversation = CoachConversation()
        context.insert(conversation)
        let assistantBody = "You slept 6h 42m."
        // Enough stored answers that the next turn is due a refresh, all older than the new turn.
        for index in 0..<AgaraConfig.Coach.summaryEveryTurns {
            context.insert(CoachMessage(
                conversationId: conversation.id, role: "user", body: "question \(index)",
                createdAt: TestSupport.day(0).addingTimeInterval(Double(index * 2))))
            context.insert(CoachMessage(
                conversationId: conversation.id, role: "assistant", body: assistantBody,
                createdAt: TestSupport.day(0).addingTimeInterval(Double(index * 2 + 1))))
        }
        try context.save()

        let viewModel = CoachViewModel()
        viewModel.refreshRollingSummary(conversationId: conversation.id, context: context)

        let stored = try XCTUnwrap(fetch(conversation.id, context: context))
        let summary = try XCTUnwrap(stored.rollingSummary)
        XCTAssertTrue(summary.contains("coach: \(assistantBody)"))
        XCTAssertEqual(stored.summarizedAnswerCount, AgaraConfig.Coach.summaryEveryTurns)

        // The next turn's packet carries it, which is what the cloud client sends as `summary`.
        let packet = CoachContextBuilder.build(context: context, conversationSummary: stored.rollingSummary)
        XCTAssertEqual(packet.conversationSummary, summary)
        let transcript = CoachTranscriptWindow.transcript(
            recentTurns(context: context, conversationId: conversation.id), summary: packet.conversationSummary)
        XCTAssertEqual(transcript.summary, summary)
        XCTAssertLessThanOrEqual(transcript.history.count, AgaraConfig.Coach.historyTurns)
    }

    @MainActor
    func testNoSummaryIsWrittenBeforeTheRefreshInterval() throws {
        let context = try TestSupport.makeContext()
        let conversation = CoachConversation()
        context.insert(conversation)
        for index in 0..<(AgaraConfig.Coach.summaryEveryTurns - 1) {
            context.insert(CoachMessage(conversationId: conversation.id, role: "assistant", body: "answer \(index)"))
        }
        try context.save()

        CoachViewModel().refreshRollingSummary(conversationId: conversation.id, context: context)

        let stored = try XCTUnwrap(fetch(conversation.id, context: context))
        XCTAssertNil(stored.rollingSummary)
        XCTAssertEqual(stored.summarizedAnswerCount, 0)
    }

    // MARK: - Helpers

    @MainActor
    private func fetch(_ id: UUID, context: ModelContext) -> CoachConversation? {
        try? context.fetch(FetchDescriptor<CoachConversation>(predicate: #Predicate { $0.id == id })).first
    }

    @MainActor
    private func recentTurns(context: ModelContext, conversationId: UUID) -> [CoachTurnText] {
        let rows = (try? context.fetch(FetchDescriptor<CoachMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
        return rows.filter { $0.role == "user" || $0.role == "assistant" }
            .map { CoachTurnText(role: $0.role, text: $0.body) }
    }
}
