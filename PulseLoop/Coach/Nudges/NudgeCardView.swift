import SwiftUI
import SwiftData

/// The one nudge card (Rule 10: Today's cards and the Coach tab's "For you" list are the same view, so a nudge can never
/// look like two different things in two places). Every button goes through `NudgeDeliveryService.shared.perform`, so a card tap
/// and a lock-screen button do exactly the same thing — and the ledger records it either way.
struct NudgeCardView: View {
    let nudge: CoachNudge
    var compact: Bool = false

    @State private var delivery = NudgeDeliveryService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(AgaraFont.caption)
                    .foregroundStyle(tint)
                Text(nudge.title)
                    .font(compact ? AgaraFont.subheadline.weight(.semibold) : AgaraFont.headline)
                    .foregroundStyle(AgaraColors.textPrimary)
                Spacer(minLength: 0)
            }

            Text(nudge.body)
                .font(compact ? AgaraFont.footnote : AgaraFont.body)
                .foregroundStyle(AgaraColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !facts.isEmpty, !compact {
                HStack(spacing: 14) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.value).font(AgaraFont.subheadline.weight(.semibold))
                                .foregroundStyle(AgaraColors.textPrimary)
                            Text(fact.label).font(AgaraFont.caption2)
                                .foregroundStyle(AgaraColors.textMuted)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if !nudge.buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(nudge.buttons.enumerated()), id: \.element) { index, action in
                        button(for: action, isPrimary: index == 0)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgaraColors.card))
        // The card is a container, not one element: its buttons must stay individually pressable (and findable) from
        // VoiceOver and from the UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(nudge.cardIdentifier)
    }

    /// The evidence, built once per render rather than inside the view builder.
    private var facts: [NudgeFact] { nudge.evidencePayload.facts }

    /// One action button. Primary = the action the nudge is asking for (filled); the rest are secondary (tinted).
    @ViewBuilder
    private func button(for action: NudgeAction, isPrimary: Bool) -> some View {
        Button {
            delivery.perform(action, on: nudge)
        } label: {
            Text(action.title)
                .font(AgaraFont.caption.weight(.semibold))
                .foregroundStyle(isPrimary ? AgaraColors.onAccent : AgaraColors.accent)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(isPrimary ? AgaraColors.accent : AgaraColors.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(nudge.actionIdentifier(action))
    }

    private var tint: Color {
        switch nudge.category {
        case .recovery: AgaraColors.readiness
        case .stress: AgaraColors.stress
        case .goal, .activity: AgaraColors.steps
        case .celebration: AgaraColors.success
        case .insight: AgaraColors.info
        }
    }

    private var symbol: String {
        switch nudge.category {
        case .recovery: "battery.50percent"
        case .stress: "wind"
        case .goal, .activity: "figure.walk"
        case .celebration: "star.fill"
        case .insight: "chart.line.uptrend.xyaxis"
        }
    }
}

/// Everything the nudges know right now, read once per pass. One loader for Today and the Coach tab, so the two lists
/// cannot disagree.
@MainActor
@Observable
final class NudgeFeed {
    var nudges: [CoachNudge] = []
    var status: NudgeStatus = .ready

    func refresh(context: ModelContext, now: Date = Date()) {
        let provider = NudgeEngine.provider()
        nudges = provider.pending(now: now, context: context)
        status = provider.status(now: now, context: context)
        for nudge in nudges where NudgeLedgerStore.shared.outcome(for: nudge.id) == nil {
            NudgeLedgerStore.shared.record(nudge, outcome: .shown, now: now)
        }
    }
}

/// The Today cards. Silent when nothing passes the policy, and "Learning your baseline" while the 28-day median has
/// fewer than seven nights — the honest state rather than an empty-looking section.
struct NudgeTodaySection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var feed = NudgeFeed()
    @State private var ledger = NudgeLedgerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feed.status.learningBaseline {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AgaraCopy.nudgeLearningBaseline)
                        .font(AgaraFont.subheadline.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text(AgaraCopy.nudgeLearningBaselineBody)
                        .font(AgaraFont.footnote)
                        .foregroundStyle(AgaraColors.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgaraColors.cardSoft))
                .accessibilityIdentifier("nudge.learningBaseline")
            }
            ForEach(feed.nudges) { nudge in
                NudgeCardView(nudge: nudge)
            }
        }
        .task { feed.refresh(context: modelContext) }
        // Answering a nudge (or snoozing its category) re-reads the engine, so the card goes away at once.
        .onChange(of: ledger.revision) { _, _ in feed.refresh(context: modelContext) }
    }
}

/// The Coach tab's "For you" list (policy rule 10: with notifications off, every nudge still appears here and on Today).
struct NudgeForYouList: View {
    @Environment(\.modelContext) private var modelContext
    @State private var feed = NudgeFeed()

    var body: some View {
        if !feed.nudges.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("For you")
                    .font(AgaraFont.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(AgaraColors.textMuted)
                    .accessibilityAddTraits(.isHeader)
                ForEach(feed.nudges.prefix(3)) { nudge in
                    NudgeCardView(nudge: nudge, compact: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .accessibilityIdentifier("nudge.forYou")
            .task { feed.refresh(context: modelContext) }
            .onChange(of: NudgeLedgerStore.shared.revision) { _, _ in feed.refresh(context: modelContext) }
        }
    }
}

/// The "Lighter today" host: the shared confirmation (Rule 10) in front of whatever screen the nudge lives on, plus the
/// breathing sheet. Mounted once — by `MainTabView` — so a push action and a card tap reach the same dialogs.
struct NudgeActionHost: ViewModifier {
    @State private var delivery = NudgeDeliveryService.shared
    @State private var pendingConfirm: ConfirmAction?
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .onChange(of: delivery.confirmingLighter) { _, nudge in
                guard let nudge else { return }
                pendingConfirm = ConfirmAction.lighterToday(percent: delivery.lighterPercent) { [delivery] in
                    DailyGoalOverrideStore.shared.set(percent: delivery.lighterPercent)
                    NudgeLedgerStore.shared.record(nudge, outcome: .madeLighter)
                    delivery.confirmingLighter = nil
                }
            }
            .confirmAction($pendingConfirm)
            .sheet(item: $delivery.breathingFor) { nudge in
                BreathingSessionView()
                    .onDisappear { NudgeLedgerStore.shared.record(nudge, outcome: .breathed) }
            }
    }
}

extension View {
    /// Attach once, at the tab root: hosts the lighter-today confirmation and the breathing sheet for every nudge button.
    func nudgeActionHost() -> some View { modifier(NudgeActionHost()) }
}
