import SwiftUI
import SwiftData

/// The message the Coach tab opens with when a nudge (or its "Why?") is tapped: already written, carrying the evidence
/// numbers, one chart spec and three suggested questions. Opening this card costs 0 tokens — the model runs only if the
/// user then sends one of the suggestions (or types their own).
struct CoachSeed: Equatable, Identifiable {
    let rule: String
    let title: String
    let message: String
    var facts: [NudgeFact] = []
    var chart: CoachChart?
    var suggestions: [String] = []

    var id: String { "seed.\(rule).\(message.hashValue)" }

    init(rule: String, title: String, message: String, facts: [NudgeFact] = [],
         chart: CoachChart? = nil, suggestions: [String]? = nil) {
        self.rule = rule
        self.title = title
        self.message = message
        self.facts = facts
        self.chart = chart
        self.suggestions = suggestions ?? CoachSeed.suggestions(forRule: rule)
    }

    /// A card tap carries the whole evidence bundle.
    init(_ nudge: CoachNudge) {
        self.init(rule: nudge.ruleID, title: nudge.title, message: nudge.seedMessage,
                  facts: nudge.evidencePayload.facts, chart: nudge.evidencePayload.chart)
    }

    /// Three questions per rule, so the seeded answer is a conversation and not a dead end. Wellness wording only.
    static func suggestions(forRule rule: String) -> [String] {
        switch rule {
        case "a1", "a2":
            ["Is it okay to train today?", "What should I do differently tonight?", "How long until I catch up on sleep?"]
        case "a3":
            ["What session fits how I slept?", "How hard can I push today?", "What keeps this level?"]
        case "b1", "b2":
            ["How long a walk do I need?", "Does an evening walk affect sleep?", "How many steps do I average?"]
        case "b3":
            ["How long should I move for?", "What is a good break at my desk?", "How does sitting affect my sleep?"]
        case "b4", "f1":
            ["How does this week compare with my usual?", "What keeps the streak going?", "Should I add distance?"]
        case "c1":
            ["What usually lowers my stress?", "Does breathing change my heart rate?", "How was my stress this week?"]
        case "e1":
            ["Does bedtime change matter for me?", "How do I move my bedtime earlier?", "How regular was last week?"]
        case "e2":
            ["What changed over the last two weeks?", "How do I keep this going?", "Which metric improved most?"]
        case "f2":
            ["What went well this week?", "What should I change next week?", "How were my sleep and steps?"]
        case "g1":
            ["Why does my ring stop syncing?", "How often should it sync?", "What does the ring need to connect?"]
        default:
            ["What does this mean for me?", "What should I do next?", "How was my week?"]
        }
    }
}

/// The seeded answer card at the top of the Coach thread. Rendered entirely from the seed — no model call, no network,
/// no consent needed — and built from the same blocks as a chat answer (facts, the one chart component, suggestion
/// chips). `CoachView` drops it into the thread's top; sending a suggestion replaces it with the real conversation.
struct CoachSeedCard: View {
    let seed: CoachSeed
    var onAsk: (String) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.accent)
                Text(seed.title.isEmpty ? "From your ring" : seed.title)
                    .font(AgaraFont.caption.weight(.semibold))
                    .foregroundStyle(AgaraColors.textSecondary)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("coach.seed.dismiss")
            }

            Text(seed.message)
                .font(AgaraFont.body)
                .foregroundStyle(AgaraColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("coach.seed.message")

            if !seed.facts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(seed.facts) { fact in
                        HStack(spacing: 6) {
                            Text(fact.label)
                                .foregroundStyle(AgaraColors.textMuted)
                            Spacer(minLength: 8)
                            Text(fact.value)
                                .foregroundStyle(AgaraColors.textPrimary)
                        }
                        .font(AgaraFont.caption)
                    }
                }
            }

            if let chart = seed.chart {
                // The one chart component (Rule 10): scrub, tooltip, empty state and accessibility all come with it.
                CoachChartView(chart: chart, height: 140)
            }

            if !seed.suggestions.isEmpty {
                // The coach's one "ask this next" component (Rule 10), like every answer's follow-ups: orange pills here
                // made the same job look like a different thing.
                CoachSuggestionList(questions: seed.suggestions, identifier: "coach.seed.question") { onAsk($0) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgaraColors.card))
        // A container, not one element: without this the card's identifier was pushed down onto every child and
        // overwrote `coach.seed.message` (and VoiceOver could not reach the questions one by one).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.seed.card")
    }
}
