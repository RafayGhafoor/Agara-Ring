import SwiftUI

/// Onboarding → Syncing (consistency plan B): right after pairing, the ring's history comes down day by day.
/// One row per day (Today, Yesterday, …) fills in live with what arrived — steps, heart rate, SpO₂, HRV,
/// stress, sleep nights — from the one sync-progress model (`SyncProgress`). Never blocking: Continue is
/// always there and the sync keeps going in the background (the header bar, and a notification if the app is
/// left). Mirrors Android's onboarding Syncing screen.
struct OnboardingSyncingView: View {
    let next: () -> Void
    @State private var progress = SyncProgress.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CompactOnboardingHeader(title: title, subtitle: subtitle)
                    .padding(.top, 8)
                overall
                if progress.isSyncing {
                    Text("Syncing continues in the background if you carry on.")
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: 0) {
                    ForEach(progress.rows) { row in
                        dayRow(row)
                        if row.id != progress.rows.last?.id {
                            Divider().overlay(AgaraColors.borderSubtle).padding(.leading, 56)
                        }
                    }
                    if progress.rows.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView().tint(AgaraColors.accent)
                            Text("Connecting to your ring…")
                                .font(AgaraFont.subheadline)
                                .foregroundStyle(AgaraColors.textSecondary)
                            Spacer()
                        }
                        .padding(16)
                    }
                }
                .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.bottom, 96)   // clear of the floating Continue button
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Continue", systemImage: "arrow.right", action: next)
                    .accessibilityIdentifier("onboarding.syncing.continue")
            }
        }
        .accessibilityIdentifier("onboarding.syncing")
    }

    private var done: Bool { !progress.isSyncing && !progress.rows.isEmpty }
    private var title: String { done ? "Your ring is synced" : "Syncing your ring" }
    private var subtitle: String {
        done ? SyncProgress.summary(progress.totals, days: progress.totalDays)
             : "Bringing your recent days over from the ring. You can carry on — it keeps going."
    }

    private var overall: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: done ? 1 : progress.fraction)
                .tint(AgaraColors.accent)
                .animation(.easeInOut(duration: 0.3), value: progress.fraction)
            HStack {
                Text(progress.totalDays > 0 ? "\(progress.daysDone) of \(progress.totalDays) days" : "Starting…")
                Spacer()
                if let eta = progress.eta, eta >= 1 {
                    Text("About \(Int(eta.rounded(.up))) s left")
                }
            }
            .font(AgaraFont.caption.weight(.semibold))
            .foregroundStyle(AgaraColors.textMuted)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.syncing.progress")
    }

    private func dayRow(_ row: SyncProgress.DayRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph(row.status)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.label(for: row))
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                if row.status == .pending {
                    Text("Waiting")
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textMuted)
                } else {
                    counts(row.counts, live: row.status == .syncing)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync.day.\(row.day)")
    }

    @ViewBuilder
    private func statusGlyph(_ status: SyncProgress.DayStatus) -> some View {
        switch status {
        case .done:
            IconTile(systemName: "checkmark", style: .tinted(AgaraColors.success), size: .small, shape: .circle)
        case .syncing:
            ProgressView().tint(AgaraColors.accent)
        case .pending:
            IconTile(systemName: "clock", style: .tinted(AgaraColors.textMuted), size: .small, shape: .circle)
        }
    }

    /// The metric chips, in the order the plan lists them. A zero shows as a muted dash, so an empty day still
    /// reads as "synced, nothing there" rather than missing.
    private func counts(_ c: SyncDayCounts, live: Bool) -> some View {
        let items: [(String, String, Int, Color)] = [
            ("figure.walk", "steps", c.steps, AgaraColors.steps),
            ("heart.fill", "HR", c.heartRate, AgaraColors.heartRate),
            ("drop.fill", "SpO₂", c.spo2, AgaraColors.spo2),
            ("waveform.path.ecg", "HRV", c.hrv, AgaraColors.hrv),
            ("brain.head.profile", "stress", c.stress, AgaraColors.stress),
            ("moon.fill", c.sleepNights == 1 ? "night" : "nights", c.sleepNights, AgaraColors.sleep),
        ]
        return FlowLayoutRow(spacing: 6) {
            ForEach(items, id: \.1) { icon, label, value, tint in
                HStack(spacing: 4) {
                    Image(systemName: icon).font(AgaraFont.caption2).foregroundStyle(value > 0 ? tint : AgaraColors.textMuted)
                    Text(value > 0 ? "\(value.formatted()) \(label)" : "– \(label)")
                        .font(AgaraFont.caption.weight(.medium))
                        .foregroundStyle(value > 0 ? AgaraColors.textSecondary : AgaraColors.textMuted)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AgaraColors.textPrimary.opacity(0.06), in: Capsule())
            }
        }
    }
}

/// Wraps chips onto as many lines as they need (a `Layout`, so it measures instead of guessing).
private struct FlowLayoutRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
