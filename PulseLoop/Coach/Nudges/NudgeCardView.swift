import SwiftUI
import SwiftData

/// The one nudge card (Rule 10: Today's cards and the Coach tab's "For you" list are the same view, so a nudge can never
/// look like two different things in two places). Every button goes through `NudgeDeliveryService.shared.perform`, so a card tap
/// and a lock-screen button do exactly the same thing — and the ledger records it either way.
struct NudgeCardView: View {
    let nudge: CoachNudge
    var compact: Bool = false
    /// Called after a button's action ran (the inbox closes for "Why?" and "Open ring").
    var onPerformed: ((NudgeAction) -> Void)? = nil

    @State private var delivery = NudgeDeliveryService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The topic, then the message. The title is the body's first sentence (`CoachNudge.title(from:)`) — a push
            // needs it as its bold line, but on a card it printed the same sentence twice, and most templates are one
            // sentence long.
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(AgaraFont.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(topicLabel)
                    .font(AgaraFont.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }

            Text(nudge.body)
                .font(compact ? AgaraFont.subheadline.weight(.medium) : AgaraFont.body.weight(.medium))
                .foregroundStyle(AgaraColors.textPrimary)
                .lineSpacing(2)
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
            onPerformed?(action)
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

    /// What the card is about, in the words of the Notifications settings (the same topics the user can turn off).
    /// The sync check lives under "Patterns" there, which would read oddly on its card.
    private var topicLabel: String {
        nudge.rule == .g1 ? "Your ring" : NudgeTopic.topic(forRule: nudge.rule.rawValue, category: nudge.category).title
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
        // The sync check rides the activity category but is about the ring, not about moving.
        if nudge.rule == .g1 { return "arrow.triangle.2.circlepath" }
        return switch nudge.category {
        case .recovery: "battery.50percent"
        case .stress: "wind"
        case .goal, .activity: "figure.walk"
        case .celebration: "star.fill"
        case .insight: "chart.line.uptrend.xyaxis"
        }
    }
}

/// Everything the nudges know right now. ONE instance (`shared`) feeds the bell's badge and the inbox, so the two can
/// never disagree.
///
/// "Shown" means seen: the ledger records `.shown` when the inbox opens (`markSeen`), not when the engine computes a
/// nudge. The badge counts nudges with no ledger outcome yet — exactly "new since you last looked".
@MainActor
@Observable
final class NudgeFeed {
    static let shared = NudgeFeed()

    var nudges: [CoachNudge] = []
    var status: NudgeStatus = .ready
    /// The inbox is open: the root action host stands down so the inbox can present the confirmation itself.
    var inboxOpen = false

    func refresh(context: ModelContext, now: Date = Date()) {
        let provider = NudgeEngine.provider()
        nudges = provider.pending(now: now, context: context)
        status = provider.status(now: now, context: context)
    }

    /// Nudges the user has not seen yet (no ledger outcome). Reads the ledger's revision so the badge updates.
    var unseenCount: Int {
        _ = NudgeLedgerStore.shared.revision
        return nudges.filter { NudgeLedgerStore.shared.outcome(for: $0.id) == nil }.count
    }

    func markSeen(now: Date = Date()) {
        for nudge in nudges where NudgeLedgerStore.shared.outcome(for: nudge.id) == nil {
            NudgeLedgerStore.shared.record(nudge, outcome: .shown, now: now)
        }
    }
}

/// The bell in the app header: nudges live behind it, with a count of the ones not seen yet (owner 2026-10-22: "like
/// Facebook notifications" — full-width cards on Today and the Coach tab took the whole screen). It also owns the
/// feed's refresh, because it is on every tab.
struct NudgeBellButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = NudgeFeed.shared
    @State private var ledger = NudgeLedgerStore.shared
    @State private var dataChange = AgaraDataChange.shared
    /// Push a route from the inbox (its footer opens Settings › Notifications).
    var onOpenRoute: (AppRoute) -> Void = { _ in }

