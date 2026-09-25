import SwiftUI
import SwiftData
import UIKit
import OSLog

struct RootAppView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LiveWorkoutManager.self) private var liveWorkout
    @Query private var profiles: [UserProfile]
    @State private var path = NavigationPath()
    @State private var didFinishForcedOnboarding = false
    /// The OS light/dark setting. Read here, above `.preferredColorScheme`: in System mode the override is
    /// nil, so this tracks the OS live; in Dark/Light mode it isn't consulted.
    @Environment(\.colorScheme) private var systemScheme
    @State private var appearance = AppearanceStore.shared
    @State private var themeStore = ThemeStore.shared
    /// The launch-argument tooling in `.task` runs once per process, not again when a theme change
    /// re-identifies the stack.
    private static var didRunLaunchTasks = false

    private var forceOnboardingForTesting: Bool {
        #if DEBUG
        DebugLaunch.bool("forceOnboarding")
        #else
        false
        #endif
    }

    @Namespace private var zoomNS
    /// Shown once when the store couldn't be opened and was moved aside at launch.
    @State private var storeNotice: String? = StoreRecoveryNotice.consume()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if (!forceOnboardingForTesting || didFinishForcedOnboarding),
                   profiles.first?.onboardingCompleted == true {
                    MainTabView(path: $path)
                } else {
                    OnboardingFlowView {
                        didFinishForcedOnboarding = true
                    }
                }
            }
            .background(PulseColors.background.ignoresSafeArea())
            .environment(\.zoomNamespace, zoomNS)
            // Demo data is opt-in: load it from Settings → "Reseed demo data", or via the
            // `-seedDemo YES` launch arg (test tooling only). Normal launches start empty.
            .task {
                if Self.didRunLaunchTasks {
                    liveWorkout.recover()
                    routeDeepLinkIfNeeded()
                    return
                }
                Self.didRunLaunchTasks = true
                if DebugLaunch.bool("seedDemo") {
                    SeedData.clearAll(modelContext)
                    SeedData.seedDemo(modelContext, completeOnboarding: true)
                }
                // Test tooling: `-demoEstimatedCalories YES` reshapes the seeded recent days into
                // what a phone-away ring-history sync produces (source `ring_history`, no device
                // calories) so the on-device estimated-total path is visible in the UI.
                if DebugLaunch.bool("demoEstimatedCalories") {
                    for offset in 0...2 {
                        guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()),
                              let row = MetricsRepository.activity(on: day, context: modelContext) else { continue }
                        row.source = ActivityService.ringHistorySource
                        DailyCalorieEstimator.recompute(day: day, context: modelContext)
                    }
                    try? modelContext.save()
                    PulseDataChange.shared.notify()
                }
                // Test tooling: fake a connected Strava account. Must run before anything touches
                // StravaAuthService.shared (it reads the token store at init).
                if DebugLaunch.bool("demoStravaConnected") {
                    StravaDemoState.apply()
                }
                #if DEBUG
                // Test tooling: headless full-archive export/import against
                // Documents/pulseloop-export.json, so the simulator smoke test can drive the
                // feature without the share sheet / file picker.
                let archiveLog = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "DataArchive")
                if UserDefaults.standard.bool(forKey: "exportDataToDocuments"),
                   let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let url = docs.appendingPathComponent("pulseloop-export.json")
                    do {
                        let data = try await DataArchiveService.exportArchive(context: modelContext)
                        try data.write(to: url, options: .atomic)
                        archiveLog.info("exported \(data.count) bytes to \(url.path)")
                    } catch {
                        archiveLog.error("export failed — \(error)")
                    }
                }
                if UserDefaults.standard.bool(forKey: "importDataFromDocuments"),
                   let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let url = docs.appendingPathComponent("pulseloop-export.json")
                    do {
                        let data = try Data(contentsOf: url)
                        try await DataArchiveService.importArchive(data, context: modelContext)
                        archiveLog.info("import from \(url.path) succeeded")
                    } catch {
                        archiveLog.error("import failed — \(error)")
                    }
                }
                #endif
                // Test tooling: flip the (off-by-default) nutrition feature on via launch arg.
                if DebugLaunch.bool("enableNutrition") {
                    NutritionPrefsStore.shared.prefs.masterEnabled = true
                    PulseDataChange.shared.notify()
                }
                if DebugLaunch.bool("openNutrition") {
                    path.append(AppRoute.nutrition)
                }
                // Test tooling: `-openAppearance YES` opens Settings › Appearance for screenshots.
                if DebugLaunch.bool("openAppearance") {
                    path.append(AppRoute.settingsAppearance)
                }
                // Test tooling: `-openGoals YES` opens Settings › Goals for screenshots.
                if DebugLaunch.bool("openGoals") {
                    path.append(AppRoute.settingsGoals)
                }
                if DebugLaunch.bool("openNutritionSettings") {
                    path.append(AppRoute.settingsNutrition)
                }
                // Test tooling: deep-link straight to a seeded workout's detail (route map).
                if DebugLaunch.bool("openWorkout"),
                   let session = ActivityRepository.sessions(context: modelContext).first(where: { $0.status == .finished && $0.useGps }) {
                    path.append(AppRoute.activityDetail(session.id))
                }
                if DebugLaunch.bool("openRecord") {
                    path.append(AppRoute.recordSelect)
                }
                // Test tooling: `-openMetric heartRate` opens a metric's detail chart for screenshots.
                if let raw = DebugLaunch.string("openMetric"),
                   let metric = MetricKind(rawValue: raw) {
                    path.append(AppRoute.metricDetail(metric))
                }
                // Re-attach to an in-progress workout left running across launches.
                liveWorkout.recover()
                routeDeepLinkIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    liveWorkout.recover()
                    routeDeepLinkIfNeeded()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "pulseloop", url.host == "workout",
                      let id = UUID(uuidString: url.lastPathComponent) else { return }
                liveWorkout.requestOpen(sessionID: id)
                routeDeepLinkIfNeeded()
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case let .activityDetail(id):
                    ActivityDetailView(sessionId: id)
                case let .metricDetail(metric):
                    MetricDetailView(metric: metric, path: $path)
                        .pulseZoomDestination(route, in: zoomNS)
                case .activityTrends:
                    ActivityTrendsView(path: $path)
                case .recordSelect:
                    RecordSelectView(path: $path)
                case .logPastActivity:
                    LogPastActivityView(path: $path)
                case let .recordLive(id):
                    RecordLiveView(sessionId: id, path: $path)
                case let .recordSummary(id):
                    RecordSummaryView(sessionId: id, path: $path)
                case .settings:
                    SettingsView(path: $path)
                case .settingsAppearance:
                    AppearanceSettingsView()
                case .settingsProfile:
                    ProfileSettingsView()
                case .settingsPhysiology:
                    PhysiologySettingsView()
                case .settingsNotifications:
                    NotificationsSettingsView()
                case .settingsCoach:
                    CoachSettingsDetailView()
                case .settingsWearable:
                    WearableSettingsView(path: $path)
                case .settingsMeasurement:
                    MeasurementSettingsView()
                case .settingsActivityTracking:
                    WorkoutSettingsView()
                case .settingsGoals:
                    GoalsSettingsView()
                case .settingsVitals:
                    VitalsSettingsView()
                case .settingsHeartRateZones:
                    HeartRateZoneSettingsView()
                case .settingsToday:
                    TodaySettingsView()
                case .settingsCalibration:
                    CalibrationSettingsView()
                case .settingsHealth:
                    AppleHealthSettingsView()
                case .settingsStrava:
                    StravaSettingsView()
                case .settingsCloud:
                    AgaraCloudSettingsView()
                case .settingsPrivacyData:
                    PrivacyDataSettingsView()
                case .settingsAbout:
                    AboutSettingsView(path: $path)
                case .settingsNutrition:
                    NutritionSettingsView()
                case .nutrition:
                    NutritionView(path: $path)
                case let .mealDetail(id):
                    MealDetailView(mealId: id, path: $path)
                case .pairing:
                    PairingView(onConnected: { path.removeLast() })
                case .debug:
                    DebugView()
                case .componentGallery:
                    ComponentGalleryView()
                }
            }
        }
        .alert("Data store reset", isPresented: Binding(
            get: { storeNotice != nil }, set: { if !$0 { storeNotice = nil } }
        )) {
            Button("OK", role: .cancel) { storeNotice = nil }
        } message: {
            Text(storeNotice ?? "")
        }
        // A theme change rebuilds the whole stack (the path survives — it lives in this view's state), so
        // colours captured outside a body (styles, cached values) are recomputed too.
        .id(themeStore.theme.name)
        // Ring firmware install progress, over everything while an install runs (debug + `firmwareInstall`).
        .firmwareInstallCover()
        .tint(PulseColors.accent)
        // System mode: no override, so the OS setting flows down (and into `systemScheme`). Otherwise the
        // chosen theme's side drives the status bar and system controls.
        .preferredColorScheme(colorSchemeOverride)
        .onChange(of: resolvedTheme.name, initial: true) { _, _ in
            // The XCTest host keeps the shipped `.dark`; tests select themes themselves.
            guard NSClassFromString("XCTestCase") == nil else { return }
            ThemeStore.current = resolvedTheme
        }
    }

    private var resolvedTheme: AgaraTheme {
        appearance.resolvedTheme(systemIsDark: systemScheme == .dark, sex: profiles.first?.sex)
    }

    private var colorSchemeOverride: ColorScheme? {
        if appearance.mode == .system && appearance.debugThemeOverride == nil { return nil }
        return resolvedTheme.isLight ? .light : .dark
    }

    /// Navigate to a workout requested by a Live Activity tap / Lock Screen control.
    private func routeDeepLinkIfNeeded() {
        guard let id = liveWorkout.pendingDeepLinkSession else { return }
        liveWorkout.clearDeepLink()
        guard let session = ActivityRepository.sessions(context: modelContext).first(where: { $0.id == id }) else { return }
        let route: AppRoute = session.status == .finished ? .recordSummary(id) : .recordLive(id)
        path.append(route)
    }
}

