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
        // The answer is the page (no bubble), so it carries its own hierarchy: a heading, body-size prose, then the
        // supporting material in a quieter voice.
        VStack(alignment: .leading, spacing: 12) {
            if !response.title.isEmpty {
                Text(coachMarkdown: response.title)
                    .font(AgaraFont.headline)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !response.summary.isEmpty {
                Text(coachMarkdown: response.summary)
                    .font(AgaraFont.body.weight(.regular))
                    .lineSpacing(3)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
            }

            bulletsSection

            if let chart = response.chart {
                CoachChartView(chart: chart).padding(.top, 2)
            }

            if let safety = response.safetyNote, !safety.isEmpty {
                // The one note that keeps a tinted ground: it must not be skimmed past.
                noteRow(icon: "exclamationmark.triangle.fill", text: safety, tone: AgaraColors.warning, filled: true)
            }

            if let dq = response.dataQualityNote, !dq.isEmpty {
                noteRow(icon: "info.circle", text: dq, tone: AgaraColors.textMuted, filled: false)
            }

            sourcesSection
            chipsSection
        }
    }

    @ViewBuilder
    private var bulletsSection: some View {
        if !response.bullets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(response.bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(AgaraColors.accent).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(coachMarkdown: bullet)
                            .foregroundStyle(AgaraColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(AgaraFont.subheadline.weight(.regular))
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
            // Exactly three, the contract's number; `balanced` keeps at most three and tops short answers up. Same
            // component as the empty thread's opening questions — both are "ask this next".
            CoachSuggestionList(questions: chips, identifier: "coach.chip") { onChipTap?($0) }
                .padding(.top, 4)
        }
    }

    private func noteRow(icon: String, text: String, tone: Color, filled: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(AgaraFont.caption2.weight(.regular)).foregroundStyle(tone)
            Text(coachMarkdown: text).font(AgaraFont.caption.weight(.regular)).foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(filled ? 10 : 0)
        .background(filled ? tone.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Ask this next": the empty thread's opening questions and every answer's three follow-ups, in one shape. Outlined
/// rows, not filled tiles — the answer above them is unboxed, and a stack of filled tiles under it read as more cards.
/// The arrow carries the accent so the row reads as an action at a glance.
struct CoachSuggestionList: View {
    let questions: [String]
    /// `coach.starter` or `coach.chip` — the UI tests tell the two apart.
    let identifier: String
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions, id: \.self) { question in
                Button { onTap(question) } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Text(question)
                            .font(AgaraFont.subheadline.weight(.regular))
                            .foregroundStyle(AgaraColors.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(AgaraFont.caption.weight(.semibold))
                            .foregroundStyle(AgaraColors.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AgaraColors.textPrimary.opacity(0.14), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
            }
        }
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

/// Display-only text fixes for model output.
enum CoachText {
    /// Joins a number to its unit, and the parts of a compound duration, with no-break spaces: "5 h 56 m" broke as
    /// "5 h 56" / "m" at the end of a line. Applied at render time; the stored answer is untouched.
    static func keepUnitsTogether(_ text: String) -> String {
        let nbsp = "\u{00A0}"
        var out = text.replacingOccurrences(
            of: #"(\d) (h|m|min|s|bpm|kcal|km|mi|steps|%)(?=\b|[^\p{L}]|$)"#,
            with: "$1\(nbsp)$2", options: .regularExpression)
        // "5 h 56 m": also hold the hour unit to the minutes that follow it.
        out = out.replacingOccurrences(of: #"(\d\u00A0h) (\d)"#, with: "$1\(nbsp)$2", options: .regularExpression)
        return out
    }
}

extension Text {
    /// Renders inline Markdown (**bold**, *italic*, `code`, links) so model
    /// output like "**HR**" displays formatted instead of raw. Falls back to the
    /// literal string if parsing fails. `inlineOnlyPreservingWhitespace` keeps
    /// line breaks intact for multi-line summaries/bullets.
    init(coachMarkdown raw: String) {
        let string = CoachText.keepUnitsTogether(raw)
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
