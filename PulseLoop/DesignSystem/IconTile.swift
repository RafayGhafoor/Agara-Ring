import SwiftUI

/// The one icon tile (consistency framework, block A — AGENTS.md Rule 10): a fixed box with the glyph fitted
/// into a fixed inner square, so every symbol sits at the same optical size wherever tiles line up (Measure
/// grid, settings rows, cards). Mirrors Android's `IconTile`.
///
/// Why a fitted box rather than a font size: SF Symbols drawn at one point size have different heights —
/// `heart.text.square` is a full square while `heart.fill` is short and wide — which is what made the blood
/// pressure tile look taller than its neighbours. Fitting every glyph into the same square, then shrinking
/// the ones that draw their own enclosure (`IconTileOptics`), lines them up.
struct IconTile: View {
    enum Size {
        /// 28 pt — inline rows and chips.
        case small
        /// 34 pt — settings rows.
        case medium
        /// 44 pt — Measure tiles, list rows, cards.
        case large
        /// 56 pt — hero spots (About's social links). Android's `IconTileSize.LARGE`.
        case hero

        var box: CGFloat {
            switch self {
            case .small: return 28
            case .medium: return 34
            case .large: return 44
            case .hero: return 56
            }
        }

        /// The square every glyph is fitted into.
        var glyph: CGFloat { (box * 0.5).rounded() }

        var cornerRadius: CGFloat {
            switch self {
            case .small: return 9
            case .medium: return 12
            case .large: return 14
            case .hero: return 18
            }
        }
    }

    enum Style {
        /// Metric-coloured glyph on a soft wash of the same colour (Measure tiles, workout rows). The wash
        /// opacity matches Android's `backgroundAlpha` (0.14 by default; the Measure tiles use 0.18).
        case tinted(Color, backgroundOpacity: Double = 0.14)
        /// Accent glyph on the palette's `accentSoft` (About's social links).
        case accent
        /// Neutral glass tile with a white glyph (settings rows — the iOS Settings look).
        case neutral
    }

    enum Shape { case circle, rounded }

    let systemName: String
    var style: Style = .neutral
    var size: Size = .medium
    var shape: Shape = .rounded

    var body: some View {
        let scale = IconTileOptics.scale(for: systemName)
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(glyphColor)
            .frame(width: size.glyph * scale, height: size.glyph * scale)
            .frame(width: size.box, height: size.box)
            .background { background }
            .accessibilityHidden(true)
    }

    private var glyphColor: Color {
        switch style {
        case .tinted(let tint, _): return tint
        case .accent: return AgaraColors.accent
        case .neutral: return AgaraColors.textPrimary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch (style, shape) {
        case (.tinted(let tint, let opacity), .circle):
            Circle().fill(tint.opacity(opacity))
        case (.tinted(let tint, let opacity), .rounded):
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous).fill(tint.opacity(opacity))
        case (.accent, .circle):
            Circle().fill(AgaraColors.accentSoft)
        case (.accent, .rounded):
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous).fill(AgaraColors.accentSoft)
        case (.neutral, _):
            // A light translucent fill with a top sheen — not `glassEffect`, which can't nest inside a glass card.
            let tile = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            tile.fill(LinearGradient(colors: [AgaraColors.textPrimary.opacity(0.16), AgaraColors.textPrimary.opacity(0.07)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(tile.strokeBorder(AgaraColors.textPrimary.opacity(0.18), lineWidth: 0.5))
        }
    }
}

/// The optical padding rule: a symbol that draws its own enclosure (`….square`, `….circle`, `….rectangle`)
/// fills its whole bounding box, so at the same fitted size it reads larger than an open glyph. Those are drawn
/// at 82 %; everything else at 100 %. Android's `IconTile` applies the same factor to its Material icons.
enum IconTileOptics {
    static let enclosedScale: CGFloat = 0.82

    static func scale(for systemName: String) -> CGFloat {
        let parts = systemName.split(separator: ".")
        let enclosures: Set<Substring> = ["square", "circle", "rectangle", "app"]
        return parts.dropFirst().contains(where: enclosures.contains) ? enclosedScale : 1
    }
}
