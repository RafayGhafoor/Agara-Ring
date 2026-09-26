import SwiftUI
import SwiftData

/// Settings › Appearance: light/dark mode (System follows the OS live) and the colour flavour. Applies at
/// once — `RootAppView` resolves the choice into `ThemeStore`. Mirrors Android `AppearanceSettingsScreen`.
struct AppearanceSettingsView: View {
    @State private var store = AppearanceStore.shared
    @State private var themeStore = ThemeStore.shared
    @Query private var profiles: [UserProfile]

    private var modeBinding: Binding<AppearanceMode> {
        Binding(get: { store.mode }, set: { store.setMode($0) })
    }

    private var selectedFlavour: String { store.flavour(sex: profiles.first?.sex) }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        // Reading the observable theme keeps this screen in step even though it sits above the root's rebuild.
        let current = themeStore.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(header: "Mode", footer: "System follows your iPhone's light or dark setting.") {
                    FormField {
                        Picker("Mode", selection: modeBinding) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("COLOURS")
                        .font(AgaraFont.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(AgaraColors.textMuted)
                        .padding(.leading, 16)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AppearanceFlavour.all) { flavour in
                            FlavourSwatchCard(
                                flavour: flavour,
                                isLight: current.isLight,
                                selected: flavour.id == selectedFlavour
                            ) {
                                store.setFlavour(flavour.id)
                            }
                        }
                    }
                    if store.storedFlavour == nil {
                        Text("Until you pick, colours follow your profile.")
                            .font(AgaraFont.caption.weight(.regular))
                            .foregroundStyle(AgaraColors.textMuted)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding()
        }
        .background(AgaraColors.background)
        .navigationTitle("Appearance")
    }
}

/// A flavour as a small preview: its ground, a card, a text line and the accent, in the variant (dark or
/// light) currently shown, with a check when selected.
private struct FlavourSwatchCard: View {
    let flavour: AppearanceFlavour
    let isLight: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let t = flavour.theme(isLight: isLight)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                // Mini screen: ground → card → a title bar and an accent pill.
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.background)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(t.textPrimary).frame(width: 46, height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(t.textMuted).frame(width: 30, height: 5)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Capsule().fill(t.accent).frame(width: 34, height: 12)
                            Circle().fill(t.heartRate).frame(width: 8, height: 8)
                            Circle().fill(t.sleep).frame(width: 8, height: 8)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(t.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(8)
                }
                .frame(height: 84)

                HStack {
                    Text(flavour.name)
                        .font(AgaraFont.callout.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AgaraColors.accent : AgaraColors.textMuted)
                }
            }
            .padding(10)
            .background(AgaraColors.card, in: RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                    .strokeBorder(selected ? AgaraColors.accent : AgaraColors.borderSubtle, lineWidth: selected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flavour.name) colours")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
