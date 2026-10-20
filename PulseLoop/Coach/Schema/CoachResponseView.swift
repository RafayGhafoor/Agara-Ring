import SwiftUI

/// Renders a decoded `CoachResponse` as the assistant bubble's content:
/// title, summary, bullets, embedded chart, safety + data-quality notes,
/// sources, and tappable follow-up chips.
struct CoachResponseView: View {
    let response: CoachResponse
    /// The conversation's data-based starter prompts: answers that carry fewer than three follow-ups (a debug-build
    /// bring-your-own-key provider, or a message written before the contract required three) are topped up from here
    /// instead of rendering a short row.
    var fallbackChips: [String] = []
    var onChipTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !response.title.isEmpty {
                Text(coachMarkdown: response.title)
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
            }

            if !response.summary.isEmpty {
                Text(coachMarkdown: response.summary)
                    .font(AgaraFont.subheadline.weight(.regular))
                    .lineSpacing(4)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bulletsSection

            if let chart = response.chart {
                CoachChartView(chart: chart).padding(.top, 2)
            }

            if let safety = response.safetyNote, !safety.isEmpty {
                noteRow(icon: "exclamationmark.triangle.fill", text: safety, tone: AgaraColors.warning)
            }

            if let dq = response.dataQualityNote, !dq.isEmpty {
                noteRow(icon: "info.circle", text: dq, tone: AgaraColors.textMuted)
            }

            sourcesSection
            chipsSection
        }
    }

    @ViewBuilder
    private var bulletsSection: some View {
        if !response.bullets.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(response.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(AgaraColors.accent)
                        Text(coachMarkdown: bullet).foregroundStyle(AgaraColors.textSecondary)
                    }
                    .font(AgaraFont.footnote.weight(.regular))
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        if !response.sources.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("SOURCES")
                    .font(AgaraFont.nano).tracking(1.2)
                    .foregroundStyle(AgaraColors.textMuted)
                ForEach(response.sources) { source in
                    sourceLink(source)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func sourceLink(_ source: CoachSource) -> some View {
        if let url = URL(string: source.url) {
            Link(destination: url) {
                Text("\(source.title) — \(source.publisher)")
                    .font(AgaraFont.caption2.weight(.regular))
                    .foregroundStyle(AgaraColors.info)
                    .underline()
            }
        } else {
            Text("\(source.title) — \(source.publisher)")
                .font(AgaraFont.caption2.weight(.regular))
                .foregroundStyle(AgaraColors.textMuted)
        }
    }

    @ViewBuilder
    private var chipsSection: some View {
        let chips = CoachFollowUpChips.balanced(response.followUpChips, fallback: fallbackChips)
        if !chips.isEmpty {
            // Full-width tappable rows — exactly three, the contract's number: wide enough that a real follow-up
            // question reads without truncation. `balanced` keeps at most three and tops short answers up.
            VStack(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    Button { onChipTap?(chip) } label: {
                        CoachFollowUpChipLabel(text: chip)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("coach.chip")
                }
            }
            .padding(.top, 2)
        }
    }

    private func noteRow(icon: String, text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(AgaraFont.caption2.weight(.regular)).foregroundStyle(tone)
            Text(coachMarkdown: text).font(AgaraFont.caption.weight(.regular)).foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Full-width follow-up chip row: wraps up to two lines of question text with a
/// trailing arrow glyph. Shared by the chat response view and the Today/Sleep
/// summary cards so both render the same wider treatment.
struct CoachFollowUpChipLabel: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(AgaraFont.footnote.weight(.regular))
                .foregroundStyle(AgaraColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(AgaraFont.micro.weight(.semibold))
                .foregroundStyle(AgaraColors.textMuted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        // Solid tile, not glass: this chip renders inside the assistant bubble's glass,
        // and glass can't sample glass (renders flat). A soft card fill + hairline keeps
        // the chip visible as a tappable affordance.
        .background(AgaraColors.cardSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AgaraColors.textPrimary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

extension Text {
    /// Renders inline Markdown (**bold**, *italic*, `code`, links) so model
    /// output like "**HR**" displays formatted instead of raw. Falls back to the
    /// literal string if parsing fails. `inlineOnlyPreservingWhitespace` keeps
    /// line breaks intact for multi-line summaries/bullets.
    init(coachMarkdown string: String) {
        if let attributed = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            self.init(attributed)
        } else {
            self.init(verbatim: string)
        }
    }
}
