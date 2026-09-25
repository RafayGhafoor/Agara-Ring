import SwiftUI

/// The app's single typographic scale, in Manrope (bundled; registered at launch by `AgaraFontRegistry`).
///
/// Every text style flows through one of these tokens instead of an ad-hoc
/// `.system(size:weight:)`, so typography stays consistent and can be re-tuned in
/// one place. Tokens carry a size + sensible default weight (numerics use tabular figures —
/// never a monospace face). Override the weight at a call site with
/// the standard `.weight(_:)` when a specific line needs it:
///
///     Text("Title").font(PulseFont.headline)
///     Text("14").font(PulseFont.subheadline.weight(.semibold))
///     Text("8,401").font(PulseFont.numberXL)
///
/// The sizes and weights come from the shared catalog (`docs/config/typography.yaml` →
/// `Generated/AgaraFont.swift`), the same numbers Android uses; re-tune the scale there, not here.
/// This enum stays as the call-site name so the 470 existing uses don't churn.
enum PulseFont {

    // MARK: Titles (San Francisco, default design)

    /// Onboarding / big hero titles. (was 34–38)
    static let largeTitle = AgaraFont.largeTitle
    /// Home greeting and screen-defining headers. (was 30–32)
    static let greeting   = AgaraFont.greeting
    /// Section-defining title. (was 26–28)
    static let title      = AgaraFont.title
    /// Secondary title. (was 22)
    static let title2     = AgaraFont.title2
    /// Tertiary title / prominent card heading. (was 18–20)
    static let title3     = AgaraFont.title3
    /// Standard heading, nav-bar title, list headline. (was 17)
    static let headline   = AgaraFont.headline

    // MARK: Body & labels

    /// Emphasized body / row title. (was 16 semibold)
    static let bodyEmphasis = AgaraFont.bodyEmphasis
    /// Body copy and list-row titles. (was 16 regular)
    static let body         = AgaraFont.body
    /// Slightly smaller body / secondary action. (was 15)
    static let callout      = AgaraFont.callout
    /// Compact labels and secondary values. (was 14, default medium)
    static let subheadline  = AgaraFont.subheadline
    /// Footnotes, hints, trailing values. (was 13)
    static let footnote     = AgaraFont.footnote
    /// Captions. (was 12)
    static let caption      = AgaraFont.caption
    /// Small captions and uppercase section headers. (was 11)
    static let caption2     = AgaraFont.caption2
    /// Micro labels (axis ticks, chips). (was 10)
    static let micro        = AgaraFont.micro
    /// Smallest label. (was 8–9)
    static let nano         = AgaraFont.nano

    // MARK: Numerics (SF Rounded)

    /// Hero metric number. (was 38–60)
    static let numberHero = AgaraFont.numberHero
    /// Large metric number. (was 30–32)
    static let numberXL   = AgaraFont.numberXL
    /// Medium metric number. (was 22–28)
    static let numberL    = AgaraFont.numberL
    /// Inline metric / stat. (was 17–20)
    static let numberM    = AgaraFont.numberM

    /// Escape hatch for a rounded numeric at an exact size the scale doesn't name
    /// (rare very-large display digits, precisely-fitted gauges).
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        AgaraFont.face(size, weight).monospacedDigit()
    }
}
