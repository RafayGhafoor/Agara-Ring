import SwiftUI

#if DEBUG
/// Settings › Developer › Feature flags (debug builds only): one toggle per shared flag
/// (`docs/config/features.yaml`), persisted as `AgaraFeatureStore` overrides. A flag showing its
/// catalog default has no override; "Reset to defaults" clears them all.
struct FeatureFlagsView: View {
    @State private var store = AgaraFeatureStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsGroup(
                        header: "Feature flags",
                        footer: "Debug builds only. Overrides persist until reset; launch with "
                            + "-features \"name=on,name=off\" to set them at start-up."
                    ) {
                        ForEach(AgaraFeature.allCases, id: \.self) { feature in
                            FormToggleRow(title: title(feature), isOn: binding(feature))
                        }
                    }
                    SecondaryButton(title: "Reset to defaults", systemImage: "arrow.uturn.backward") {
                        store.resetAll()
                    }
                }
                .padding()
            }
            .background(AgaraColors.background)
            .navigationTitle("Feature flags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// The flag key, marked when it differs from the shipped default.
    private func title(_ feature: AgaraFeature) -> String {
        store.override(for: feature) == nil ? feature.rawValue : "\(feature.rawValue) •"
    }

    private func binding(_ feature: AgaraFeature) -> Binding<Bool> {
        Binding(
            get: { store.isOn(feature) },
            set: { value in store.setOverride(feature, value == feature.defaultOn ? nil : value) }
        )
    }
}
#endif
