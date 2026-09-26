import SwiftUI
import SwiftData

/// Full page for one logged meal (pushed via `AppRoute.mealDetail`): kcal + macro breakdown,
/// serving info, full nutrition facts, and provenance. Edit opens `MealLogSheet` prefilled;
/// delete confirms then pops.
struct MealDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mealId: UUID
    @Binding var path: NavigationPath

    @State private var dataChange = AgaraDataChange.shared
    @State private var entry: MealEntry?
    @State private var editSheet = false
    @State private var deleteConfirm = false

    private func reload() {
        entry = NutritionRepository.entry(id: mealId, context: modelContext)
    }

    var body: some View {
        ScrollView {
            if let entry {
                VStack(spacing: 16) {
                    if let photo = CoachAttachmentRef.decode(fromJSON: entry.photoRefJSON).first
                        .flatMap({ CoachAttachmentStore.loadImage($0) }) {
                        Image(uiImage: photo)
                            .resizable().scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
                    }
                    titleBlock(entry)
                    kcalMacroCard(entry)
                    if entry.servingDescription != nil || entry.quantity != 1 {
                        servingCard(entry)
                    }
                    factsCard(entry)
                    if let notes = entry.notes, !notes.isEmpty {
                        DetailCard(title: "Notes", color: AgaraColors.textMuted) {
                            Text(notes)
                                .font(AgaraFont.body)
                                .foregroundStyle(AgaraColors.textSecondary)
                                .padding(.top, 12)
                        }
                    }
                    sourceFooter(entry)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            } else {
                EmptyStateView(title: "Meal not found", body: "This entry was deleted.")
                    .padding(.top, 60)
            }
        }
        .background(AgaraColors.background)
        .pageChrome(entry?.name ?? "Meal") {
            if entry != nil {
                Menu {
                    Button { editSheet = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { deleteConfirm = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(AgaraFont.bodyEmphasis)
                        .foregroundStyle(AgaraColors.textPrimary)
                        .frame(width: 36, height: 36)
                        .agaraGlass(Circle(), interactive: true)
                        .minTapTarget(visualSize: 36)
                }
                .accessibilityLabel("Meal actions")
            }
        }
        .agaraScrollEdges()
        .task(id: dataChange.token) { reload() }
        .sheet(isPresented: $editSheet) {
            if let entry {
                MealLogSheet(day: entry.date, presetMealType: entry.mealType, editingId: entry.id)
            }
        }
        .confirmationDialog("Delete this meal?", isPresented: $deleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                NutritionRepository.delete(id: mealId, context: modelContext)
                dismiss()
            }
        }
    }

    // MARK: - Sections

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f
    }()

    private func titleBlock(_ entry: MealEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.mealType.label.uppercased())
                    .font(AgaraFont.micro.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(AgaraColors.calories)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AgaraColors.calories.opacity(0.14), in: Capsule())
                ProvenanceBadge(source: entry.source, userEdited: entry.userEdited)
            }
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(AgaraFont.caption.weight(.regular))
                .foregroundStyle(AgaraColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Energy headline only — the Nutrition Facts card below owns the full macro
    /// breakdown, so repeating P/C/F here just restated the table.
    private func kcalMacroCard(_ entry: MealEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(NutritionFormat.kcal(entry.calories))
                .activityValueStyle(size: 40)
            Text("kcal")
                .font(AgaraFont.subheadline)
                .foregroundStyle(AgaraColors.textMuted)
            Spacer()
            Text("ENERGY")
                .font(AgaraFont.micro.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(AgaraColors.calories)
        }
        .padding(16)
        .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
    }

    private func servingCard(_ entry: MealEntry) -> some View {
        DetailCard(title: "Serving", color: AgaraColors.calories) {
            VStack(alignment: .leading, spacing: 6) {
                if let serving = entry.servingDescription {
                    factRow("Serving size", serving)
                }
                factRow("Quantity", quantityText(entry.quantity))
            }
            .padding(.top, 12)
        }
    }

    private func quantityText(_ quantity: Double) -> String {
        quantity == quantity.rounded() ? "\(Int(quantity))" : String(format: "%.2g", quantity)
    }

    private func factsCard(_ entry: MealEntry) -> some View {
        DetailCard(title: "Nutrition Facts", color: AgaraColors.calories) {
            VStack(spacing: 0) {
                // No Calories row — the hero strip above owns energy.
                factDividedRow("Protein", "\(NutritionFormat.grams(entry.proteinG)) g", first: true)
                factDividedRow("Carbohydrates", "\(NutritionFormat.grams(entry.carbsG)) g")
                if let fiber = entry.fiberG {
                    factDividedRow("Fiber", "\(NutritionFormat.grams(fiber)) g", indented: true)
                }
                if let sugar = entry.sugarG {
                    factDividedRow("Sugar", "\(NutritionFormat.grams(sugar)) g", indented: true)
                }
                factDividedRow("Fat", "\(NutritionFormat.grams(entry.fatG)) g")
                if let sodium = entry.sodiumMg {
                    factDividedRow("Sodium", "\(NutritionFormat.grams(sodium)) mg")
                }
            }
            .padding(.top, 8)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(AgaraFont.body).foregroundStyle(AgaraColors.textSecondary)
            Spacer()
            Text(value)
                .font(AgaraFont.body.monospacedDigit())
                .foregroundStyle(AgaraColors.textPrimary)
        }
    }

    private func factDividedRow(_ label: String, _ value: String, first: Bool = false, indented: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first {
                Divider().overlay(AgaraColors.borderSubtle)
            }
            HStack {
                Text(label)
                    .font(indented ? AgaraFont.subheadline.weight(.regular) : AgaraFont.body)
                    .foregroundStyle(indented ? AgaraColors.textMuted : AgaraColors.textSecondary)
                    .padding(.leading, indented ? 16 : 0)
                Spacer()
                Text(value)
                    .font(AgaraFont.body.monospacedDigit())
                    .foregroundStyle(AgaraColors.textPrimary)
            }
            .padding(.vertical, 10)
        }
    }

    private func sourceFooter(_ entry: MealEntry) -> some View {
        let text: String
        switch entry.source {
        case .offBarcode, .offSearch:
            text = "Nutrition data from Open Food Facts"
        case .llmEstimate:
            text = entry.userEdited ? "Estimated by AI Coach, adjusted by you" : "Estimated by AI Coach"
        case .manual:
            text = "Entered manually"
        }
        return Text(text)
            .font(AgaraFont.caption.weight(.regular))
            .foregroundStyle(AgaraColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
