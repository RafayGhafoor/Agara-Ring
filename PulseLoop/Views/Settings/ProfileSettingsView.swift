import SwiftUI
import SwiftData

/// The Settings host for the same compact profile editor used during onboarding.
struct ProfileSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]

    @State private var draft = ProfileDraft()
    @State private var loaded = false
    @State private var importing = false
    @State private var importStatus: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileEditorView(draft: $draft)
                if AgaraFeatureStore.isOn(.vitalsGlucose) || AgaraFeatureStore.isOn(.bloodComponents) { unitsGroup }
                appleHealthImport
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AgaraColors.background)
        .pageChrome("Profile")
        .onAppear(perform: loadIfNeeded)
        // Autosave: every field edit persists immediately — no explicit Save step. Health-imported
        // values flow through the same `draft` bindings, so this also persists them.
        .onChange(of: draft) { _, _ in autosave() }
    }

    /// Display units. The glucose unit lives here (not in Physiology) so it stays reachable with the
    /// `physiology` flag off — parity audit 2026-09-26, same move as Android.
    private var unitsGroup: some View {
        SettingsGroup(header: "Units", footer: "How blood glucose readings are shown.") {
            FormValueRow(title: "Glucose unit") {
                Picker("Glucose unit", selection: Binding(
                    get: { profiles.first?.preferredGlucoseUnit ?? .mgdl },
                    set: { setGlucoseUnit($0) }
                )) {
                    ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("profile.glucoseUnit")
            }
        }
    }

    private func setGlucoseUnit(_ unit: GlucoseUnit) {
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }
        guard profile.preferredGlucoseUnit != unit else { return }
        profile.preferredGlucoseUnit = unit
        // `updatedAt` is what the vitals cards watch to re-render in the new unit.
        profile.updatedAt = AppClock.now
        try? modelContext.save()
    }

    /// One-way import of age/sex/height/weight from Apple Health. This never writes to Health — the
    /// button only reads profile characteristics and drops them into the editor's `draft`, which the
    /// autosave `.onChange` above persists. Read authorization is invisible in HealthKit, so an empty
    /// result is reported as "nothing found / access may be off", never as an outright denial.
    @ViewBuilder private var appleHealthImport: some View {
        let available = HealthSyncService.shared.isAvailable
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(
                header: "Apple Health",
                footer: "Imports age, sex, height and weight. Nothing is written to Health from here."
            ) {
                FormField {
                    QuickActionButton(label: importing ? "Importing…" : "Import from Apple Health") {
                        importFromHealth()
                    }
                    .disabled(importing)
                    .opacity(importing ? 0.6 : 1)
                }
            }
            if let importStatus {
                Text(importStatus)
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textMuted)
                    .padding(.horizontal, 4)
            }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        // Assign the draft before flipping `loaded`, so the resulting onChange lands while
        // `loaded` is still false and autosave skips it (no write just from opening the screen).
        draft = ProfileDraft(profile: profiles.first)
        loaded = true
    }

    private func autosave() {
        guard loaded else { return }
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }
        draft.apply(to: profile)
        try? modelContext.save()
        coordinator.applyUserProfile()
        // Weight/height/age/sex shift every term of the daily calorie estimate.
        DailyCalorieEstimator.recomputeRecentDays(context: modelContext)
    }

    private func importFromHealth() {
        importing = true
        importStatus = nil
        Task {
            do {
                try await HealthSyncService.shared.requestProfileReadAuthorization()
            } catch {
                importing = false
                importStatus = "Couldn't reach Apple Health."
                return
            }
            let data = await HealthSyncService.shared.fetchUserProfileData()
            let imported = draft.importFromHealth(age: data.age, sex: data.sex,
                                                  heightCm: data.heightCm, weightKg: data.weightKg)
            importing = false
            importStatus = imported > 0
                ? "Imported \(imported) metric\(imported == 1 ? "" : "s")."
                : "No profile data found in Apple Health — it may be empty or access may be off."
        }
    }
}