struct MainTabView: View {
    @Binding var path: NavigationPath
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @State private var selected: MainTab
    @State private var nav = CoachNavigation.shared
    @State private var coachStore = CoachSettingsStore.shared
    /// Card-reorder edit mode, entered inside a tab but chromed here: the Done bar floats above the
    /// tab bar and the coach FAB has to step aside.
    @State private var reorder = CardReorderSession.shared
    /// Route requested from inside the Coach sheet, pushed once the sheet dismisses.
    @State private var pendingCoachRoute: AppRoute?

    /// The tab in use, kept across a theme change (which rebuilds this view) for the rest of the session.
    private static var sessionTab: MainTab?

    init(path: Binding<NavigationPath>) {
        self._path = path
        // Optional `-startTab vitals` launch arg (parsed into UserDefaults) for screenshot tooling.
        let raw = DebugLaunch.string("startTab")
        let requested = MainTab.allCases.first { $0.rawValue.lowercased() == raw } ?? .today
        // Coach is no longer a tab (it opens as a sheet), so `-startTab coach`
        // just lands on Today.
        _selected = State(initialValue: Self.sessionTab ?? (requested == .coach ? .today : requested))
    }

    private var coachEnabled: Bool { coachStore.settings.coachMasterEnabled }
    private var visibleTabs: [MainTab] {
        // Coach is intentionally NOT a tab — it opens as a sheet. Keeping it a tab
        // pushed the count to 6 and iOS collapsed everything into a "More" tab.
        MainTab.allCases.filter { $0 != .coach }
    }

