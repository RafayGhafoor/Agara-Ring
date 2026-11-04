//
//  AgaraApp.swift
//  Agara Ring
//
//  Created by Saksham Bhutani on 5/31/26.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct AgaraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer
    @State private var bleClient: RingBLEClient
    @State private var coordinator: RingSyncCoordinator
    @State private var gpsRecorder: GpsRouteRecorder
    @State private var liveWorkout: LiveWorkoutManager
    /// Retained for app lifetime so it keeps draining the event bus into SwiftData.
    private let persistence: EventPersistenceSubscriber
    /// Retained so it keeps regenerating Today/Sleep coach summaries on new data.
    private let summaryCoordinator: CoachSummaryCoordinator
    /// Retained so it keeps watching for on-device proactive anomaly alerts.
    private let anomalyMonitor: CoachAnomalyMonitor
    /// Retained so it keeps watching the ring's battery for low/critical alerts.
    private let batteryAlertMonitor = BatteryAlertMonitor()
    /// Retained so it keeps recording the structured wearable diagnostics timeline.
    private let diagnostics: DiagnosticsSubscriber
    /// Retained so it keeps projecting synced data into the home-screen-widget snapshot.
    private let widgetPublisher: WidgetSnapshotPublisher
    /// Retained so it keeps exporting newly-synced ring data into Apple Health.
    private let healthSyncPublisher: HealthSyncPublisher
    /// Retained so it keeps pushing newly-finished workouts to Strava (automatic mode).
    private let stravaSyncPublisher: StravaSyncPublisher
    /// Retained so the UNUserNotificationCenter delegate stays alive.
    private let notificationDelegate = CoachNotificationDelegate()
    /// Retained so a completed background sync can fire the due check-in on fresh data.
    private let notificationDataTrigger: CoachNotificationDataTrigger

    /// True when the app host is launched by the XCTest runner. Unit tests build their own
    /// in-memory stores and never touch the live BLE/notification stack, so the app host must
    /// not spin those up: on the headless CI simulator CoreBluetooth's XPC service and the
    /// on-disk SwiftData store are unavailable, and starting them hangs/crashes the test host.
    private static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    init() {
        // Store-screenshot tooling (`-fixedNow <ISO>`, `-storeCapture YES`): debug builds only, and applied before
        // anything reads the clock or builds a view, so the first frame is already right. No-ops in Release.
        AppClock.applyLaunchArguments()
        StoreCapture.applyLaunchArguments()
        // Manrope ships as data assets; register it before the first view resolves a `Font.custom`.
        // The user's week start (unset = the device locale) — before the first chart, review or settings row.
        WeekStartPrefs.installFromDefaults()
        AgaraFontRegistry.registerBundledFonts()
        AgaraUIKitFonts.apply()
        let runningTests = Self.isRunningUnitTests
        #if DEBUG
        // `-theme <name>` pins a catalog theme (docs/config/palette.yaml) over the Appearance choice —
        // for screenshots. Applied before any view is built.
        AppearanceStore.shared.debugThemeOverride = UserDefaults.standard.string(forKey: "theme")
        ThemeStore.select(UserDefaults.standard.string(forKey: "theme"))
        // `-features "a=on,b=off"` overrides feature flags (docs/config/features.yaml); persisted like the
        // Settings › Developer › Feature flags toggles.
        AgaraFeatureStore.shared.applyLaunchOverrides(UserDefaults.standard.string(forKey: AgaraFeatureStore.launchArgumentKey))
        #endif

        let container: ModelContainer
        if runningTests {
            // Under tests, use an isolated in-memory store instead of the on-disk `default.store`
            // (which fails to create in the sandboxed CI simulator).
            // swiftlint:disable:next force_try
            container = try! ModelContainerFactory.make(inMemory: true)
        } else {
            // A store that can't be opened is moved aside and replaced (with a one-time notice) rather
            // than a `fatalError` that would crash every launch until the app is deleted.
            container = ModelContainerFactory.makeRecovering().container
        }
        self.container = container

        // First frame in the right theme: the persisted Appearance choice (or the profile-sex default) and
        // the current OS light/dark setting. `RootAppView` keeps it in step from here on.
        // (Not under tests: they expect the shipped `.dark` unless they select a theme themselves.)
        if !runningTests {
            let profileSex = (try? container.mainContext.fetch(FetchDescriptor<UserProfile>()))?.first?.sex
            ThemeStore.current = AppearanceStore.shared.resolvedTheme(
                systemIsDark: UITraitCollection.current.userInterfaceStyle != .light, sex: profileSex
            )
        }

        // One-time cleanup of activity totals inflated by the old accumulator bug.
        ActivityService.migrateInflatedActivityIfNeeded(context: container.mainContext)

        // One-time cleanup of activity rows poisoned by unvalidated live updates (implausible totals or
        // future-dated rows that would otherwise permanently become "today").
        ActivityService.migrateGarbageActivityIfNeeded(context: container.mainContext)

        // One-time merge of sleep sessions split across midnight by the old start-of-day grouping.
        SleepService.migrateSplitSleepSessionsIfNeeded(context: container.mainContext)

        // One-time re-split of days whose nap merged into that morning's night (issue #59): re-derive
        // each waking day into distinct sessions so the carousel can page through them.
        SleepService.migrateSleepSessionSegmentsIfNeeded(context: container.mainContext)

        // One-time repair of nights stacked by the old add-only sleep rule (from the raw trace, when it
        // holds the transfers) and a stored score for every night (sleep-session-merge.md, D1/D4).
        SleepService.migrateSleepSourcesIfNeeded(context: container.mainContext)

        // A persisted "connected" state can't survive a restart — the live link is gone. Reset it so
        // the UI never shows a false "Connected" until a real connection re-confirms.
        if !runningTests {
            DeviceRepository.resetStaleConnectionState(context: container.mainContext)
        }

        // Don't bring up CoreBluetooth under tests (see `isRunningUnitTests`).
        #if DEBUG
        // `-virtualRing <port>` routes the whole pipeline to `ring-emulator` over a socket instead of
        // BLE. CoreBluetooth is then never started, so a remembered physical ring cannot be dragged
        // into a virtual session.
        let useVirtualRing = VirtualRingLink.configuredPort != nil
        #else
        let useVirtualRing = false
        #endif
        let client = RingBLEClient(startManager: !runningTests && !useVirtualRing)
        let coordinator = RingSyncCoordinator(client: client, context: container.mainContext)
        client.onConnected = { [weak coordinator] in coordinator?.runStartupSequence() }
        // The measurement engine runs tests on the live ring, app-scoped (survives the sheet and tab switches).
        MeasurementService.shared.attach(client: client, coordinator: coordinator, context: container.mainContext)
        // Ring firmware install (stage 4, debug + `firmwareInstall`): gates read the live client + coordinator.
        FirmwareInstallController.shared.attach(client: client, coordinator: coordinator)
        #if DEBUG
        if useVirtualRing, DebugLaunch.bool(VirtualRingLink.onPairKey) {
            // `-virtualRingOnPair YES` (E2E): leave onboarding alone and connect only when the pairing
            // screen's "Connect my ring" starts a scan, so the real pairing → "Name your ring" path runs.
            VirtualRingLink.shared.deferAttach(client: client)
        } else if useVirtualRing {
            // The pairing step needs a BLE scan, which the virtual link bypasses — open on the tabs.
            try? VirtualRingLink.completeOnboardingIfNeeded(context: container.mainContext)
            // Then seed what that flow would have created (a goal row + one workout), so the
            // weekly-goal widget and active-minutes ring have something real to show.
            try? VirtualRingLink.seedToolingDataIfNeeded(context: container.mainContext)
            VirtualRingLink.shared.attachIfConfigured(client: client)
        }
        #endif
        let gps = GpsRouteRecorder()
        _bleClient = State(initialValue: client)
        _coordinator = State(initialValue: coordinator)
        _gpsRecorder = State(initialValue: gps)
        let liveWorkout = LiveWorkoutManager(coordinator: coordinator, gps: gps, context: container.mainContext)
        _liveWorkout = State(initialValue: liveWorkout)
        // The one holder every presentation root re-injects from (`.agaraRingEnvironment()`), so no sheet, cover or
        // background-snapshot rebuild can read `@Environment(X.self)` without the object (TestFlight 1.0.0 (1) crash).
        AgaraRingEnvironment.current = AgaraRingEnvironment(ble: client, coordinator: coordinator, gps: gps,
                                                            liveWorkout: liveWorkout)

        let subscriber = EventPersistenceSubscriber(context: container.mainContext)
        subscriber.keepEveryHeartRateSample = { [weak coordinator] in
            guard let coordinator else { return false }
            return coordinator.workoutHRActive || coordinator.hrState == .measuring
        }
        self.persistence = subscriber
        self.summaryCoordinator = CoachSummaryCoordinator(context: container.mainContext)
        self.anomalyMonitor = CoachAnomalyMonitor(context: container.mainContext)
        let diagnostics = DiagnosticsSubscriber(context: container.mainContext)
        self.diagnostics = diagnostics
        let widgetPublisher = WidgetSnapshotPublisher(context: container.mainContext)
        self.widgetPublisher = widgetPublisher
        let healthSyncPublisher = HealthSyncPublisher(context: container.mainContext)
        self.healthSyncPublisher = healthSyncPublisher
        let stravaSyncPublisher = StravaSyncPublisher(context: container.mainContext)
        self.stravaSyncPublisher = stravaSyncPublisher
        let mainContext = container.mainContext
        self.notificationDataTrigger = CoachNotificationDataTrigger {
            CoachNotificationService(modelContext: mainContext, coordinator: coordinator)
        }

        // Skip the live subsystems entirely under XCTest — the test target exercises these
        // components directly with their own fixtures; the app host just needs to launch cleanly.
        guard !runningTests else { return }

        // Storage: the background maintenance owner (daily compaction, cleanup, "Optimize now") and the disk-space verdict
        // that raw capture, caches and import consult. Nothing runs until the first delayed pass below.
        StorageGuard.refresh()
        StorageCenter.shared.attach(container: container)

        // Agara Cloud (release 1.1): the account, consent and sync engine. Nothing syncs until the user has consented and
        // signed in with a verified address; the flag `agara_cloud` gates the UI.
        AgaraCloud.shared.attach(container: container)

        // Learn/refresh the resting-HR baseline that personalizes the auto HR zones (throttled
        // internally, so this is a cheap no-op most launches).
        RestingHRBaselineService.refreshIfStale(context: container.mainContext)

        // One-shot upgrade backfill: give the trailing week's rows a calorie estimate if they
        // predate the estimator (no-op once every recent day carries one).
        DailyCalorieEstimator.recomputeRecentDays(onlyMissing: true, context: container.mainContext)

        // Start persistence + coordinator draining the bus; auto-reconnect happens when
        // CoreBluetooth reports poweredOn (see RingBLEClient.centralManagerDidUpdateState).
        subscriber.start()
        coordinator.start()
        summaryCoordinator.start()
        anomalyMonitor.start()
        batteryAlertMonitor.start()
        diagnostics.start()
        widgetPublisher.start()
        healthSyncPublisher.start()
        stravaSyncPublisher.start()
        notificationDataTrigger.start()
        // Ring firmware check (flag `firmwareCheck`): at most once a day, when the ring's `a1` identity arrives.
        FirmwareUpdateChecker.shared.start()
        // `-firmwareAutoInstall YES` (debug): download + install once the gates pass (headless verification).
        FirmwareInstallController.shared.startAutoInstallIfRequested()

        // The one notification layer: categories + app-lifecycle tracking (background-only progress news).
        AgaraNotifications.shared.start()
        // Per-day sync progress (onboarding Syncing step, header bar, background sync notification).
        SyncProgress.shared.start()
        // Auto-measure writes (`b3 01`): the store tracks ack + read-back, the coordinator sends.
        AutoMeasureStore.shared.sender = { [coordinator] entry in coordinator.setAutoMeasure(entry) }
        // The once-per-ring default schedule is keyed by the ring's identity ("virtual" for the emulator socket, as
        // on Android).
        AutoMeasureStore.shared.ringAddress = { [client] in client.connectionSource }
        AutoMeasureStore.shared.start()
        // Daily check-in notifications: route taps + register the background wake.
        UNUserNotificationCenter.current().delegate = notificationDelegate
        let ctx = container.mainContext
        // Agara Cloud background refresh (release 1.1): registered before launch finishes, like the coach's tasks.
        AgaraCloud.registerBackgroundTask()
        CoachNotificationScheduler.shared.register { syncBudget in
            CoachNotificationService(modelContext: ctx, coordinator: coordinator, syncWaitTimeout: syncBudget)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootAppView()
                // The default for every Text without its own font — Manrope, never SF Pro.
                .font(AgaraFont.body)
                // All four ring objects, from the same holder every presentation root uses.
                .agaraRingEnvironment()
                .task {
                    // Off the launch path: the routine pass waits until the ring sync has had its head start.
                    guard !Self.isRunningUnitTests else { return }
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    StorageCenter.shared.runIfDue()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // Flush any batched-but-unsaved ring writes before the app suspends so a mid-sync
            // batch isn't lost.
            if phase != .active { persistence.flush() }
            if phase == .background, !Self.isRunningUnitTests { AgaraCloud.shared.scheduleBackgroundRefresh() }
            // Republish the widget snapshot at scene edges: leaving-active captures the freshest
            // flushed data before suspension; becoming-active catches Settings edits (goals, units,
            // visibility) that change tiles without bumping the sync token. No-ops when unchanged.
            if !Self.isRunningUnitTests {
                widgetPublisher.publish(reason: .scenePhase)
                healthSyncPublisher.kick()
                stravaSyncPublisher.kick()
            }
            guard phase == .active else { return }
            if !Self.isRunningUnitTests {
                StorageGuard.refresh()
                StorageCenter.shared.runIfDue()
                if AgaraFeatureStore.isOn(.agaraCloud) { AgaraCloud.shared.kick(reason: .foreground) }
            }
            // Refresh the learned resting-HR baseline on foreground (6h-throttled no-op usually).
            if !Self.isRunningUnitTests {
                RestingHRBaselineService.refreshIfStale(context: container.mainContext)
            }
            // Foreground reconnect: the OS can silently tear down the BLE link while suspended without
            // delivering a disconnect, leaving us "connected" but dead. On every resume, re-link the
            // last-known ring if it isn't actually connected. (Android foreground-reconnect parity.)
            if bleClient.hasLastKnownRing, bleClient.state != .connected {
                bleClient.connectLastKnown()
            }
            // Both calls are no-ops when the AI Coach master switch is off — the
            // scheduler gates on `coachMasterEnabled`, and `runDueSlot` short
            // -circuits via the feature-flags gate.
            CoachNotificationScheduler.shared.scheduleNext()
            guard CoachGate.isOn else { return }
            // Foreground catch-up: deliver a due check-in we missed while away.
            let ctx = container.mainContext
            let coordinator = coordinator
            Task {
                await CoachNotificationService(modelContext: ctx, coordinator: coordinator).runDueSlot()
            }
        }
    }
}
