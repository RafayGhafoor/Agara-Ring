import SwiftUI

/// Per-conversation token/cost transparency. Shows the provider + model(s), total
/// input/output tokens, and total cost, with a per-message breakdown. Tolerates
/// all-nil accounting (older conversations, on-device turns) by rendering "—".
struct CoachUsageSheet: View {
    let conversation: CoachConversation?
    let messages: [CoachMessage]
    let settings: CoachSettings
    /// The effective provider: the privacy section describes what actually happens to this conversation.
    var usesCloud: Bool = false
    @Environment(\.dismiss) private var dismiss

    /// Assistant/error rows that carried token accounting.
    private var accountedMessages: [CoachMessage] {
        messages.filter { $0.inputTokens != nil || $0.outputTokens != nil || $0.costUSD != nil }
    }

    private var totalInputTokens: Int {
        if let convo = conversation, convo.totalInputTokens > 0 { return convo.totalInputTokens }
        return messages.compactMap(\.inputTokens).reduce(0, +)
    }

    private var totalOutputTokens: Int {
        if let convo = conversation, convo.totalOutputTokens > 0 { return convo.totalOutputTokens }
        return messages.compactMap(\.outputTokens).reduce(0, +)
    }

    private var totalCost: Double? {
        if let convo = conversation, convo.totalCostUSD > 0 { return convo.totalCostUSD }
        let costs = messages.compactMap(\.costUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// Distinct model names seen across the conversation's turns, in order.
    private var models: [String] {
        var seen: [String] = []
        for m in messages {
            if let model = m.modelUsed, !model.isEmpty, !seen.contains(model) { seen.append(model) }
        }
        // No recorded turn yet: name what WILL answer. `settings.model` is the bring-your-own-key field and was shown
        // for the cloud coach ("gpt-5.4").
        if seen.isEmpty { seen.append(usesCloud ? CoachCopy.cloudModelLabel : settings.model) }
        return seen
    }

    private var providerLabel: String {
        messages.compactMap(\.providerUsed).first
            .flatMap { CoachProviderMode(rawValue: $0)?.label }
            ?? settings.providerMode.label
    }

    /// The catalog can't price on-device/offline/custom models. Show the note when
    /// a turn burned tokens but has no cost, or the provider inherently lacks it.
    private var showsCostNote: Bool {
        let providerLacksCost = settings.providerMode == .appleOnDevice || settings.providerMode == .offlineStub
        let anyTokenlessCost = accountedMessages.contains {
            ($0.inputTokens != nil || $0.outputTokens != nil) && $0.costUSD == nil
        }
        return providerLacksCost || anyTokenlessCost
    }

    private static let tokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private func formatTokens(_ value: Int) -> String {
        Self.tokenFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // What the status line promised: where the answers come from and what leaves the phone. The
                    // sentences are the consent sheet's, verbatim — no new claims.
                    privacySection
                    summaryCard
                    if showsCostNote && totalInputTokens + totalOutputTokens > 0 { costNote }
                    if !accountedMessages.isEmpty { breakdownCard }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(AgaraColors.background)
            .navigationTitle(CoachCopy.privacySheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: usesCloud ? "cloud" : "iphone")
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(usesCloud ? AgaraColors.accent : AgaraColors.success)
                Text(usesCloud ? CoachCopy.headerCloudSubtitle : CoachCopy.headerOnDeviceSubtitle)
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if usesCloud {
                ForEach([CoachCopy.consentNeverSent, CoachCopy.consentStoredBody, CoachCopy.consentProviderRetention],
                        id: \.self) { line in
                    Text(line)
                        .font(AgaraFont.footnote.weight(.regular))
                        .foregroundStyle(AgaraColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coach.privacy")
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            usageRow(label: "Provider", value: providerLabel)
            divider
            usageRow(label: models.count > 1 ? "Models" : "Model", value: models.joined(separator: ", "))
            divider
            usageRow(label: "Input tokens", value: formatTokens(totalInputTokens), mono: true)
            divider
            usageRow(label: "Output tokens", value: formatTokens(totalOutputTokens), mono: true)
            divider
            usageRow(
                label: "Estimated cost",
                value: totalCost.map { String(format: "$%.4f", $0) } ?? "—",
                mono: true
            )
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // Inline notice, not a surface: keeps its flat tint so it doesn't stack glass
    // on top of the glass cards it sits between.
    private var costNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(AgaraFont.caption2.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
            Text("Cost estimates aren't available for on-device or custom models.")
                .font(AgaraFont.caption.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AgaraColors.textMuted.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(accountedMessages) { message in
                        messageBreakdownRow(message)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Per-message breakdown")
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textPrimary)
            }
            .tint(AgaraColors.textSecondary)
        }
        .padding(16)
        .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func messageBreakdownRow(_ message: CoachMessage) -> some View {
        let preview = message.body.replacingOccurrences(of: "\n", with: " ").prefix(30)
        let tokens = "\(message.inputTokens ?? 0) in · \(message.outputTokens ?? 0) out"
        let cost = message.costUSD.map { String(format: "$%.4f", $0) } ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            Text(preview.isEmpty ? "(no text)" : String(preview))
                .font(AgaraFont.caption.weight(.regular))
                .foregroundStyle(AgaraColors.textPrimary)
                .lineLimit(1)
            HStack {
                Text(tokens)
                    .font(AgaraFont.caption2.weight(.regular).monospacedDigit())
                    .foregroundStyle(AgaraColors.textMuted)
                Spacer()
                Text(cost)
                    .font(AgaraFont.caption2.weight(.regular).monospacedDigit())
                    .foregroundStyle(AgaraColors.textMuted)
            }
        }
    }

    private func usageRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(AgaraFont.subheadline.weight(.regular))
                .foregroundStyle(AgaraColors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? AgaraFont.subheadline.weight(.regular).monospacedDigit() : AgaraFont.subheadline.weight(.regular))
                .foregroundStyle(AgaraColors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(AgaraColors.borderSubtle).frame(height: 1)
    }
}