    var body: some View {
        Button { feed.inboxOpen = true } label: {
            Image(systemName: feed.unseenCount > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(.hierarchical)
                .font(AgaraFont.body.weight(.regular))
                .foregroundStyle(AgaraColors.textSecondary)
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if feed.unseenCount > 0 {
                        Text("\(min(feed.unseenCount, 9))")
                            .font(AgaraFont.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(AgaraColors.onAccent)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Circle().fill(AgaraColors.accent))
                            .overlay(Circle().stroke(AgaraColors.background, lineWidth: 2))
                            .offset(x: -2, y: 3)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .animation(.spring(duration: 0.3), value: feed.unseenCount)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nudge.bell")
        .accessibilityLabel("Nudges")
        .accessibilityValue(feed.unseenCount == 0 ? "No new nudges"
                            : feed.unseenCount == 1 ? "1 new nudge" : "\(feed.unseenCount) new nudges")
        .task { feed.refresh(context: modelContext) }
        // Answering a nudge, new ring data, and coming back to the app all re-read the engine.
        .onChange(of: ledger.revision) { _, _ in feed.refresh(context: modelContext) }
        .onChange(of: dataChange.token) { _, _ in feed.refresh(context: modelContext) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { feed.refresh(context: modelContext) } }
        .sheet(isPresented: $feed.inboxOpen) {
            NudgeInboxSheet(onOpenRoute: onOpenRoute)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .agaraRingEnvironment()   // every presentation root (AgaraRingEnvironment, the 1.0.0 (1) crash)
        }
    }
}

/// The nudges, behind the bell: the same cards and buttons, most important first. Opening it marks them seen.
struct NudgeInboxSheet: View {
    var onOpenRoute: (AppRoute) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var feed = NudgeFeed.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if feed.nudges.isEmpty {
                        emptyState
                    } else {
                        ForEach(feed.nudges) { nudge in
                            // "Why?" and "Open ring" leave for another screen: close the inbox first.
                            NudgeCardView(nudge: nudge) { action in
                                if action == .why || action == .openRing { dismiss() }
                            }
                        }
                    }
                    Button {
                        dismiss()
                        onOpenRoute(.settingsNotifications)
                    } label: {
                        Label("Notification settings", systemImage: "slider.horizontal.3")
                            .font(AgaraFont.footnote.weight(.medium))
                            .foregroundStyle(AgaraColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("nudge.inbox.settings")
                }
                .padding(16)
            }
            .background(AgaraColors.background)
            .navigationTitle("Nudges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("nudge.inbox.done")
                }
            }
        }
        // The inbox presents the lighter-today confirmation and the breathing session itself; the root host stands
        // down while it is open (an alert from under a sheet never appears).
        .nudgeActionHost(active: true)
        .onAppear { feed.markSeen() }
        .onDisappear { feed.inboxOpen = false }
        .accessibilityIdentifier("nudge.inbox")
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bell")
                .font(AgaraFont.title3)
                .foregroundStyle(AgaraColors.textMuted)
            if feed.status.learningBaseline {
                Text(AgaraCopy.nudgeLearningBaseline)
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                Text(AgaraCopy.nudgeLearningBaselineBody)
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textSecondary)
            } else {
                Text("Nothing right now")
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                Text("Nudges appear here when your ring's data says something worth acting on.")
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgaraColors.cardSoft))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(feed.status.learningBaseline ? "nudge.learningBaseline" : "nudge.inbox.empty")
    }
}

struct NudgeActionHost: ViewModifier {
    /// The root host is active unless the inbox is open; the inbox's own host is always active.
    var active: Bool? = nil
    @State private var delivery = NudgeDeliveryService.shared
    @State private var feed = NudgeFeed.shared
    @State private var pendingConfirm: ConfirmAction?
    @Environment(\.modelContext) private var modelContext

    private var isActive: Bool { active ?? !feed.inboxOpen }

    func body(content: Content) -> some View {
        content
            .onChange(of: delivery.confirmingLighter) { _, nudge in
                guard isActive, let nudge else { return }
                pendingConfirm = ConfirmAction.lighterToday(percent: delivery.lighterPercent) { [delivery] in
                    DailyGoalOverrideStore.shared.set(percent: delivery.lighterPercent)
                    NudgeLedgerStore.shared.record(nudge, outcome: .madeLighter)
                    delivery.confirmingLighter = nil
                }
            }
            .confirmAction($pendingConfirm)
            .sheet(item: Binding(get: { isActive ? delivery.breathingFor : nil },
                                 set: { delivery.breathingFor = $0 })) { nudge in
                BreathingSessionView()
                    .onDisappear { NudgeLedgerStore.shared.record(nudge, outcome: .breathed) }
                    .agaraRingEnvironment()
            }
    }
}

extension View {
    /// Attach once, at the tab root: hosts the lighter-today confirmation and the breathing sheet for every nudge button.
    func nudgeActionHost() -> some View { modifier(NudgeActionHost()) }
    /// The inbox's own host (always active while the inbox is open).
    func nudgeActionHost(active: Bool) -> some View { modifier(NudgeActionHost(active: active)) }
}
