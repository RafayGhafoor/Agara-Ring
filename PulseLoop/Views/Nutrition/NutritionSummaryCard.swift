import SwiftUI

/// Full-width nutrition summary on the Activity page — the intake sibling of
/// `DailyActivitySummaryCard`: EATEN and muted BURNED stats on the left, the eaten-vs-goal
/// ring on the right, macro mini-bars along the bottom. Tapping opens the Nutrition page.
/// Rendered only when the nutrition feature is enabled.
struct NutritionSummaryCard: View {
    let totals: NutritionDayTotals
    let goals: GoalsSummary
    /// Active-energy burned today; informational, muted.
    let burned: Double?
    var onTap: () -> Void

    private var goal: Int? { goals.intakeCalories }
    private var remaining: Double? { goal.map { Double($0) - totals.calories } }
    private var ringColor: Color {
        goal.map { NutritionFormat.progressColor(consumed: totals.calories, goal: Double($0), base: AgaraColors.calories) }
            ?? AgaraColors.calories
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 18) {
                        metric(label: "Eaten", value: NutritionFormat.kcal(totals.calories),
                               unit: "kcal", color: AgaraColors.calories)
                        metric(label: "Burned", value: burned.map { NutritionFormat.kcal($0) } ?? "—",
                               unit: burned == nil ? nil : "kcal", color: AgaraColors.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ProgressRingView(
                        value: totals.calories,
                        max: Double(goal ?? 0),
                        size: 112,
                        stroke: 11,
                        color: ringColor
                    ) {
                        VStack(spacing: 0) {
                            if let remaining {
                                Text(NutritionFormat.kcal(max(0, remaining)))
                                    .font(AgaraFont.title3)
                                    .monospacedDigit()
                                    .foregroundStyle(AgaraColors.textPrimary)
                                Text(remaining >= 0 ? "LEFT" : "OVER")
                                    .font(AgaraFont.micro.weight(.semibold))
                                    .tracking(1.0)
                                    .foregroundStyle(remaining >= 0 ? AgaraColors.textMuted : ringColor)
                            } else {
                                Text("SET")
                                    .font(AgaraFont.micro.weight(.semibold)).tracking(1.0)
                                    .foregroundStyle(AgaraColors.textMuted)
                                Text("GOAL")
                                    .font(AgaraFont.micro.weight(.semibold)).tracking(1.0)
                                    .foregroundStyle(AgaraColors.textMuted)
                            }
                        }
                    }
                    .frame(width: 112, height: 112)
                }
                MacroMiniBars(totals: totals, goals: goals)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func metric(label: String, value: String, unit: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(AgaraFont.callout.weight(.bold)).tracking(0.6)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .activityValueStyle(size: 32)
                if let unit {
                    Text(unit).font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
