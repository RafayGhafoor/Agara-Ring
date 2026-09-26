import SwiftUI

/// Call-site additions to the generated type scale (`Generated/AgaraFont.swift`, from
/// `docs/config/typography.yaml` — the same numbers Android uses; re-tune the scale there).
///
/// Every text style flows through an `AgaraFont` token instead of an ad-hoc `.system(size:weight:)`.
/// Tokens carry a size + sensible default weight (numerics use tabular figures — never a monospace
/// face). Override the weight at a call site with the standard `.weight(_:)`:
///
///     Text("Title").font(AgaraFont.headline)
///     Text("14").font(AgaraFont.subheadline.weight(.semibold))
///     Text("8,401").font(AgaraFont.numberXL)
///
/// (This file used to hold a pass-through alias enum for every generated token; the tokens are now
/// used directly and only the escape hatch below remains.)
extension AgaraFont {
    /// Escape hatch for a rounded numeric at an exact size the scale doesn't name
    /// (rare very-large display digits, precisely-fitted gauges).
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        face(size, weight).monospacedDigit()
    }
}