    /// The screen for a given tab. Shared by the iOS 26 stock `Tab` bar and the
    /// iOS 18–25 paged fallback so content wiring stays in one place.
    @ViewBuilder
    private func tabDestination(_ tab: MainTab) -> some View {
        switch tab {
        case .today:    TodayView(path: $path, selectedTab: $selected, isActive: selected == .today)
        case .vitals:   VitalsView(path: $path, isActive: selected == .vitals)
        case .activity: ActivityView(path: $path)
        case .sleep:    SleepView()
        case .coach:    CoachView()
        case .settings: SettingsView(path: $path)
        }
    }

    /// A card tapped inside the chat can't push onto `path` directly: the sheet
    /// sits outside this NavigationStack, so the detail would slide in behind it. Park
    /// the route and dismiss; `pushPendingCoachRoute` runs once the sheet is gone.
    private func requestCoachRoute(_ route: AppRoute) {
        pendingCoachRoute = route
        nav.showCoach = false
    }

    private func pushPendingCoachRoute() {
        guard let route = pendingCoachRoute else { return }
        pendingCoachRoute = nil
        path.append(route)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(path: $path)
            // Thin sync-progress accent directly under the greeting; only present while the ring
            // is actively syncing. The always-present container lets iOS 26 materialize the
            // bar (glass light-bending in/out) instead of a hard opacity cut.
            Group {
                if coordinator.isSyncing {
                    SyncProgressBar()
                        .pulseMaterialize()
                }
            }
            .pulseGlassContainer(spacing: 8)
            if let error = coordinator.syncError {
                HStack {
                    Text(error).font(PulseFont.caption)
                    Spacer()
                    Button("Retry") { coordinator.runStartupSequence() }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
            }
            if #available(iOS 26, *) {
                // iOS 26+: native TabView renders Apple's stock Liquid Glass tab bar —
                // real lensing, morphing selection, and content diffusing under the bar.
                // Swipe-between-tabs is intentionally dropped (the stock bar can't swipe).
                TabView(selection: $selected) {
                    ForEach(visibleTabs) { tab in
                        Tab(tab.rawValue, systemImage: tab.symbol, value: tab) {
                            tabDestination(tab)
                        }
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .onChange(of: selected) { _, _ in UIApplication.shared.endEditing() }
            } else {
                // iOS 18–25: no stock Liquid Glass, so keep the paged swipe + custom bar.
                ZStack(alignment: .bottom) {
                    TabView(selection: $selected) {
                        ForEach(visibleTabs) { tab in
                            tabDestination(tab).tag(tab)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    BottomNavBar(selected: $selected, tabs: visibleTabs)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .onChange(of: selected) { _, _ in UIApplication.shared.endEditing() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.isSyncing)
        .animation(PulseMotion.materialize, value: coachEnabled)   // FAB materializes in/out
        .animation(PulseMotion.materialize, value: reorder.isEditing)
        // Floating Coach chat bubble, bottom-right, hovering above the tab bar. It steps aside while
        // reordering: the cards are disabled then anyway, and the Done bar wants the full width.
        .overlay(alignment: .bottomTrailing) {
            if coachEnabled && !reorder.isEditing {
                CoachFAB { CoachNavigation.shared.openRoot() }
                    .padding(.trailing, 18)
                    .padding(.bottom, PulseLayout.floatingBottomInset)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Reorder chrome lives here, not in the tab: only at this level can it clear the tab bar (which
        // is Apple's own on iOS 26) and coexist with the FAB.
        .overlay(alignment: .bottom) {
            if reorder.isEditing {
                ReorderDoneBar { reorder.end() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, PulseLayout.floatingBottomInset)
            }
        }
        // Leaving the tab abandons its edit mode; the tab's own observer persists the order.
        .onChange(of: selected) { _, tab in reorder.end(); Self.sessionTab = tab }
        .onChange(of: coachEnabled) { _, enabled in
            // Coach turned off — dismiss the sheet and clear any pending deep link.
            if !enabled { nav.requestedConversationId = nil; nav.showCoach = false }
        }
        // Coach opens as a sheet (swipe-to-dismiss) instead of a tab, so it never
        // crowds the tab bar. All entry points set `nav.showCoach`.
        .sheet(isPresented: $nav.showCoach, onDismiss: pushPendingCoachRoute) {
            CoachView(
                onOpenWorkout: { requestCoachRoute(.activityDetail($0)) },
                onOpenMeal: { requestCoachRoute(.mealDetail($0)) }
            )
                .presentationDragIndicator(.visible) // grabber ("pull tab") at the top of the sheet
                // CoachView reads the coordinator; pass it explicitly (see the note on VitalsView's sheet —
                // a sheet presented on the iPad/Mac idiom can lose the WindowGroup's environment objects).
                .environment(coordinator)
        }
        .background(PulseColors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Fixed top header mirroring the web app's `TopStatusBar`: small uppercase brand over a
/// time-based greeting on the left; a connection-status pill plus quick nav icons on the right.
struct AppHeader: View {
    @Binding var path: NavigationPath
    @Environment(RingBLEClient.self) private var ble
    @Query private var devices: [Device]
    @Query private var profiles: [UserProfile]

    /// Profile's first name (text before the first space), or nil when no name is set.
    private var firstName: String? {
        guard let full = profiles.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !full.isEmpty else { return nil }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    /// A rotating, time-of-day greeting. Each variant is a `lead` phrase plus a `suffix`
    /// (usually "" or "?") so it composes both with a name — "\(lead), \(name)\(suffix)" — and
    /// without — "\(lead)\(suffix)". The pick advances every 2 hours (and differs day to day),
    /// so it stays stable within each 2-hour block — no flicker as the view re-renders.
    private var greeting: (lead: String, suffix: String) {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let day = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        // 12 two-hour blocks per day; a global block index rotates the variant every 2 hours.
        let block = day * 12 + hour / 2
        let variants = Self.greetingVariants(hour: hour)
        return variants[block % variants.count]
    }

    private static func greetingVariants(hour: Int) -> [(lead: String, suffix: String)] {
        switch hour {
        case 5..<12: // Morning
            return [
                ("Good morning", ""),
                ("Rise and shine", ""),
                ("Ready for a run", "?"),
                ("Ready to seize the day", "?"),
                ("Fresh start", "")
            ]
        case 12..<17: // Afternoon
            return [
                ("Good afternoon", ""),
                ("Keeping the momentum", "?"),
                ("Staying on track", "?"),
                ("How's the day treating you", "?"),
                ("Powering through", "?")
            ]
        case 17..<22: // Evening
            return [
                ("Good evening", ""),
                ("How was your day", "?"),
                ("Time to unwind", ""),
                ("Winding down", "?"),
                ("Evening, champ", "")
            ]
        default: // Night (22–5)
            return [
                ("Good night", ""),
                ("Time to wind down", ""),
                ("Ready to rest", "?"),
                ("Rest well", ""),
                ("Burning the midnight oil", "?")
            ]
        }
    }

    var body: some View {
        let greeting = self.greeting
        // The brand lockup sits centred above the row, so it reads as the app's masthead and the
        // greeting/status below stay aligned with the rest of the screen's leading edge.
        VStack(spacing: 6) {
            // White type on dark themes, dark type on light ones (the orange A is the same).
            Image(ThemeStore.current.isLight ? "agara-wordmark-dark" : "agara-wordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 11)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let firstName {
                    // Two lines: greeting on top, name below — avoids truncating a long name.
                    Text("\(greeting.lead),")
                        .font(PulseFont.footnote)
                        .foregroundStyle(PulseColors.textMuted)
                    Text("\(firstName)\(greeting.suffix)")
                        .font(PulseFont.title2.weight(.semibold))
                        .foregroundStyle(PulseColors.textPrimary)
                        .lineLimit(1)
                } else {
                    Text("\(greeting.lead)\(greeting.suffix)")
                        .font(PulseFont.title3)
                        .foregroundStyle(PulseColors.textPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // Clean top bar: just the live connection status. Settings is in the tab
            // bar; Coach is the floating bubble above the tab bar.
            // Tap the ring chip → Wearable settings (add-a-ring / status).
            RingStatusChip(state: effectiveState, batteryPercent: effectiveBattery,
                           isCharging: AgaraFeatureStore.shared.isOn(.chargingState) && ble.isCharging,
                           chargeEstimate: ble.chargeEstimate,
                           ringName: devices.first?.displayName) {
                path.append(AppRoute.settingsWearable)
            }
            .coachMark(CoachMarkStore.ringChip, text: AgaraHelp.hintRingChip)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(PulseColors.background)
        }
    }

    /// Prefer live BLE state; otherwise fall back to the stored device so demo
    /// data shows "Connected · 82%" instead of a permanently disconnected ring.
    private var liveActive: Bool {
        [.connected, .connecting, .reconnecting, .scanning].contains(ble.state)
    }
    private var effectiveState: RingConnectionState {
        liveActive ? ble.state : (devices.first?.state ?? ble.state)
    }
    private var effectiveBattery: Int? {
        ble.batteryPercent ?? devices.first?.batteryPercent
    }
}

/// The ring's status in the header, as one compact chip: a ring glyph inside a battery arc (filled to the
/// level, in the battery tier colour) with a status dot on its corner. No words while connected; a label
/// only when something needs attention. Replaces the "● Connected 🔋20%" pill, which crowded the greeting.
/// Last-known battery stays, dimmed, while disconnected. Mirrors Android `RingStatusChip`.
struct RingStatusChip: View {
    let state: RingConnectionState
    let batteryPercent: Int?
    /// On the charger: the arc sweeps up to full in a loop and a bolt replaces the status dot.
    var isCharging: Bool = false
    /// Time to full while charging ("full in about 50 minutes" in the spoken label).
    var chargeEstimate: ChargeEstimator.Estimate? = nil
    /// The ring's name (nickname, else model name) spoken by VoiceOver; nil → "Ring".
    var ringName: String? = nil
    var action: () -> Void = {}
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if status != .connected {
                    Text(status.label)
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                        .fixedSize()
                }
                RingBatteryGlyph(
                    percent: battery,
                    live: status == .connected,
                    dotColor: status.color,
                    dotOpacity: status == .connecting && pulse ? 0.35 : 1,
                    charging: charging
                )
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(
            ringName: ringName, statusLabel: status.label, battery: battery, charging: charging,
            chargeEstimate: chargeEstimate
        ))
        .accessibilityHint(AgaraHelp.ringChip)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("ringChip")
        .help(AgaraHelp.ringChip)
        .onAppear { startPulse(status == .connecting) }
        // The chip stays mounted across state changes, so `onAppear` alone would miss a later
        // idle → connecting flip — and would leave the repeatForever loop running after connect.
        .onChange(of: status == .connecting) { _, now in startPulse(now) }
    }

    /// "<name> connected, battery 80 percent" / "<name> charging, …". Pure so it is unit-testable.
    static func accessibilityLabel(ringName: String?, statusLabel: String, battery: Int?, charging: Bool,
                                   chargeEstimate: ChargeEstimator.Estimate? = nil) -> String {
        let name = ringName.flatMap { RingNickname.normalized($0) } ?? "Ring"
        let batteryPart = battery.map { ", battery \($0) percent" } ?? ""
        let estimatePart = chargeEstimate?.spokenText.map { ", \($0)" } ?? ""
        return charging
            ? "\(name) charging" + batteryPart + estimatePart
            : "\(name) \(statusLabel.lowercased())" + batteryPart
    }

    private var battery: Int? { batteryPercent.flatMap { $0 > 0 ? min($0, 100) : nil } }
    private var status: RingChipStatus { RingChipStatus(state) }
    /// Charging only means something while the link is up.
    private var charging: Bool { isCharging && status == .connected }

    /// Restart or cancel the dot pulse. The non-animated reset replaces the old repeatForever
    /// transaction; without it the loop keeps animating the header for the app's whole lifetime.
    private func startPulse(_ on: Bool) {
        pulse = false
        guard on else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// What the header chip says about the connection. Same cases and labels as Android `RingChipStatus`.
enum RingChipStatus: Equatable {
    case connected, connecting, failed, disconnected

    init(_ state: RingConnectionState) {
        switch state {
        case .connected: self = .connected
        case .connecting, .reconnecting: self = .connecting
        case .failed: self = .failed
        // No ring linked: the background auto-reconnect scan reads as "Disconnected", not an
        // in-progress action (active pairing has its own UI in PairingView).
        case .scanning, .idle, .disconnected: self = .disconnected
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Sync failed"
        case .disconnected: return "Disconnected"
        }
    }

    var color: Color {
        switch self {
        case .connected: return PulseColors.success
        case .connecting: return PulseColors.accent
        case .failed, .disconnected: return PulseColors.danger
        }
    }
}

/// A ring drawn inside a battery arc: from 12 o'clock clockwise to `percent` in the tier colour over a faint
/// track, with the status dot on the lower-right corner. `percent` nil = unknown (track only). Dimmed when
/// not `live`. Same geometry as Android `RingBatteryGlyph`; also used on the Settings ring card.
struct RingBatteryGlyph: View {
    let percent: Int?
    var live: Bool = true
    var dotColor: Color?
    var dotOpacity: Double = 1
    var size: CGFloat = 38
    /// On the charger: the arc sweeps from the current level to full in a ~1.6 s ease-in-out loop and a
    /// small bolt replaces the status dot. Reduce Motion: a static full arc (full tier colour) + the bolt.
    var charging: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One sweep, level → full, then it starts again.
    static let chargeCycle: TimeInterval = 1.6

    /// The arc fill (0…1) at `time` while charging: eased from `level` up to full over one cycle.
    static func chargingFill(level: Double, time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: chargeCycle) / chargeCycle
        let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2   // ease-in-out
        return level + (1 - level) * eased
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if charging && !reduceMotion {
                TimelineView(.animation) { context in
                    let level = Double(percent ?? 0) / 100
                    glyph(fill: Self.chargingFill(level: level, time: context.date.timeIntervalSinceReferenceDate),
                          tier: PulseColors.success)
                }
            } else if charging {
                glyph(fill: 1, tier: PulseColors.success)
            } else {
                glyph(fill: percent.map { Double($0) / 100 }, tier: percent.map { BatteryTier(percent: $0).color })
            }
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(PulseColors.onAccent)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .background(PulseColors.success, in: Circle())
                    .overlay(Circle().stroke(PulseColors.background, lineWidth: 1.5))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: percent)
    }

    /// The glyph itself; `fill` nil = unknown level (track only).
    private func glyph(fill: Double?, tier: Color?) -> some View {
        let tierColor = tier ?? PulseColors.textMuted
        let showsDot = !charging
        return Canvas { context, canvasSize in
            let w = canvasSize.width
            let arcStroke = w * 0.08
            let diameter = w * 0.84
            let arcRect = CGRect(x: (w - diameter) / 2 + arcStroke / 2, y: (w - diameter) / 2 + arcStroke / 2,
                                 width: diameter - arcStroke, height: diameter - arcStroke)
            let disc = CGRect(x: (w - diameter) / 2, y: (w - diameter) / 2, width: diameter, height: diameter)
            context.fill(Path(ellipseIn: disc), with: .color(PulseColors.card))
            context.stroke(Path(ellipseIn: arcRect), with: .color(PulseColors.borderStrong), lineWidth: arcStroke)
            if let fill {
                var arc = Path()
                arc.addArc(center: CGPoint(x: arcRect.midX, y: arcRect.midY), radius: arcRect.width / 2,
                           startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * max(fill, 0.02)), clockwise: false)
                context.stroke(arc, with: .color(tierColor.opacity(live ? 1 : 0.45)),
                               style: StrokeStyle(lineWidth: arcStroke, lineCap: .round))
            }
            // The ring: a band with a small gem on top.
            let ink = PulseColors.textPrimary.opacity(live ? 1 : 0.6)
            let band = w * 0.15
            let bandStroke = w * 0.065
            let c = CGPoint(x: w / 2, y: w / 2 + w * 0.03)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - band, y: c.y - band, width: band * 2, height: band * 2)),
                           with: .color(ink), lineWidth: bandStroke)
            let gem = w * 0.075
            let top = CGPoint(x: c.x, y: c.y - band - bandStroke * 0.2)
            var diamond = Path()
            diamond.move(to: CGPoint(x: top.x, y: top.y - gem))
            diamond.addLine(to: CGPoint(x: top.x + gem, y: top.y))
            diamond.addLine(to: CGPoint(x: top.x, y: top.y + gem * 0.8))
            diamond.addLine(to: CGPoint(x: top.x - gem, y: top.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(ink))
            if showsDot, let dotColor {
                let r = w * 0.12
                let dc = CGPoint(x: w - r - 0.5, y: w - r - 0.5)
                context.fill(Path(ellipseIn: CGRect(x: dc.x - r - 1.5, y: dc.y - r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2)),
                             with: .color(PulseColors.background))
                context.fill(Path(ellipseIn: CGRect(x: dc.x - r, y: dc.y - r, width: r * 2, height: r * 2)),
                             with: .color(dotColor.opacity(dotOpacity)))
            }
        }
    }
}

/// Battery colour bands, from the shared catalog (`ring_battery_*_percent`); Android `BatteryTier`.
enum BatteryTier: Equatable {
    case low, mid, ok

    init(percent: Int) {
        if percent <= AgaraConfig.Ring.batteryLowPercent { self = .low }
        else if percent <= AgaraConfig.Ring.batteryOkPercent { self = .mid }
        else { self = .ok }
    }

    var color: Color {
        switch self {
        case .low: return PulseColors.danger
        case .mid: return PulseColors.warning
        case .ok: return PulseColors.success
        }
    }
}

/// Time-of-day greeting, mirroring the web app's `greetingForHour()`.
func greetingForHour(_ date: Date = Date()) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: return "Good morning"
    case 12..<17: return "Good afternoon"
    case 17..<22: return "Good evening"
    default: return "Good night"
    }
}

/// Floating Coach chat bubble — a circular tinted-glass button that hovers above
/// the tab bar (bottom-right) and opens the Coach chat sheet. Real Liquid Glass on
/// iOS 26+, solid accent fallback on older systems / Reduce Transparency.
struct CoachFAB: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(PulseFont.title2)
                .foregroundStyle(PulseColors.accent)
                .frame(width: 56, height: 56)
                .modifier(CoachFABGlass())
                // Consume every touch inside the circle so taps never fall through
                // to the content scrolling underneath the bubble.
                .contentShape(Circle())
        }
        .buttonStyle(FABPressStyle())
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .accessibilityLabel("Open Coach chat")
    }
}

/// Press-in spring for the FAB. A ButtonStyle (not a gesture) so it never leaks
/// the touch to the view below.
private struct FABPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Frosted Liquid Glass bubble (no solid fill) so the icon reads as glass. Real
/// glass on iOS 26+, Material fallback otherwise / under Reduce Transparency.
private struct CoachFABGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }
}

struct BottomNavBar: View {
    @Binding var selected: MainTab
    var tabs: [MainTab] = MainTab.allCases
    // Drives the sliding selection lozenge that morphs between tabs.
    @Namespace private var tabSelection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = selected == tab
                Button {
                    // Switch the page instantly (no scroll-through of intermediate
                    // pages, so rapid taps land reliably). The lozenge still animates
                    // via the `.animation(value:)` below; manual swipe is unaffected.
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) { selected = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(PulseFont.headline)
                            .frame(width: 38, height: 28)
                            .background {
                                // The active lozenge slides between tabs instead of
                                // hard-cutting — matchedGeometryEffect works on every OS.
                                if isSelected {
                                    Capsule()
                                        .fill(PulseColors.accentSoft)
                                        .matchedGeometryEffect(id: "tabLozenge", in: tabSelection)
                                }
                            }
                        Text(tab.rawValue)
                            .font(PulseFont.micro)
                    }
                    .foregroundStyle(isSelected ? PulseColors.textPrimary : PulseColors.textMuted)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        // Slide the selection lozenge smoothly whenever the tab changes.
        .animation(PulseMotion.spring, value: selected)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // Single interactive glass surface — real Liquid Glass (touch illumination)
        // on iOS 26+, Material fallback below.
        .pulseGlass(Capsule(), interactive: true)
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
        // Consume every touch inside the capsule so taps never fall through to the
        // scrolling content beneath the floating bar.
        .contentShape(Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}

struct OnboardingHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(PulseFont.numberHero)
                .foregroundStyle(PulseColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(PulseFont.callout.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }
}

// MARK: - Shared small views

struct SectionHeader: View {
    let title: String
    let action: String?
    var body: some View {
        HStack {
            Text(title)
                .font(PulseFont.footnote.weight(.semibold))
                .foregroundStyle(PulseColors.textSecondary)
                .textCase(.uppercase)
            Spacer()
            if let action {
                Text(action)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.accent)
            }
        }
    }
}

struct StatusCopy: View {
    let title: String
    let text: String

    init(title: String, body: String) {
        self.title = title
        self.text = body
    }

    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(PulseFont.headline)
                Text(text)
                    .font(PulseFont.subheadline.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    init(title: String, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(PulseFont.largeTitle)
                .foregroundStyle(PulseColors.textMuted)
            Text(title)
                .font(PulseFont.headline)
            Text(message)
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

/// Compact inline empty state for charts/cards (web's `EmptyState` used inside cards).
struct InlineEmptyState: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(PulseFont.subheadline).foregroundStyle(PulseColors.textPrimary)
            Text(message).font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
