import SwiftUI
import SwiftData
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - The card

/// The EV40 share card (v3 layout, owner 2026-11-10 — plan `ev40-share-card-v2` → *v3*, mockup
/// `scripts/ev40_share_mockups.py`): the EV40 wordmark, the person, a hero card with the ring and three stats, the eight
/// disciplines as tiles with the tracker's own symbols, the 40-day journey as two compact rows of twenty, and the footer.
///
/// **Laid out on Android's pixel grid.** Every block is placed at the coordinates Android's `Ev40ShareCard` draws at
/// (1080-px canvas ÷ 3 = points, since the card renders at 3×), and text is placed by its *baseline* the way
/// `Canvas.drawText` does: top = baseline − 1.066 × size, Manrope's ascent. So the two platforms produce the same card,
/// not two cards that look alike (Rule 2). No "copy link" (owner).
struct Ev40ShareCardView: View {
    let model: Ev40ShareCardModel
    let format: ShareCardFormat

    /// Pixels → points: the card is laid out in Android's 1080-px units and rendered at 3×.
    private let k: CGFloat = 1.0 / 3.0
    private let M: CGFloat = 72                         // outer margin, px
    private var W: CGFloat { format.pointSize.width * 3 }
    private var H: CGFloat { format.pointSize.height * 3 }
    private var IW: CGFloat { W - 2 * M }
    /// Manrope's ascent in em (hhea 2132/2000) — the distance from a text block's top to its baseline.
    private static let ascent: CGFloat = 1.066

