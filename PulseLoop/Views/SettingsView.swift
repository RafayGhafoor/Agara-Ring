import SwiftUI
import SwiftData

/// Top-level Settings: a hero ring-device card over five inset-grouped sections. Each row pushes a
/// focused detail screen via `AppRoute`; detail screens live under `Views/Settings/`.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @State private var coachStore = CoachSettingsStore.shared
    /// Shared feature flags: every iOS-only surface hides while its parity flag is off (phase 6).
    @State private var features = AgaraFeatureStore.shared
    @Query private var devices: [Device]
    @Query private var profiles: [UserProfile]
    /// Unlocked by tapping the version 7× in About; shows the Developer row.
    @AppStorage("developerUnlocked") private var developerUnlocked = false
    @Binding var path: NavigationPath

    /// Capabilities of the live device (preferred) or the last stored device, used to decide whether
    /// device-specific rows appear.
    private var capabilities: Set<WearableCapability> {
        MetricsService.activeCapabilities(context: modelContext, ble: ble)
    }

    /// Provider-aware AI Coach summary. Local modes identify where inference runs; hosted
    /// providers show the selected model so stale settings cannot mislabel them as "Balanced".
    private var coachTrailing: String {
        guard coachStore.settings.coachMasterEnabled else { return "Off" }
        let settings = coachStore.settings
        switch settings.providerMode {
        case .offlineStub:
            return "Offline"
        case .appleOnDevice:
            return "Apple on-device"
        case .userOpenAIKey:
            return CoachModel(rawValue: settings.model)?.label ?? settings.model
        case .userGeminiKey:
            return GeminiModel(rawValue: settings.model)?.label ?? settings.model
        case .userOpenRouterKey:
            return OpenRouterModel(rawValue: settings.model)?.label ?? settings.openRouterModel
        case .userMiniMaxKey:
            return MiniMaxModel(rawValue: settings.model)?.label ?? settings.minimaxModel
        case .localOpenAICompat:
            // The model name is whatever the user's own server calls it, so there's no preset to
            // map. Blank is legitimate (llama.cpp ignores the field), hence the fallback.
            return settings.resolvedLocalModel.isEmpty ? "Self-hosted" : settings.resolvedLocalModel
        case .backendProxy:
            return "Backend proxy"
        }
    }

    /// "Ember · System".
    private var appearanceTrailing: String {
        let store = AppearanceStore.shared
        let flavour = AppearanceFlavour.named(store.flavour(sex: profiles.first?.sex))?.name ?? ""
        return [flavour, store.mode.label].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var notificationsTrailing: String {
        coachStore.settings.notificationsEnabled ? "On" : "Off"
    }

    var body: some View {
        let caps = capabilities // evaluate once (one device fetch) and share across sections
        ScrollView {
            VStack(spacing: 20) {
                DeviceHeroCard(path: $path)

                // Grouped glass sections share one container so their glass renders/
                // blends consistently (iOS-Settings inset-grouped look).
                VStack(spacing: 20) {
                    SettingsSection(title: "General", rows: generalRows(caps))
                    SettingsSection(title: "Metrics", rows: metricsRows)
                    SettingsSection(title: "Resources", rows: resourcesRows(caps))
                }
                .agaraGlassContainer(spacing: 20)
            }
            .padding()
        }
        .background(AgaraColors.background)
        .agaraScrollEdges(.top) // content frosts/dissolves under the top as it scrolls
        .navigationTitle("Settings")
    }

    // MARK: - Rows

    /// Auto-measure is offered when the flag is on and the ring reported a schedule (or says it has one).
    private var showsAutoMeasure: Bool {
        guard features.isOn(.autoMeasureSettings), let device = devices.first else { return false }
        return !device.autoMeasureSchedule.isEmpty || device.ringCapabilities?.autoMeasure == true
    }

    /// User setup: profile (with the glucose unit), physiology (flag), appearance, the ring's auto-measure
    /// schedule, then the AI Coach and its check-ins (flag `coach`).
    private func generalRows(_ caps: Set<WearableCapability>) -> [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            SettingsRowItem(icon: "person.crop.circle", tint: AgaraColors.accent, title: "User Profile") {
                path.append(AppRoute.settingsProfile)
            }
        ]
        if features.isOn(.physiology) {
            rows.append(SettingsRowItem(icon: "lungs", tint: AgaraColors.hrv, title: "Physiology") {
                path.append(AppRoute.settingsPhysiology)
            })
        }
        rows.append(SettingsRowItem(icon: "paintpalette", tint: AgaraColors.accent, title: "Appearance",
                                    trailingValue: appearanceTrailing) {
            path.append(AppRoute.settingsAppearance)
        })
        // The ring's own `b3` schedule — replaces the old "Measurement Frequency" row, which the Agara ring
        // never qualified for.
        if showsAutoMeasure {
            rows.append(SettingsRowItem(icon: "timer", tint: AgaraColors.spo2, title: "Auto-measure") {
                path.append(AppRoute.settingsAutoMeasure)
            })
        }
        if features.isOn(.coach) {
            rows.append(SettingsRowItem(icon: "sparkles", tint: AgaraColors.accent, title: "AI Coach", trailingValue: coachTrailing) {
                path.append(AppRoute.settingsCoach)
            })
            // Check-ins are a coach sub-feature — only show the row once the coach is on.
            if coachStore.settings.coachMasterEnabled {
                rows.append(SettingsRowItem(icon: "bell.badge", tint: AgaraColors.warning, title: "Coach Check-Ins", trailingValue: notificationsTrailing) {
                    path.append(AppRoute.settingsNotifications)
                })
            }
        }
        return rows
    }

    private var metricsRows: [SettingsRowItem] {
        var rows: [SettingsRowItem] = [
            SettingsRowItem(icon: "circle.circle", tint: AgaraColors.accent, title: "Today") {
                path.append(AppRoute.settingsToday)
            },
            SettingsRowItem(icon: "heart.text.square", tint: AgaraColors.heartRate, title: "Vitals") {
                path.append(AppRoute.settingsVitals)
            }
        ]
        if features.isOn(.hrZonesEditor) {
            rows.append(SettingsRowItem(icon: "waveform.path.ecg", tint: AgaraColors.heartRate, title: "Heart Rate Zones") {
                path.append(AppRoute.settingsHeartRateZones)
            })
        }
        if features.isOn(.activityTrackingSettings) {
            rows.append(SettingsRowItem(icon: "figure.run", tint: AgaraColors.success, title: "Activity Tracking") {
                path.append(AppRoute.settingsActivityTracking)
            })
        }
        rows.append(SettingsRowItem(icon: "target", tint: AgaraColors.readiness, title: "Goals") {
            path.append(AppRoute.settingsGoals)
        })
        // Nutrition: flag `nutrition`, then its own master toggle inside.
        if features.isOn(.nutrition) {
            rows.append(SettingsRowItem(
                icon: "fork.knife", tint: AgaraColors.calories, title: "Nutrition",
                trailingValue: NutritionPrefsStore.shared.prefs.masterEnabled ? "On" : "Off"
            ) {
                path.append(AppRoute.settingsNutrition)
            })
        }
        return rows
    }

    private func resourcesRows(_ caps: Set<WearableCapability>) -> [SettingsRowItem] {
        var rows: [SettingsRowItem] = []
        // the ring-only: only the 56ff the ring measures BP / blood sugar, so Calibration hides otherwise.
        if (caps.contains(.bloodPressure) && AgaraFeatureStore.isOn(.vitalsBp))
            || (caps.contains(.bloodSugar) && AgaraFeatureStore.isOn(.vitalsGlucose)) {
            rows.append(SettingsRowItem(icon: "slider.horizontal.3", tint: AgaraColors.bloodPressure, title: "Calibration") {
                path.append(AppRoute.settingsCalibration)
            })
        }
        // Hidden until unlocked by tapping the version 7× in About (like Android's developer options).
        // Debug builds only: a release build has no hidden menu (store launch, App Store 2.3.1(a)).
        #if DEBUG
        if developerUnlocked, StoreCapture.showsDebugChrome {
            rows.append(SettingsRowItem(icon: "ladybug", tint: AgaraColors.danger, title: "Developer") {
                path.append(AppRoute.debug)
            })
        }
        #endif
        rows.append(SettingsRowItem(icon: "heart.fill", tint: AgaraColors.heartRate, title: "Apple Health") {
            path.append(AppRoute.settingsHealth)
        })
        if features.isOn(.strava) {
            rows.append(SettingsRowItem(icon: "figure.run", tint: Color(hex: "#FC4C02"), title: "Strava") {
                path.append(AppRoute.settingsStrava)
            })
        }
        // Agara cloud account: login + health-data sync to the PocketBase backend (flag `agara_cloud`).
        if features.isOn(.agaraCloud) {
            rows.append(SettingsRowItem(icon: "icloud.fill", tint: AgaraColors.hrv, title: "Agara Cloud") {
                path.append(AppRoute.settingsCloud)
            })
        }
        // Export/import, diagnostics and demo data (phase 5); Privacy keeps the privacy statement and resets.
        rows.append(SettingsRowItem(icon: "square.and.arrow.up.on.square", tint: AgaraColors.accent, title: "Data & Export") {
            path.append(AppRoute.settingsDataExport)
        })
        rows.append(SettingsRowItem(icon: "lock.shield", tint: AgaraColors.success, title: "Privacy") {
            path.append(AppRoute.settingsPrivacyData)
        })
        rows.append(SettingsRowItem(icon: "info.circle", tint: AgaraColors.textMuted, title: "About \(AgaraCopy.aboutProductName)") {
            path.append(AppRoute.settingsAbout)
        })
        return rows
    }
}
