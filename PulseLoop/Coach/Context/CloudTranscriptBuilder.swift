import Foundation

/// One prior exchange as it travels to the cloud: `{"role", "text"}` (contract §6). Tool calls and
/// tool output are not part of it — the model re-derives those with tools when it needs them.
struct CoachTurnText: Equatable {
    /// "user" | "assistant"
    let role: String
    let text: String
}

/// The `history` + `summary` pair of a coach turn (`docs/ring/coach-proxy.md` §6): at most
/// `coach_history_turns` messages, oldest first, with a rolling summary standing in for everything
/// older than that window.
struct CoachCloudTranscript: Encodable, Equatable {
    var history: [Message]
    var summary: String?

    struct Message: Encodable, Equatable {
        var role: String
        var text: String
    }
}

enum CoachTranscriptWindow {
    /// The catalog cap on replayed messages. The contract fixes it (`coach_history_turns`, 10); the
    /// on-device model keeps its smaller budget.
    static func limit(for budget: CoachContextBudget) -> Int {
        budget == .compact ? min(budget.historyTurns, AgaraConfig.Coach.historyTurns) : AgaraConfig.Coach.historyTurns
    }

    /// The newest `limit` messages, in chronological order (the tail is kept, as the server does).
    static func tail<T>(_ messages: [T], limit: Int) -> [T] {
        limit <= 0 ? [] : Array(messages.suffix(limit))
    }

    /// A turn's `history` + `summary`. Pass the conversation's rolling summary; pass nil when there is
    /// none yet (the request then carries `history` only).
    static func transcript(_ messages: [CoachTurnText], summary: String?, budget: CoachContextBudget = .full) -> CoachCloudTranscript {
        CoachCloudTranscript(
            history: tail(messages, limit: limit(for: budget)).map { .init(role: $0.role, text: $0.text) },
            summary: summary
        )
    }
}

/// The rolling conversation summary stored on `CoachConversation` and sent as the turn's `summary`.
///
/// Refreshed every `AgaraConfig.Coach.summaryEveryTurns` answers, not on every turn: the point is to
/// stand in for the turns that fall out of the 10-message window, and rebuilding it costs a write per
/// answer without adding anything the window does not already carry.
///
/// It is **extractive** — the app condenses the stored messages itself instead of asking the model to
/// summarise. A model-written summary would be a second paid round trip per refresh with its own
/// failure mode, and the text it replaces is what the user already sees on screen.
enum CoachRollingSummary {
    /// How many characters of a message survive into the summary.
    static let excerptCharacters = 110
    /// Character budget for the whole summary (older context is dropped first).
    static let summaryCharacters = 700

    static var refreshEveryTurns: Int { max(1, AgaraConfig.Coach.summaryEveryTurns) }

    /// True once `refreshEveryTurns` answers have been recorded that the stored summary does not cover.
    static func shouldRefresh(answerCount: Int, summarizedAnswerCount: Int) -> Bool {
        guard answerCount > summarizedAnswerCount else { return false }
        return answerCount - summarizedAnswerCount >= refreshEveryTurns
    }

    /// Rebuild the summary from the conversation's messages, keeping the newest exchanges and carrying
    /// the previous summary forward (truncated) so nothing said early in a long conversation is lost.
    static func make(previous: String?, turns: [CoachTurnText]) -> String {
        var block = "Earlier in this conversation:"
        if let previous = previous?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            block += "\n" + "  " + truncate(previous, to: 240)
        }
        let lines = turns.compactMap { turn -> String? in
            // A compact single line per exchange: the role, then the message's opening words.
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !text.isEmpty else { return nil }
            let label = turn.role == "assistant" ? "coach" : "user"
            // The label is inside the text, so a message can never pass itself off as the other role.
            return "- \(label): " + truncate(text, to: excerptCharacters)
        }
        guard !lines.isEmpty else { return block }
        block += "\n" + lines.joined(separator: "\n")
        return String(block.prefix(summaryCharacters))
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