    private var highlight: Color { model.isPerfect ? AgaraColors.success : AgaraColors.accent }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AgaraColors.background
            if format == .story { story } else { square }
        }
        .frame(width: format.pointSize.width, height: format.pointSize.height, alignment: .topLeading)
        .clipped()
    }

    // MARK: Story

    @ViewBuilder private var story: some View {
        let baseline: CGFloat = 322
        let top = baseline + 120
        let hero = CGRect(x: M, y: top + 10, width: IW, height: 380)
        let cx = M + 56 + 132
        let cy = hero.midY
        let ty = hero.maxY + 90
        let tw = (IW - 20) / 2, th: CGFloat = 104, gap: CGFloat = 18
        let gridBottom = ty + 28 + 4 * th + 3 * gap
        let box = CGRect(x: M, y: gridBottom + 48, width: IW, height: 236)
        let pad: CGFloat = 36
        let fy = box.minY + pad + 22
        let cellGap: CGFloat = 9
        let cell = (IW - 2 * pad - 19 * cellGap) / 20

        // A large, faint wordmark in the open ground right of the name, bleeding off the edge (story only, V2).
        mark(x: W - 190 * Self.markAspect * 0.62, top: 210, height: 190,
             opacity: ThemeStore.current.isLight ? 0.09 : 0.08)
        header

        // Who and when. No name → the date takes the name's place, so nothing below moves (D10).
        if let name = model.userName {
            text(name, x: M, baseline: baseline, size: 96, weight: .bold, color: AgaraColors.textPrimary)
            text(model.dateLine, x: M, baseline: baseline + 60, size: 34, weight: .medium,
                 color: AgaraColors.textSecondary)
        } else {
            text(model.dateLine, x: M, baseline: baseline, size: 80, weight: .bold, color: AgaraColors.textPrimary)
        }

        // Hero card: the ring and the three numbers behind the day.
        panel(hero, radius: 40)
        ring(cx: cx, cy: cy, r: 132, stroke: 24)
        if model.isPerfect {
            symbol("star.fill", cx: cx, cy: cy - 6, size: 92, color: highlight)
            text("\(model.done) of \(model.total)", x: cx, baseline: cy + 74, size: 26, weight: .semibold,
                 color: AgaraColors.textMuted, align: .center)
        } else {
            text("\(model.percent)%", x: cx, baseline: cy + 18, size: 64, weight: .bold,
                 color: AgaraColors.textPrimary, align: .center)
            text("\(model.done) of \(model.total)", x: cx, baseline: cy + 62, size: 26, weight: .semibold,
                 color: AgaraColors.textMuted, align: .center)
        }
        let sx = cx + 132 + 72
        ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
            let ry = cy - 100 + CGFloat(i) * 100
            Circle().fill(AgaraColors.accent.opacity(40.0 / 255))
                .frame(width: 60 * k, height: 60 * k)
                .offset(x: sx * k, y: (ry - 30) * k)
            symbol(stat.symbol, cx: sx + 30, cy: ry, size: 34, color: AgaraColors.accent)
            statLine(stat, x: sx + 84, baseline: ry + 16, numberSize: 46, labelSize: 30, gap: 14, lift: 2)
        }

        // Today's eight, as tiles with the tracker's own symbols.
        tracked(AgaraCopy.ev40ShareActionsHeading, x: M, baseline: ty, size: 24, weight: .bold,
                color: AgaraColors.textMuted, tracking: 0.22)
        tracked("\(model.done)/\(model.total)", x: W - M, baseline: ty, size: 24, weight: .bold, color: highlight,
                tracking: 0.10, align: .trailing)
        ForEach(Array(model.disciplines.enumerated()), id: \.offset) { i, entry in
            let x0 = M + CGFloat(i % 2) * (tw + 20)
            let y0 = ty + 28 + CGFloat(i / 2) * (th + gap)
            let mid = y0 + th / 2
            let ic = x0 + 22 + 29
            panel(CGRect(x: x0, y: y0, width: tw, height: th), radius: 26)
            Circle().fill(entry.done ? AgaraColors.accent.opacity(40.0 / 255) : AgaraColors.cardSoft)
                .frame(width: 58 * k, height: 58 * k)
                .offset(x: (ic - 29) * k, y: (mid - 29) * k)
            symbol(entry.symbol, cx: ic, cy: mid, size: 32,
                   color: entry.done ? AgaraColors.accent : AgaraColors.textMuted)
            text(entry.name, x: ic + 46, baseline: mid + 10, size: entry.name.count < 13 ? 29 : 25,
                 weight: .semibold, color: entry.done ? AgaraColors.textPrimary : AgaraColors.textMuted)
            check(cx: x0 + tw - 22 - 18, cy: mid, r: 18, on: entry.done, glyph: 26)
        }

        // THE 40: a card holding two compact rows of twenty (D11).
        panel(box, radius: 40)
        tracked(AgaraCopy.ev40ShareJourneyHeading, x: M + pad, baseline: fy, size: 24, weight: .bold,
                color: AgaraColors.textMuted, tracking: 0.22)
        legend(right: W - M - pad, baseline: fy)
        ForEach(0..<Ev40Challenge.totalDays, id: \.self) { day in
            let x0 = M + pad + CGFloat(day % 20) * (cell + cellGap)
            let y0 = fy + 34 + CGFloat(day / 20) * (cell + cellGap + 4)
            dayCell(day, rect: CGRect(x: x0, y: y0, width: cell, height: cell), radius: 9, ring: 5)
        }
        let labels = fy + 34 + 2 * cell + cellGap + 4 + 40
        text("Day 1", x: M + pad, baseline: labels, size: 22, weight: .medium, color: AgaraColors.textMuted)
        text("Day \(Ev40Challenge.totalDays)", x: W - M - pad, baseline: labels, size: 22, weight: .medium,
             color: AgaraColors.textMuted, align: .trailing)

        footer
    }

    // MARK: Square

    @ViewBuilder private var square: some View {
        let cx = M + 100, cy: CGFloat = 420
        let step = IW / 8, iy: CGFloat = 620
        let fy: CGFloat = 760, gap: CGFloat = 6
        let cell = (IW - 39 * gap) / 40

        header
        text([model.userName, model.dateLine].compactMap { $0 }.joined(separator: " · "),
             x: M, baseline: 246, size: 48, weight: .bold, color: AgaraColors.textPrimary)
        ring(cx: cx, cy: cy, r: 100, stroke: 20)
        if model.isPerfect {
            symbol("star.fill", cx: cx, cy: cy, size: 70, color: highlight)
        } else {
            text("\(model.percent)%", x: cx, baseline: cy + 14, size: 48, weight: .bold,
                 color: AgaraColors.textPrimary, align: .center)
        }
        let sx = cx + 100 + 64
        ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
            let ry = cy - 70 + CGFloat(i) * 70
            symbol(stat.symbol, cx: sx + 20, cy: ry, size: 32, color: AgaraColors.accent)
            statLine(stat, x: sx + 56, baseline: ry + 13, numberSize: 38, labelSize: 26, gap: 12, lift: 1)
        }
        // The eight as symbol discs, a tick badge on the done ones.
        ForEach(Array(model.disciplines.enumerated()), id: \.offset) { i, entry in
            let ic = M + step * CGFloat(i) + step / 2
            Circle().fill(entry.done ? AgaraColors.accent.opacity(46.0 / 255) : AgaraColors.cardSoft)
                .frame(width: 84 * k, height: 84 * k)
                .offset(x: (ic - 42) * k, y: (iy - 42) * k)
            symbol(entry.symbol, cx: ic, cy: iy, size: 40,
                   color: entry.done ? AgaraColors.accent : AgaraColors.textMuted)
            if entry.done { check(cx: ic + 34, cy: iy - 32, r: 12, on: true, glyph: 18) }
        }
        // THE 40 as one strip.
        tracked(AgaraCopy.ev40ShareJourneyHeading, x: M, baseline: fy, size: 22, weight: .bold,
                color: AgaraColors.textMuted, tracking: 0.22)
        ForEach(0..<Ev40Challenge.totalDays, id: \.self) { day in
            dayCell(day, rect: CGRect(x: M + CGFloat(day) * (cell + gap), y: fy + 22, width: cell, height: 44),
                    radius: 6, ring: 4)
        }
        footer
    }

    // MARK: Shared parts

    /// The EV40 wordmark (owner's logo) with "BY AGARA" under it, and the day pill (D9) on the right.
    @ViewBuilder private var header: some View {
        mark(x: M, top: 92, height: 62, opacity: 1)
        tracked("BY AGARA", x: M, baseline: 194, size: 22, weight: .bold, color: AgaraColors.textMuted, tracking: 0.28)
        Text(model.pillLabel)
            .font(AgaraFont.face(28 * k, .bold))
            .tracking(0.12 * 28 * k)
            .foregroundStyle(highlight)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 26 * k)
            .frame(height: 60 * k)
            .background(Capsule().fill(highlight.opacity(46.0 / 255)))
            .frame(width: (W - M) * k, alignment: .trailing)
            .offset(y: 96 * k)
    }

    @ViewBuilder private var footer: some View {
        let story = format == .story
        let ruleY = H - (story ? 150 : 132)
        let baseline = H - (story ? 92 : 80)
        let size: CGFloat = story ? 32 : 28
        let card = ShareCardConfig.active()
        Rectangle().fill(AgaraColors.borderSubtle)
            .frame(width: IW * k, height: 2 * k)
            .offset(x: M * k, y: ruleY * k)
        text(AgaraCopy.ev40ChallengeTagline, x: M, baseline: baseline, size: size, weight: .medium,
             color: AgaraColors.textSecondary)
        if card.qr, let url = card.qrUrl {
            // The console switched the QR on (A6/D4): it encodes the address instead of spelling it out.
            qrCode(url)
                .frame(width: 108 * k, height: 108 * k)
                .offset(x: (W - M - 108) * k, y: (ruleY + 14) * k)
        } else {
            // The address the cloud names (R1), shrunk to whatever the tagline leaves.
            Text(card.displayUrl)
                .font(AgaraFont.face(size * k, .bold))
                .foregroundStyle(AgaraColors.accent)
                .lineLimit(1)
                .minimumScaleFactor(18 / size)
                .frame(width: (IW * 0.5) * k, alignment: .trailing)
                .offset(x: (W - M - IW * 0.5) * k, y: (baseline - Self.ascent * size) * k)
        }
    }

    private struct Stat { let symbol: String; let number: Int; let label: String }

    private var stats: [Stat] {
        [Stat(symbol: "flame.fill", number: model.streak, label: model.streakLabel),
         Stat(symbol: "calendar", number: model.daysActive, label: model.activeLabel),
         Stat(symbol: "star.fill", number: model.perfectDays, label: model.perfectLabel)]
    }

    /// "6 day streak": the number and its words on one baseline (the words sit `lift` px higher, as Android draws them).
    private func statLine(_ stat: Stat, x: CGFloat, baseline: CGFloat, numberSize: CGFloat, labelSize: CGFloat,
                          gap: CGFloat, lift: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: gap * k) {
            Text("\(stat.number)").font(AgaraFont.face(numberSize * k, .bold))
                .foregroundStyle(AgaraColors.textPrimary)
            Text(stat.label).font(AgaraFont.face(labelSize * k, .medium))
                .foregroundStyle(AgaraColors.textSecondary)
                .baselineOffset(lift * k)
        }
        .lineLimit(1)
        .fixedSize()
        .offset(x: x * k, y: (baseline - Self.ascent * numberSize) * k)
    }

    private func ring(cx: CGFloat, cy: CGFloat, r: CGFloat, stroke: CGFloat) -> some View {
        ZStack {
            Circle().inset(by: stroke / 2 * k).stroke(AgaraColors.cardSoft, lineWidth: stroke * k)
            if model.done > 0 {
                Circle().inset(by: stroke / 2 * k)
                    .trim(from: 0, to: model.fraction)
                    .stroke(highlight, style: StrokeStyle(lineWidth: stroke * k, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 2 * r * k, height: 2 * r * k)
        .offset(x: (cx - r) * k, y: (cy - r) * k)
    }

    /// One day of THE 40: shaded by effort up to today, outlined for the days to come, today ringed.
    @ViewBuilder private func dayCell(_ day: Int, rect: CGRect, radius: CGFloat, ring: CGFloat) -> some View {
        let today = model.journeyToday
        let future = today.map { day > $0 } ?? true
        let shape = RoundedRectangle(cornerRadius: radius * k, style: .continuous)
        Group {
            if future {
                shape.strokeBorder(AgaraColors.borderStrong, lineWidth: 2 * k)
            } else {
                let level = day < model.journey.count ? model.journey[day] : 0
                shape.fill(level > 0 ? AgaraColors.accent.opacity(Self.heat(level)) : AgaraColors.cardSoft)
            }
        }
        .frame(width: rect.width * k, height: rect.height * k)
        .offset(x: rect.minX * k, y: rect.minY * k)
        if day == today {
            RoundedRectangle(cornerRadius: (radius + 4) * k, style: .continuous)
                .strokeBorder(AgaraColors.textPrimary, lineWidth: 3 * k)
                .frame(width: (rect.width + 2 * ring) * k, height: (rect.height + 2 * ring) * k)
                .offset(x: (rect.minX - ring) * k, y: (rect.minY - ring) * k)
        }
    }

    /// "LESS ▪▪▪▪ MORE", right-aligned at `right` on `baseline`.
    @ViewBuilder private func legend(right: CGFloat, baseline: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(AgaraCopy.ev40ShareLegendLess).tracking(0.15 * 20 * k)
                .padding(.trailing, 4 * k)
            HStack(spacing: 6 * k) {
                ForEach(1...4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 5 * k).fill(AgaraColors.accent.opacity(Self.heat(level)))
                        .frame(width: 20 * k, height: 20 * k)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                }
            }
            .padding(.trailing, 12 * k)
            Text(AgaraCopy.ev40ShareLegendMore).tracking(0.15 * 20 * k)
        }
        .font(AgaraFont.face(20 * k, .semibold))
        .foregroundStyle(AgaraColors.textMuted)
        .fixedSize()
        .frame(width: right * k, alignment: .trailing)
        .offset(y: (baseline - Self.ascent * 20) * k)
    }

    private func check(cx: CGFloat, cy: CGFloat, r: CGFloat, on: Bool, glyph: CGFloat) -> some View {
        ZStack {
            if on {
                Circle().fill(AgaraColors.success)
                Image(systemName: "checkmark")
                    .font(.system(size: glyph * 0.62 * k, weight: .heavy))
                    .foregroundStyle(AgaraColors.card)
            } else {
                Circle().inset(by: 1.5 * k).stroke(AgaraColors.borderStrong, lineWidth: 3 * k)
            }
        }
        .frame(width: 2 * r * k, height: 2 * r * k)
        .offset(x: (cx - r) * k, y: (cy - r) * k)
    }

    private func panel(_ rect: CGRect, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius * k, style: .continuous)
        return shape.fill(AgaraColors.card)
            .overlay { shape.strokeBorder(AgaraColors.borderSubtle, lineWidth: 2 * k) }
            .frame(width: rect.width * k, height: rect.height * k)
            .offset(x: rect.minX * k, y: rect.minY * k)
    }

    /// The tracker's SF Symbol in a `size`-px box centred on (`cx`, `cy`) — the box Android's Material glyph fills.
    private func symbol(_ name: String, cx: CGFloat, cy: CGFloat, size: CGFloat, color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size * 0.78 * k, height: size * 0.78 * k)
            .frame(width: size * k, height: size * k)
            .offset(x: (cx - size / 2) * k, y: (cy - size / 2) * k)
    }

    // MARK: The mark

    /// Width ÷ height of the wordmark layers (963 × 169, `scripts/ev40_logo_extract.py`).
    static let markAspect: CGFloat = 963.0 / 169.0

    /// The wordmark `height` px tall at (`x`, `top`): "EV" in the mark's own orange, "40" tinted to the theme's text.
    private func mark(x: CGFloat, top: CGFloat, height: CGFloat, opacity: Double) -> some View {
        let size = CGSize(width: height * Self.markAspect * k, height: height * k)
        return ZStack {
            Image("ev40-mark-ev").resizable().renderingMode(.original)
            Image("ev40-mark-forty").resizable().renderingMode(.template).foregroundStyle(AgaraColors.textPrimary)
        }
        .frame(width: size.width, height: size.height)
        .opacity(opacity)
        .offset(x: x * k, y: top * k)
        .accessibilityHidden(true)
    }

    // MARK: Text

    private enum Align { case leading, center, trailing }

    /// Text placed by its baseline, the way Android's `Canvas.drawText` places it. `x` is the leading edge, the centre or
    /// the trailing edge depending on `align`.
    private func text(_ s: String, x: CGFloat, baseline: CGFloat, size: CGFloat, weight: Font.Weight, color: Color,
                      align: Align = .leading) -> some View {
        tracked(s, x: x, baseline: baseline, size: size, weight: weight, color: color, tracking: 0, align: align)
    }

    @ViewBuilder
    private func tracked(_ s: String, x: CGFloat, baseline: CGFloat, size: CGFloat, weight: Font.Weight, color: Color,
                         tracking: CGFloat, align: Align = .leading) -> some View {
        let label = Text(s)
            .font(AgaraFont.face(size * k, weight))
            .tracking(tracking * size * k)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
        let y = (baseline - Self.ascent * size) * k
        switch align {
        case .leading: label.offset(x: x * k, y: y)
        case .trailing: label.frame(width: x * k, alignment: .trailing).offset(y: y)
        case .center: label.frame(width: 2 * x * k, alignment: .center).offset(y: y)
        }
    }

    /// The four heat shades: more ticks, deeper colour (1–2, 3–4, 5–7, 8 of the eight). Same values as Android `heat`.
    static func heat(_ level: Int) -> Double {
        switch level {
        case 1: 0.30
        case 2: 0.55
        case 3: 0.80
        default: 1.0
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

    /// Today's day of the challenge (1…40), or nil before it starts — the pill's number (v3 D9).
    var dayNumber: Int? = nil

    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let done: Bool
        /// The tracker's own SF Symbol for this discipline (`Ev40Discipline.symbol`).
        var symbol: String { Ev40Discipline(rawValue: id)?.symbol ?? "circle" }
    }

    /// "DAY 14 / 40", or "TODAY" before the challenge has a first ticked day (D9). Mirror of Android `pillLabel`.
    var pillLabel: String {
        guard let day = dayNumber, (1...Ev40Challenge.totalDays).contains(day) else { return AgaraCopy.ev40CardPillToday }
        return "DAY \(day) / \(Ev40Challenge.totalDays)"
    }

    /// The words after each stat's number, singular when the count is exactly 1 (v3 replaced the one stats line with a
    /// row per stat). Mirror of Android.
    var streakLabel: String { AgaraCopy.ev40ShareStreak }
    var activeLabel: String { daysActive == 1 ? AgaraCopy.ev40ShareDayActive : AgaraCopy.ev40ShareDaysActive }
    var perfectLabel: String { perfectDays == 1 ? AgaraCopy.ev40SharePerfectDay : AgaraCopy.ev40SharePerfectDays }

    var percent: Int { total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded()) }
    /// The ring's sweep; an empty day still draws its cap rather than nothing.
    var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
    /// All eight today: green pill, green ring, a star in the ring (D9).
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
            journeyToday: slots.1,
            dayNumber: day)
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
