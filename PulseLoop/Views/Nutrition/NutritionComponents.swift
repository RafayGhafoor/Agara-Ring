import SwiftUI
import UIKit

// Shared building blocks for the nutrition feature: the calorie budget gauge, macro progress
// bars, meal rows, and the provenance badge. All follow the Liquid Glass design system and are
// reused across the Nutrition page, Activity card, Today tile, and coach chat meal card.

/// One macro's identity: display name, single-letter tag, and token color.
enum MacroKind: CaseIterable {
    case protein, carbs, fat

    var name: String {
        switch self {
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        }
    }

    var letter: String {
        switch self {
        case .protein: return "P"
        case .carbs: return "C"
        case .fat: return "F"
        }
    }

    var color: Color {
        switch self {
        case .protein: return AgaraColors.macroProtein
        case .carbs: return AgaraColors.macroCarbs
        case .fat: return AgaraColors.macroFat
        }
    }
}

enum NutritionFormat {
    static func kcal(_ value: Double) -> String { Int(value.rounded()).formatted() }
    static func grams(_ value: Double) -> String { "\(Int(value.rounded()))" }

    /// Fill color for consumed-vs-goal progress: metric color while under goal, warning slightly
    /// over, danger well over — mirrors the vitals zone idiom (never a hard red at 101%).
    static func progressColor(consumed: Double, goal: Double, base: Color) -> Color {
        guard goal > 0, consumed > goal else { return base }
        return consumed <= goal * 1.15 ? AgaraColors.warning : AgaraColors.danger
    }
}

// MARK: - Macro mini bar

/// A thin capsule progress bar for one macro (value vs goal). Goal-less bars render as a muted
/// track only — no invented targets.
struct MacroMiniBar: View {
    let value: Double
    let goal: Double?
    var color: Color
    var height: CGFloat = 4

    private var fraction: Double {
        guard let goal, goal > 0 else { return 0 }
        return min(1, max(0, value / goal))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AgaraColors.elevated)
                if fraction > 0 {
                    Capsule()
                        .fill(goal.map { NutritionFormat.progressColor(consumed: value, goal: $0, base: color) } ?? color)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
    }
}

/// The three macro mini-bars in one row with `P 80/112g`-style micro labels. Used on the
/// Activity summary card and (vertically) the Today tile.
struct MacroMiniBars: View {
    let totals: NutritionDayTotals
    let goals: GoalsSummary

    var body: some View {
        HStack(spacing: 12) {
            column(.protein, value: totals.proteinG, goal: goals.intakeProteinG)
            column(.carbs, value: totals.carbsG, goal: goals.intakeCarbsG)
            column(.fat, value: totals.fatG, goal: goals.intakeFatG)
        }
    }

    private func column(_ kind: MacroKind, value: Double, goal: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(kind.letter)
                    .font(AgaraFont.micro.weight(.semibold))
                    .foregroundStyle(kind.color)
                Text(goal.map { "\(NutritionFormat.grams(value))/\($0)g" } ?? "\(NutritionFormat.grams(value))g")
                    .font(AgaraFont.micro.weight(.medium).monospacedDigit())
                    .foregroundStyle(AgaraColors.textMuted)
                    .lineLimit(1)
            }
            MacroMiniBar(value: value, goal: goal.map(Double.init), color: kind.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Macro progress row (Nutrition page)

/// Full-width macro row: colored dot + name, `80 / 112 g`, and a 6pt progress bar.
struct MacroProgressRow: View {
    let kind: MacroKind
    let consumed: Double
    let goal: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(kind.color).frame(width: 8, height: 8)
                        .shadow(color: kind.color.opacity(0.7), radius: 5)
                    Text(kind.name)
                        .font(AgaraFont.subheadline)
                        .foregroundStyle(AgaraColors.textPrimary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(NutritionFormat.grams(consumed))
                        .font(AgaraFont.numberM)
                        .monospacedDigit()
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text(goal.map { "/ \($0) g" } ?? "g")
                        .font(AgaraFont.caption.weight(.regular).monospacedDigit())
                        .foregroundStyle(AgaraColors.textMuted)
                }
            }
            MacroMiniBar(value: consumed, goal: goal.map(Double.init), color: kind.color, height: 6)
        }
    }
}

// MARK: - Calorie budget gauge (Nutrition page hero)

/// The page hero: a large eaten-vs-goal ring with remaining kcal in the center, flanked by
/// EATEN and BURNED stat columns. With no goal set, the ring stays a muted track and the
/// center shows total eaten — the app never invents a calorie target.
struct CalorieBudgetGauge: View {
    let totals: NutritionDayTotals
    let goal: Int?
    /// Active-energy burned today (from the existing activity summary); informational.
    let burned: Double?

    private var remaining: Double? { goal.map { Double($0) - totals.calories } }
    private var ringColor: Color {
        goal.map { NutritionFormat.progressColor(consumed: totals.calories, goal: Double($0), base: AgaraColors.calories) }
            ?? AgaraColors.calories
    }

