import SwiftUI
import SwiftData

// MARK: - The card

/// The EV40 share card: a typographic card on the app's own surface, sized for a story and a feed post.
///
/// It carries only what the tracker screen already shows — the day of the challenge, today's count and share, and
/// which of the eight are ticked — so nobody can share a claim the app does not make. No "copy link": the card is an
/// image and the link would go stale the moment the day changes.
struct Ev40ShareCardView: View {
    let model: Ev40ShareCardModel
    let format: ShareCardFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            Spacer(minLength: 12)
            challengeLine
            Spacer(minLength: 16)
            count
            Spacer(minLength: 16)
            dots
            Spacer(minLength: 12)
            tagline
        }
        .padding(28)
        .frame(width: format.pointSize.width, height: format.pointSize.height, alignment: .leading)
        .background(AgaraColors.background)
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AGARA")
                .font(.system(size: 11, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(AgaraColors.accent)
            Text(AgaraCopy.ev40ChallengeName)
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(AgaraColors.textMuted)
        }
    }

    private var challengeLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.dayLabel)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AgaraColors.textPrimary)
            Text(model.dateLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AgaraColors.textMuted)
        }
    }

    private var count: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(model.done)/\(model.total)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(AgaraColors.textPrimary)
            Text("\(model.percent)%")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(AgaraColors.accent)
        }
    }

    /// One dot per discipline, filled for ticked — the smallest form that still says *which* ones, in the app's order.
    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<model.total, id: \.self) { index in
                Circle()
                    .fill(index < model.done ? AgaraColors.accent : AgaraColors.cardSoft)
                    .frame(width: 10, height: 10)
            }
        }
    }

    private var tagline: some View {
        Text(AgaraCopy.ev40ChallengeTagline)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AgaraColors.textMuted)
    }
}

// MARK: - Model

/// Formatted up front so the renderer does no date or pluralisation logic (same split as `ShareCardModel`).
struct Ev40ShareCardModel: Equatable {
    /// "Day 14 of 40", or the challenge name when it has not started.
    let dayLabel: String
    /// "Thu, 5 Nov" — the local day the card was made for.
    let dateLine: String
    let done: Int
    let total: Int

    var percent: Int { total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded()) }

    static func make(mask: Int, now: Date = AppClock.now, calendar: Calendar = .current,
                     trackedKeys: [String]) -> Ev40ShareCardModel {
        let done = Ev40Disciplines.count(mask)
        let day = Ev40Challenge.dayNumber(trackedKeys: trackedKeys,
                                         today: Ev40Challenge.key(now, calendar: calendar), calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return Ev40ShareCardModel(dayLabel: Ev40Challenge.label(dayNumber: day) ?? AgaraCopy.ev40ChallengeName,
                                  dateLine: formatter.string(from: now),
                                  done: done,
                                  total: Ev40Disciplines.all.count)
    }
}

// MARK: - Renderer

/// Renders the card at `format`'s pixel size (1080×1920 story / 1080×1080 square) — the same `ImageRenderer` route the
/// workout card uses, so the export is the view, not a second drawing that could drift from it.
@MainActor
enum Ev40ShareRenderer {
    static func render(model: Ev40ShareCardModel, format: ShareCardFormat) -> UIImage? {
        let renderer = ImageRenderer(content: Ev40ShareCardView(model: model, format: format))
        renderer.proposedSize = ProposedViewSize(format.pointSize)
        renderer.scale = format.scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// PNG-wrapped render ready for `ShareLink`; nil when rendering or PNG encoding fails.
    static func shareImage(model: Ev40ShareCardModel, format: ShareCardFormat,
                           date: Date = AppClock.now) -> ShareCardImage? {
        guard let image = render(model: model, format: format), let data = image.pngData() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return ShareCardImage(pngData: data, filename: "agara-ev40-\(formatter.string(from: date)).png")
    }
}

// MARK: - Sheet

/// Share sheet for the EV40 card: a live preview, story/square, and a `ShareLink` that exports the rendered PNG.
/// Deliberately no "copy link" — the card is an image, and a link would go stale the moment the day changes.
struct Ev40ShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var days: [Ev40Day]

    @State private var format: ShareCardFormat = .story
    @State private var model: Ev40ShareCardModel?
    @State private var shareImage: ShareCardImage?

    private var mask: Int { Ev40Repo.todayMask(context: modelContext) }

    var body: some View {
        VStack(spacing: 18) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            formatToggle
            shareButton
        }
        .padding(20)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AgaraColors.background)
        .onAppear(perform: rebuild)
        .onChange(of: format) { _, _ in renderShareImage() }
        .accessibilityIdentifier("ev40.shareSheet")
    }

    private var header: some View {
        HStack {
            Text(AgaraCopy.ev40ShareTitle)
                .font(AgaraFont.title3.weight(.bold))
                .foregroundStyle(AgaraColors.textPrimary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(AgaraColors.textMuted)
            }
            .accessibilityLabel("Close")
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var preview: some View {
        if let model {
            Ev40ShareCardView(model: model, format: format)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            ProgressView().frame(maxHeight: .infinity)
        }
    }

    private var formatToggle: some View {
        Picker("Format", selection: $format) {
            Text("Story").tag(ShareCardFormat.story)
            Text("Square").tag(ShareCardFormat.square)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ev40.shareFormat")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            ShareLink(item: shareImage, preview: SharePreview(AgaraCopy.ev40ChallengeName,
                                                              image: shareImage.previewImage)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(AgaraFont.bodyEmphasis)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AgaraColors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: AgaraShape.radiusControl, style: .continuous))
            }
            .accessibilityIdentifier("ev40.shareLink")
        } else {
            ProgressView().frame(height: 48)
        }
    }

    private func rebuild() {
        model = Ev40ShareCardModel.make(mask: mask, trackedKeys: days.map(\.dateKey))
        renderShareImage()
    }

    private func renderShareImage() {
        guard let model else { return }
        shareImage = Ev40ShareRenderer.shareImage(model: model, format: format)
    }
}
