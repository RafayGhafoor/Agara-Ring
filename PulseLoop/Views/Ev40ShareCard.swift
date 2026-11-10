import SwiftUI
import SwiftData
import CoreImage
import CoreImage.CIFilterBuiltins

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
                    // The streak, not the percentage again: that number is already inside the ring (R2).
                    Text("\(model.streak) \(AgaraCopy.ev40ShareStreak)")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundStyle(AgaraColors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10 * scale)
            Spacer(minLength: 6)
            disciplineList
            statsRow

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
            // The perfect day is the moment worth sharing, so the pill says so instead of "TODAY" (A4).
            Text(model.isPerfect ? AgaraCopy.ev40SharePerfectBadge : AgaraCopy.ev40CardPillToday)
                .font(.system(size: 9 * scale, weight: .bold))
                .tracking(1.1)
                .lineLimit(1)
                .foregroundStyle(model.isPerfect ? AgaraColors.success : AgaraColors.accent)
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 3 * scale)
                .background(Capsule().fill((model.isPerfect ? AgaraColors.success : AgaraColors.accent).opacity(0.12)))
        }
    }

    /// The progress ring: the day's share in one shape, with the count inside it.
    private var ring: some View {
        let size = 96 * scale
        let tint = model.isPerfect ? AgaraColors.success : AgaraColors.accent
        return ZStack {
            Circle()
                .stroke(AgaraColors.cardSoft, lineWidth: 7 * scale)
            Circle()
                .trim(from: 0, to: max(0.001, model.fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round))
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
                        if discipline.done {
                            Circle().fill(AgaraColors.success)
                            Image(systemName: "checkmark")
                                .font(.system(size: 7.5 * scale, weight: .bold))
                                .foregroundStyle(AgaraColors.background)
                        } else {
                            // A clear fill with a real edge: `cardSoft` on `background` was nearly invisible on the
                            // light theme (R8).
                            Circle().strokeBorder(AgaraColors.borderStrong, lineWidth: 1.5 * scale)
                        }
                    }
                    .frame(width: 14 * scale, height: 14 * scale)
                    Text(discipline.name)
                        .font(.system(size: 10.5 * scale, weight: discipline.done ? .semibold : .regular))
                        .foregroundStyle(discipline.done ? AgaraColors.textPrimary : AgaraColors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    /// Streak · perfect days · days active (A2): the summary a day-30 card needs, and on a day-1 card the one line that
    /// still says something real.
    private var statsRow: some View {
        Text(model.statsLine)
            .font(.system(size: 9.5 * scale, weight: .medium))
            .foregroundStyle(AgaraColors.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.top, 8 * scale)
    }

    /// The whole 40-day journey, not just today: one of four accent shades for the ticks that day carried (A3), an
    /// outlined empty slot for a day with none, and the today ring on top of whichever it is.
    private var journeyGrid: some View {
        // Always the whole challenge (mirror of Android): a short journey list is padded with empty slots, so an early
        // card still shows the days to come.
        let slots = Ev40Challenge.totalDays
        let rows = stride(from: 0, to: slots, by: 8).map { start in Array(start..<min(start + 8, slots)) }
        return VStack(alignment: .leading, spacing: 7 * scale) {
            Text("THE 40")
                .font(.system(size: 8.5 * scale, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(AgaraColors.textMuted)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5 * scale) {
                    ForEach(row, id: \.self) { index in
                        let isToday = model.journeyToday == index
                        let level = index < model.journey.count ? model.journey[index] : 0
                        let shape = RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                        shape
                            .fill(level == 0 ? AgaraColors.cardSoft : AgaraColors.accent.opacity(heat(level)))
                            // Both strokes sit on the square itself, before the flexible frame: an overlay applied
                            // after `.frame(maxWidth:)` outlines the frame, which in square format is wider than the cell.
                            .overlay {
                                if isToday {
                                    shape.strokeBorder(AgaraColors.textPrimary, lineWidth: 1.4)
                                } else if level == 0 {
                                    shape.strokeBorder(AgaraColors.borderSubtle, lineWidth: 1)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// The four heat shades: more ticks, deeper colour (1–2, 3–4, 5–7, 8 of the eight).
    private func heat(_ level: Int) -> Double {
        switch level {
        case 1: 0.30
        case 2: 0.55
        case 3: 0.80
        default: 1.0
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(AgaraColors.cardSoft)
            .frame(height: 1)
            .padding(.bottom, 9)
    }

    /// The footer prints the address the cloud says (`ShareCardConfig.active()`), never a literal — and, when the
    /// console switches the QR on, encodes that same address instead of spelling it out (A6/D4).
    private var footer: some View {
        let card = ShareCardConfig.active()
        return HStack(alignment: .center, spacing: 8 * scale) {
            Text(AgaraCopy.ev40ChallengeTagline)
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundStyle(AgaraColors.textMuted)
            Spacer(minLength: 0)
            if card.qr, let url = card.qrUrl {
                qrCode(url)
                    .frame(width: 44 * scale, height: 44 * scale)
            } else {
                Text(card.displayUrl)
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundStyle(AgaraColors.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// The QR itself, drawn from the same address the text would print. Generated on the device (CoreImage): no network
    /// call, no SDK, and the app never opens it — only the viewer's camera does.
    @ViewBuilder
    private func qrCode(_ text: String) -> some View {
        if let image = Ev40ShareCardView.qrImage(text) {
            image
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    /// The QR bitmap for a 44 pt footer slot: at the card's 3× export that slot is 132 px, and the bitmap is an integer
    /// multiple of the generator's module grid so no module edge falls mid-pixel.
    static func qrImage(_ text: String) -> Image? {
        guard let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let slotPixels = 132.0                                   // 44 pt × 3 (`format.scale`)
        let factor = max(1, (slotPixels / output.extent.width).rounded(.up))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cgImage = qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 3)
    }

    /// One context for every card render: creating one per preview would be the most expensive part of the sheet.
    private static let qrContext = CIContext(options: nil)
}

// MARK: - Model

/// Formatted up front so the renderer does no date or pluralisation logic (same split as `ShareCardModel`).
struct Ev40ShareCardModel: Equatable {
    /// The person's name from their profile; nil hides the row rather than printing a placeholder.
    let userName: String?
    /// "Day 14 of 40", or the challenge name when it has not started.
    let dayLabel: String
    /// "Tue, 10 Nov" — the local day the card was made for, and the same shape Android prints (R3).
    let dateLine: String
    let done: Int
    let total: Int
    /// One entry per discipline in the app's own order, so the card lists what the day contained.
    let disciplines: [Entry]
    /// Consecutive days with a tick, ending today (or yesterday) — the number under `N/8` and in the stats row (A1/R2).
    let streak: Int
    /// Days so far that ended with all eight ticked (A2).
    let perfectDays: Int
    /// Days so far that carried at least one tick (A2).
    let daysActive: Int
    /// The challenge journey: one slot per day of the 40, as a heat level 0–4 for the ticks that day carried (A3).
    let journey: [Int]
    /// Today's position in `journey` (0-based), so the card can mark it.
    let journeyToday: Int?

    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let done: Bool
    }

    /// The stats row: perfect days and days active, singular when the count is exactly 1. The streak is **not** repeated
    /// here — it already sits under the count, and printing it twice read as filler (review, 2026-11-10).
    var statsLine: String {
        let perfect = perfectDays == 1 ? AgaraCopy.ev40SharePerfectDay : AgaraCopy.ev40SharePerfectDays
        let active = daysActive == 1 ? AgaraCopy.ev40ShareDayActive : AgaraCopy.ev40ShareDaysActive
        return "\(perfectDays) \(perfect) · \(daysActive) \(active)"
    }

    var percent: Int { total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded()) }
    /// The ring's sweep; an empty day still draws its cap rather than nothing.
    var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
    /// All eight today: the ring turns success-green and the pill becomes the badge (A4).
    var isPerfect: Bool { total > 0 && done == total }

    static func make(mask: Int, userName: String?, now: Date = AppClock.now, calendar: Calendar = .current,
                     trackedKeys: [String], masksByKey: [String: Int] = [:]) -> Ev40ShareCardModel {
        let done = Ev40Disciplines.count(mask)
        let todayKey = Ev40Challenge.key(now, calendar: calendar)
        // A day someone merely opened the screen on carries no tick and must not start the challenge; a key the mask map
        // does not cover is taken as the caller's own ticked day (the `dayNumber` contract).
        let tickedKeys = trackedKeys.filter { key in
            guard let dayMask = masksByKey[key] else { return true }
            return Ev40Disciplines.count(dayMask) > 0
        }
        let day = Ev40Challenge.dayNumber(trackedKeys: tickedKeys, today: todayKey, calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // A fixed pattern, not a template: the card is an image both platforms print the same date on ("Tue, 10 Nov").
        formatter.dateFormat = "EEE, d MMM"
        let trimmed = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let slots = journey(tickedKeys: tickedKeys, masksByKey: masksByKey, today: now, calendar: calendar)
        return Ev40ShareCardModel(
            userName: trimmed.isEmpty ? nil : trimmed,
            dayLabel: Ev40Challenge.label(dayNumber: day) ?? AgaraCopy.ev40ChallengeName,
            dateLine: formatter.string(from: now),
            done: done,
            total: Ev40Disciplines.all.count,
            disciplines: Ev40Disciplines.all.map {
                Entry(id: $0.rawValue, name: $0.title, done: Ev40Disciplines.isOn(mask, $0))
            },
            streak: Ev40Challenge.streak(tickedKeys: Set(tickedKeys), today: todayKey, calendar: calendar),
            perfectDays: Ev40Challenge.perfectDays(masksByKey: masksByKey, today: todayKey, calendar: calendar),
            daysActive: Ev40Challenge.daysActive(masksByKey: masksByKey, today: todayKey, calendar: calendar),
            journey: slots.0,
            journeyToday: slots.1)
    }
}

extension Ev40ShareCardModel {
    /// The 40 slots from the challenge's first ticked day, plus today's index. Derived from the same synced rows as the
    /// day number, so the grid and "Day N of 40" can never disagree.
    static func journey(tickedKeys: [String], masksByKey: [String: Int], today: Date,
                        calendar: Calendar) -> ([Int], Int?) {
        guard let dayNumber = Ev40Challenge.dayNumber(trackedKeys: tickedKeys,
                                                      today: Ev40Challenge.key(today, calendar: calendar),
                                                      calendar: calendar),
              let end = Ev40Repo.date(Ev40Challenge.key(today, calendar: calendar), calendar: calendar),
              let start = calendar.date(byAdding: .day, value: -(dayNumber - 1), to: calendar.startOfDay(for: end))
        else { return ([], nil) }
        let slots = (0..<Ev40Challenge.totalDays).map { offset -> Int in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return 0 }
            let key = Ev40Challenge.key(date, calendar: calendar)
            return Ev40Challenge.level(mask: masksByKey[key] ?? 0)
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
        .padding(.top, 30)          // clears the sheet grabber: the title starts below the indicator, not under it
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
    }

    /// The card is laid out at its own point size (360×640 for story). A sheet has less room than that once the header,
    /// the toggle and the share button have taken theirs, and the overflowing stack used to push the title up under the
    /// grabber (R7) — so the preview is scaled to whatever space is left instead of overflowing it.
    @ViewBuilder
    private var preview: some View {
        if let model {
            GeometryReader { geo in
                let card = format.pointSize
                let fit = min(1, min(geo.size.width / card.width, geo.size.height / card.height))
                // The card shares the app's background colour, so without a real edge it reads as text floating in the
                // sheet — the preview must look like an object.
                Ev40ShareCardView(model: model, format: format)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AgaraColors.cardSoft, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                    .scaleEffect(fit)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
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