    var body: some View {
        // No footer restating the ring's own inputs — the ring + EATEN/BURNED columns are
        // the whole story (Oura/Whoop idiom). Only the goal-less state gets one hint line.
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                stat("EATEN", NutritionFormat.kcal(totals.calories), AgaraColors.calories)
                Spacer(minLength: 8)
                ProgressRingView(
                    value: totals.calories,
                    max: Double(goal ?? 0),
                    size: 140,
                    stroke: 12,
                    color: ringColor
                ) {
                    VStack(spacing: 2) {
                        if let remaining {
                            Text(NutritionFormat.kcal(max(0, remaining)))
                                .font(AgaraFont.numberXL)
                                .monospacedDigit()
                                .foregroundStyle(AgaraColors.textPrimary)
                            Text(remaining >= 0 ? "LEFT" : "OVER")
                                .font(AgaraFont.micro.weight(.semibold))
                                .tracking(1.0)
                                .foregroundStyle(remaining >= 0 ? AgaraColors.textMuted : ringColor)
                        } else {
                            Text(NutritionFormat.kcal(totals.calories))
                                .font(AgaraFont.numberXL)
                                .monospacedDigit()
                                .foregroundStyle(AgaraColors.textPrimary)
                            Text("KCAL")
                                .font(AgaraFont.micro.weight(.semibold))
                                .tracking(1.0)
                                .foregroundStyle(AgaraColors.textMuted)
                        }
                    }
                }
                Spacer(minLength: 8)
                stat("BURNED", burned.map { NutritionFormat.kcal($0) } ?? "—", AgaraColors.textMuted)
            }
            if goal == nil {
                Text("No calorie goal set — add one in Nutrition settings")
                    .font(AgaraFont.caption.weight(.regular))
                    .foregroundStyle(AgaraColors.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .activityValueStyle(size: 24)
            Text(label)
                .font(AgaraFont.micro.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Provenance badge

/// Small capsule stating where an entry's numbers came from — the honesty marker required by
/// the "we don't guess" principle. Database-verified (Open Food Facts), AI estimate, or manual.
struct ProvenanceBadge: View {
    let source: MealEntrySource
    var userEdited: Bool = false

    private var symbol: String {
        switch source {
        case .offBarcode, .offSearch: return "checkmark.seal"
        case .llmEstimate: return "sparkles"
        case .manual: return "pencil"
        }
    }

    private var label: String {
        if userEdited { return "Edited" }
        switch source {
        case .offBarcode, .offSearch: return "Verified"
        case .llmEstimate: return "AI estimate"
        case .manual: return "Manual"
        }
    }

    private var color: Color {
        switch source {
        case .offBarcode, .offSearch: return AgaraColors.success
        case .llmEstimate: return AgaraColors.accent
        case .manual: return AgaraColors.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(AgaraFont.micro)
            Text(label).font(AgaraFont.micro.weight(.semibold)).tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Meal entry row

/// One logged meal in a list: leading food square, name + time, and the kcal/macro strip.
/// Shared by the Nutrition page and the coach chat meal card so both read identically —
/// the same relationship `ActivityWorkoutRow` has with its surfaces.
struct MealEntryRow: View {
    let entry: MealEntry
    var onTap: (() -> Void)?

    /// Meal photo, when the entry was logged from one (bytes live in the attachment store).
    private var photo: UIImage? {
        CoachAttachmentRef.decode(fromJSON: entry.photoRefJSON).first.flatMap { CoachAttachmentStore.loadImage($0) }
    }

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 12) {
                Group {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable().scaledToFill()
                    } else {
                        Image(systemName: "fork.knife")
                            .font(AgaraFont.title3.weight(.regular))
                            .foregroundStyle(AgaraColors.calories)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AgaraColors.calories.opacity(0.18))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.name)
                            .font(AgaraFont.subheadline.weight(.semibold))
                            .foregroundStyle(AgaraColors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(SleepFormat.clockTime(entry.timestamp))
                            .font(AgaraFont.caption2.weight(.regular).monospacedDigit())
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                    // One headline metric per row (kcal); macros live on the detail page —
                    // per-row P/C/F tags made the list noisy. The sparkle stays: it's the
                    // at-a-glance provenance marker for unreviewed AI estimates.
                    HStack(spacing: 8) {
                        Text("\(NutritionFormat.kcal(entry.calories)) kcal")
                            .font(AgaraFont.caption.weight(.regular).monospacedDigit())
                            .foregroundStyle(AgaraColors.textMuted)
                        if entry.source == .llmEstimate && !entry.userEdited {
                            Image(systemName: "sparkles")
                                .font(AgaraFont.micro)
                                .foregroundStyle(AgaraColors.accent)
                        }
                    }
                }
            }
            .padding(16)
            .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

// MARK: - First-run explainer

/// Shown on the Nutrition page until the first meal is ever logged: one glass card stating
/// what to do and the privacy stance. No modal onboarding.
struct NutritionEmptyStateCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "fork.knife.circle")
                .font(AgaraFont.largeTitle.weight(.regular))
                .foregroundStyle(AgaraColors.calories)
            Text("Log your first meal")
                .font(AgaraFont.bodyEmphasis)
                .foregroundStyle(AgaraColors.textPrimary)
            Text("Add meals manually, search the food database, or describe them to your coach. Everything stays on your device.")
                .font(AgaraFont.caption.weight(.regular))
                .foregroundStyle(AgaraColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
    }
}
