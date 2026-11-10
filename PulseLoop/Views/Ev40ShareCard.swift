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

    /// Square is 360×360 — the same content at story type sizes would crowd it, so the whole card scales down.
    private var scale: CGFloat { format == .story ? 1 : 0.62 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            // Who + which day of the challenge — the two things that make the card personal. A profile with no name
            // hides the row rather than printing a placeholder; the card still reads.
            VStack(alignment: .leading, spacing: 3) {
                if let userName = model.userName {
                    Text(userName)
                        .font(.system(size: 24 * scale, weight: .bold))
                        .foregroundStyle(AgaraColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(model.dayLabel.uppercased() + "  ·  " + model.dateLine)
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(AgaraColors.accent)
            }
            .padding(.top, 10 * scale)

            HStack(alignment: .center, spacing: 18 * scale) {
                ring
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text("\(model.done)/\(model.total)")
                        .font(.system(size: 30 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text("\(model.percent)% of today")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundStyle(AgaraColors.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10 * scale)
            Spacer(minLength: 6)
            disciplineList

            if !model.journey.isEmpty {
                Spacer(minLength: 6)
                journeyGrid
            }

            Spacer(minLength: 10)          // the foot is pinned low; the spacer above it takes the last of the slack
            hairline
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: format.pointSize.width, height: format.pointSize.height, alignment: .topLeading)
        .background(AgaraColors.background)
    }

    private var brand: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AGARA")
                    .font(.system(size: 10 * scale, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(AgaraColors.accent)
                Text(AgaraCopy.ev40ChallengeName)
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(AgaraColors.textMuted)
            }
            Spacer(minLength: 0)
            Text(AgaraCopy.ev40CardPillToday)
                .font(.system(size: 9 * scale, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(AgaraColors.accent)
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 3 * scale)
                .background(Capsule().fill(AgaraColors.accent.opacity(0.12)))
        }
    }

    /// The progress ring: the day's share in one shape, with the count inside it.
    private var ring: some View {
        let size = 96 * scale
        return ZStack {
            Circle()
                .stroke(AgaraColors.cardSoft, lineWidth: 7 * scale)
            Circle()
                .trim(from: 0, to: max(0.001, model.fraction))
                .stroke(AgaraColors.accent, style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(model.percent)%")
                .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(AgaraColors.textPrimary)
        }
        .frame(width: size, height: size)
    }

    /// All eight, not just the count: the card should say what the day actually contained. Two columns keep the story
    /// format from turning into a long list with dead space.
    private var disciplineList: some View {
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6 * scale) {
            ForEach(model.disciplines) { discipline in
                HStack(spacing: 6 * scale) {
                    ZStack {
                        Circle()
                            .fill(discipline.done ? AgaraColors.success : AgaraColors.cardSoft)
                            .frame(width: 14 * scale, height: 14 * scale)
                        if discipline.done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7.5 * scale, weight: .bold))
                                .foregroundStyle(AgaraColors.background)
                        }
                    }
                    Text(discipline.name)
                        .font(.system(size: 10.5 * scale, weight: discipline.done ? .semibold : .regular))
                        .foregroundStyle(discipline.done ? AgaraColors.textPrimary : AgaraColors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    /// The whole 40-day journey, not just today: filled where the day carried at least one tick, outlined for today.
    private var journeyGrid: some View {
        let rows = stride(from: 0, to: model.journey.count, by: 8).map { start in
            Array(start..<min(start + 8, model.journey.count))
        }
        return VStack(alignment: .leading, spacing: 7 * scale) {
            Text("THE 40")
                .font(.system(size: 8.5 * scale, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(AgaraColors.textMuted)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5 * scale) {
                    ForEach(row, id: \.self) { index in
                        let isToday = model.journeyToday == index
                        RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                            .fill(model.journey[index] ? AgaraColors.accent : AgaraColors.cardSoft)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay {
                                if isToday {
                                    RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                                        .stroke(AgaraColors.textPrimary, lineWidth: 1.4)
                                }
                            }
                    }
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(AgaraColors.cardSoft)
            .frame(height: 1)
            .padding(.bottom, 9)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AgaraCopy.ev40ChallengeTagline)
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundStyle(AgaraColors.textMuted)
            Spacer(minLength: 0)
            Text("agara.life")
                .font(.system(size: 9 * scale, weight: .semibold))
                .foregroundStyle(AgaraColors.accent)
        }
    }
}

// MARK: - Model

/// Formatted up front so the renderer does no date or pluralisation logic (same split as `ShareCardModel`).
struct Ev40ShareCardModel: Equatable {
    /// The person's name from their profile; nil hides the row rather than printing a placeholder.
    let userName: String?
    /// "Day 14 of 40", or the challenge name when it has not started.
    let dayLabel: String
    /// "Thu, 5 Nov" — the local day the card was made for.
    let dateLine: String
    let done: Int
    let total: Int
    /// One entry per discipline in the app's own order, so the card lists what the day contained.
    let disciplines: [Entry]
    /// The challenge journey: one slot per day of the 40, true when that day carried at least one tick.
    let journey: [Bool]
    /// Today's position in `journey` (0-based), so the card can mark it.
    let journeyToday: Int?

    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let done: Bool
    }

    var percent: Int { total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded()) }
    /// The ring's sweep; an empty day still draws its cap rather than nothing.
    var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }

    static func make(mask: Int, userName: String?, now: Date = AppClock.now, calendar: Calendar = .current,
                     trackedKeys: [String], masksByKey: [String: Int] = [:]) -> Ev40ShareCardModel {
        let done = Ev40Disciplines.count(mask)
        let day = Ev40Challenge.dayNumber(trackedKeys: trackedKeys,
                                         today: Ev40Challenge.key(now, calendar: calendar), calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        let trimmed = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Ev40ShareCardModel(
            userName: trimmed.isEmpty ? nil : trimmed,
            dayLabel: Ev40Challenge.label(dayNumber: day) ?? AgaraCopy.ev40ChallengeName,
            dateLine: formatter.string(from: now),
            done: done,
            total: Ev40Disciplines.all.count,
            disciplines: Ev40Disciplines.all.map {
                Entry(id: $0.rawValue, name: $0.title, done: Ev40Disciplines.isOn(mask, $0))
            },
            journey: journey(trackedKeys: trackedKeys, masksByKey: masksByKey, today: now, calendar: calendar).0,
            journeyToday: journey(trackedKeys: trackedKeys, masksByKey: masksByKey, today: now, calendar: calendar).1)
    }
}

extension Ev40ShareCardModel {
    /// The 40 slots from the challenge's first ticked day, plus today's index. Derived from the same synced rows as the
    /// day number, so the grid and "Day N of 40" can never disagree.
    static func journey(trackedKeys: [String], masksByKey: [String: Int], today: Date,
                        calendar: Calendar) -> ([Bool], Int?) {
        guard let dayNumber = Ev40Challenge.dayNumber(trackedKeys: trackedKeys,
                                                      today: Ev40Challenge.key(today, calendar: calendar),
                                                      calendar: calendar),
              let end = Ev40Repo.date(Ev40Challenge.key(today, calendar: calendar), calendar: calendar),
              let start = calendar.date(byAdding: .day, value: -(dayNumber - 1), to: calendar.startOfDay(for: end))
        else { return ([], nil) }
        let slots = (0..<Ev40Challenge.totalDays).map { offset -> Bool in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return false }
            let key = Ev40Challenge.key(date, calendar: calendar)
            return (masksByKey[key] ?? 0) != 0
        }
        return (slots, dayNumber - 1)
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
    @Query private var profiles: [UserProfile]

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
        .padding(.horizontal, 20)
        .padding(.top, 28)          // clears the sheet grabber, which was clipping the title
        .padding(.bottom, 20)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AgaraColors.background)
        .onAppear(perform: rebuild)
        .onChange(of: format) { _, _ in renderShareImage() }
    }

    private var header: some View {
        HStack {
            Text(AgaraCopy.ev40ShareTitle)
                .font(AgaraFont.title3.weight(.bold))
                .foregroundStyle(AgaraColors.textPrimary)
                // The sheet's identifier lives on this label, not on the container: an identifier on a stack propagates
                // to every descendant and shadows the children's own ids (`ev40.shareLink` became unreachable).
                .accessibilityIdentifier("ev40.shareSheet")
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
            // The card shares the app's background colour, so without a real edge it reads as text floating in the
            // sheet — the preview must look like an object.
            Ev40ShareCardView(model: model, format: format)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AgaraColors.cardSoft, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        model = Ev40ShareCardModel.make(mask: mask, userName: profiles.first?.name,
                                        trackedKeys: days.map(\.dateKey),
                                        masksByKey: Dictionary(days.map { ($0.dateKey, $0.mask) },
                                                               uniquingKeysWith: { a, _ in a }))
        renderShareImage()
    }

    private func renderShareImage() {
        guard let model else { return }
        shareImage = Ev40ShareRenderer.shareImage(model: model, format: format)
    }
}
