import SwiftUI
import SwiftData
import UIKit

struct VitalsView: View {
    @Binding var path: NavigationPath
    /// Whether the Vitals tab is the one on screen. The `.page` TabView keeps adjacent tabs alive, so
    /// we gate expensive rebuilds on visibility — an off-screen Vitals must not rebuild on every sync.
    let isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(RingBLEClient.self) private var ble
    @Environment(\.zoomNamespace) private var zoomNS
    @Query private var profiles: [UserProfile]
    @Query private var devices: [Device]
    /// The measure hub, or the measurement ring it hands off to — one sheet slot, so picking a tile
    /// swaps the hub for the ring.
    @State private var sheet: VitalsSheet?
    @State private var features = AgaraFeatureStore.shared
    @State private var dataChange = AgaraDataChange.shared
    /// The app-scoped measurement engine: a running or finished test reopens instead of the hub.
    @State private var measurement = MeasurementService.shared
    @State private var deepLinks = AgaraDeepLinks.shared
    /// Owns the prepared vitals state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: VitalsStore?
    // Card reorder ("edit mode"): long-press a card to enter, drag to reorder, Done to exit. The Done
    // bar itself is rendered by `MainTabView`, which is why edit state lives in a shared session.
    @State private var reorder = CardReorderSession.shared
    @State private var dragging: MetricKey?
    @State private var prefs = MetricPrefsStore.shared
    /// The order being dragged — see the matching note in `TodayView`. Persisted on drop and on exit.
    @State private var liveKeys: [MetricKey] = []
    /// Whether the user actually moved a card; an unsaved order means "use the screen default".
    @State private var orderDirty = false

    /// Canonical Vitals card order (used until the user reorders). Card id = `MetricKey`.
    private static let defaultOrder: [MetricKey] = [
        .heartRate, .spo2, .bloodPressureSystolic, .hrv, .stress, .fatigue, .bloodSugar, .temperature,
        // Behind feature flags (see `MetricKey.requiredFeature`).
        .respiratoryRate, .met, .cardiacLoad, .bloodComponents,
    ]

    private var profile: UserProfile? { profiles.first }
    private var editing: Bool { reorder.editingScope == .vitals }

    var body: some View {
        guard let activeStore = store else {
            return AnyView(AgaraColors.background.ignoresSafeArea().task { ensureStore() })
        }

        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(activeStore)
                grid(activeStore)
            }
            .padding(.horizontal, 16)
            // Extra clearance while editing so the last card stays draggable above the Done bar.
            .padding(.bottom, editing ? AgaraLayout.scrollBottomInsetEditing : AgaraLayout.scrollBottomInset)
        }
        // Tap-outside-to-exit: a catcher layered above the opaque background colour — `.background`
        // stacks back-to-front, so adding it after `AgaraColors.background` would bury it.
        .background {
            if editing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { exitEdit() }
                    .accessibilityHidden(true)
            }
        }
        .background(AgaraColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .agaraScrollEdges()
        // A sync can rebuild the store mid-edit — fold the new card set into the on-screen order, and
        // never while a drag is in flight.
        .onChange(of: activeStore.revision) { _, _ in
            guard editing, dragging == nil else { return }
            liveKeys = CardOrder.reconcile(current: liveKeys, target: orderedKeys(activeStore))
        }
        .onChange(of: reorder.editingScope) { old, new in
            guard old == .vitals, new != .vitals else { return }
            dragging = nil
            persistOrder()
        }
        .task { ensureStore(); if isActive { store?.updateProfile(profile) } }
        #if DEBUG
        .task { await autoMeasureIfRequested() }
        #endif
        .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
        // A measurement notification (or the in-app pill) asks for the Measure sheet.
        .onChange(of: deepLinks.openMeasureSheet) { _, open in if open { openMeasureFromLink() } }
        .onAppear { if deepLinks.openMeasureSheet { openMeasureFromLink() } }
        .onChange(of: isActive) { _, active in if active { store?.updateProfile(profile) } }
        .onChange(of: profile?.updatedAt) { _, _ in store?.updateProfile(profile) }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .hub:
                    MeasureHubSheet(kinds: measureKinds(activeStore), isCharging: ringCharging,
                                    runningID: measurement.isRunning ? measurement.spec?.id : nil) { spec in
                        self.sheet = .measure(spec)
                    }
                case let .measure(spec):
                    MeasurementSheet(spec: spec)
                }
            }
            // Hand the ring objects to the sheet explicitly. Picking a tile swaps the hub for the
            // measurement in the same sheet slot; on the iPad idiom (and so the Mac "Designed for iPad"
            // build) SwiftUI presents the queued sheet from the hub's `viewDidDisappear`, with an
            // environment that no longer carries the `.environment(_:)` objects set on the WindowGroup —
            // `MeasurementSheet`'s `@Environment(RingBLEClient.self)` then traps ("No Observable object of
            // type RingBLEClient found"). That was the Mac "Measure → Heart rate" crash (2026-09-25). All four objects
            // now come from the one holder (`AgaraRingEnvironment`), like every other presentation root.
            .agaraRingEnvironment()
        })
    }

    // MARK: - Header

    /// Title row with the one "Measure" button on the right (it replaced the row of measure pills). The
    /// button opens the measure hub; it is hidden when the ring offers no on-demand test.
    @ViewBuilder
    private func header(_ store: VitalsStore) -> some View {
        let kinds = measureKinds(store)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vitals")
                    .font(AgaraFont.title2.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Today's readings from your ring")
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textMuted)
            }
            Spacer(minLength: 8)
            if !kinds.isEmpty {
                Button { openMeasure() } label: {
                    Label("Measure", systemImage: "waveform.path.ecg")
                        .font(AgaraFont.subheadline.weight(.semibold))
                        .foregroundStyle(AgaraColors.onAccent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 40)
                        .background(AgaraColors.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose a measurement to take with your ring.")
                .accessibilityIdentifier("vitals.measure")
                .help("Take a measurement now")
                .coachMark(CoachMarkStore.measure, text: AgaraHelp.hintMeasure)
            }
        }
        .padding(.top, 4)
    }

    /// The tests the hub offers: flags on, and supported by the ring (its own capability packets when
    /// the probe has run, otherwise the family's capability list).
    private func measureKinds(_ store: VitalsStore) -> [MeasurementSpec] {
        MeasurementRegistry.available(capabilities: store.capabilities,
                              ring: devices.first?.ringCapabilities,
                              isOn: { features.isOn($0) })
    }

    private var ringCharging: Bool { features.isOn(.chargingState) && ble.isCharging }

    /// Measure: straight back to the running or finished test when there is one (resume), else the hub.
    private func openMeasure() {
        if let spec = measurement.spec {
            sheet = .measure(spec)
        } else {
            sheet = .hub
        }
    }

    private func openMeasureFromLink() {
        deepLinks.openMeasureSheet = false
        openMeasure()
    }

    // MARK: - Grid

    /// Single full-width column, rendered in the user's saved order. Long-press any card → reorder.
    @ViewBuilder
    private func grid(_ store: VitalsStore) -> some View {
        let physiology = UserPhysiologyProfile(profile)
        // While editing the column follows the in-flight drag order; otherwise the saved one.
        let keys = editing ? liveKeys : orderedKeys(store)

        VStack(spacing: 14) {
            ReorderableForEach(items: keys, isEditing: editing, revision: store.revision, dragging: $dragging,
                               move: { from, to in move(from, to) },
                               commit: { persistOrder() },
                               hide: { key in hide(key, store) },
                               displayName: { $0.reorderDisplayName },
                               symbolName: { $0.reorderSymbolName },
                               content: { key in
                cardFor(key, store, physiology)
                    // simultaneousGesture so the long-press fires even though each card is a Button.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45).onEnded { _ in enterEdit(store) }
                    )
            })

            // Restore tray: only while editing, and only if something is hidden.
            if editing {
                HiddenMetricsTray(
                    hidden: hiddenKeys(store),
                    restore: { restore($0, store) },
                    displayName: { $0.reorderDisplayName },
                    symbolName: { $0.reorderSymbolName }
                )
            } else {
                // Citations for the ranges on these cards (App Review 1.4.1) — always the last row.
                HealthSourcesLinkCard()
                    .padding(.top, 6)
            }
        }
    }

    /// Metrics hidden in the Vitals scope, so the tray stays in lockstep with Settings visibility.
    /// Device-unsupported metrics stay out of the tray — restoring one could never produce a card.
    private func hiddenKeys(_ store: VitalsStore) -> [MetricKey] {
        Self.defaultOrder.filter {
            $0.isSupported(by: store.capabilities) && prefs.isHidden($0, scope: .vitals)
        }
    }

    /// Hide and restore change which keys belong on screen, so they capture the drag order and then
    /// re-derive it — reusing `resolvedOrder`, which knows where a restored card should land.
    private func hide(_ key: MetricKey, _ store: VitalsStore) {
        ReorderHaptics.selection.selectionChanged()
        persistOrder()
        prefs.setHidden(key, true, scope: .vitals)
        liveKeys = orderedKeys(store)
    }

    private func restore(_ key: MetricKey, _ store: VitalsStore) {
        persistOrder()
        prefs.setHidden(key, false, scope: .vitals)
        liveKeys = orderedKeys(store)
    }

    /// The one place the drag order reaches `UserDefaults`: on drop, on exit, and around a hide.
    private func persistOrder() {
        guard orderDirty, !liveKeys.isEmpty else { return }
        prefs.setOrder(liveKeys.map(\.rawValue), for: .vitals)
        orderDirty = false
    }

    /// Visible Vitals cards in the saved order (falling back to `defaultOrder`).
    private func orderedKeys(_ store: VitalsStore) -> [MetricKey] {
        // Capability from the store's snapshot, hidden read live from `prefs` — see the matching note
        // in `TodayView.orderedKeys` for why `store.visibleMetrics` can't be the gate here.
        let visible = Self.defaultOrder.filter {
            $0.isSupported(by: store.capabilities) && !prefs.isHidden($0, scope: .vitals)
        }
        let raws = prefs.resolvedOrder(
            visible: Set(visible.map(\.rawValue)),
            defaultOrder: Self.defaultOrder.map(\.rawValue),
            scope: .vitals
        )
        return raws.compactMap { MetricKey(rawValue: $0) }
    }

    @ViewBuilder
    private func cardFor(_ key: MetricKey, _ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        switch key {
        case .heartRate: chartCard(store, .heartRate, physiology)
        case .spo2: chartCard(store, .spo2, physiology, showPoints: true)
        case .bloodPressureSystolic: bpCard(store, physiology)
        case .hrv: chartCard(store, .hrv, physiology)
        case .stress:
            if let m = card(store, .stress) { VitalGaugeCard(model: m) { open(.stress) } }
        case .fatigue:
            if let m = card(store, .fatigue) { VitalGaugeCard(model: m) { open(.fatigue) } }
        case .bloodSugar:
            if let g = card(store, .glucose) { VitalGlucoseCard(model: g) { open(.glucose) } }
        case .temperature: chartCard(store, .temperature, physiology)
        case .respiratoryRate: chartCard(store, .respiration, physiology)
        case .met: chartCard(store, .met, physiology)
        case .cardiacLoad: chartCard(store, .cardiacLoad, physiology)
        case .bloodComponents: bloodComponentsCard(store)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func bloodComponentsCard(_ store: VitalsStore) -> some View {
        if let summary = store.bloodComponents {
            VitalBloodComponentsCard(summary: summary, unit: UserPhysiologyProfile(profile).preferredGlucoseUnit,
                                     sex: BiologicalSex(profileSex: profile?.sex)) { open($0) }
        } else {
            VitalEmptyState(metric: .totalCholesterol)
                .padding(.vertical, 20)
                .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
        }
    }

    /// Fires on every cell a dragged card crosses — view state only, no persistence.
    private func move(_ from: Int, _ to: Int) {
        liveKeys = CardOrder.moving(liveKeys, from: from, to: to)
        orderDirty = true
    }

    private func enterEdit(_ store: VitalsStore) {
        guard !editing else { return }
        liveKeys = orderedKeys(store)   // seed before flipping, or the first frame renders an empty column
        orderDirty = false
        ReorderHaptics.selection.prepare()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { reorder.begin(.vitals) }
        // Drag is invisible to VoiceOver — tell VO users how to reorder without it.
        AccessibilityNotification.Announcement(
            "Editing layout. Double-tap and hold to drag, or use actions to move cards."
        ).post()
    }

    /// Ends edit mode. The order is persisted (and `dragging` cleared) by the `editingScope` observer,
    /// which also covers the Done bar and tab switches.
    private func exitEdit() {
        guard editing else { return }
        withAnimation(.easeInOut(duration: 0.2)) { reorder.end() }
    }

    // MARK: - Card builders

    /// The card model, with no visibility gate of its own: `orderedKeys` already decides which cards
    /// the grid renders, and re-checking the store's cached `visibleMetrics` here would drop a card
    /// that was just restored from the Hidden tray, leaving an empty cell behind its remove badge.
    private func card(_ store: VitalsStore, _ metric: MetricKind) -> VitalCardViewModel? {
        store.cards[metric]
    }

    @ViewBuilder
    private func chartCard(_ store: VitalsStore, _ metric: MetricKind,
                           _ physiology: UserPhysiologyProfile, showPoints: Bool = false) -> some View {
        if let model = card(store, metric) {
            let baseline = metric == .hrv ? store.hrvBaseline : nil
            VitalChartCard(model: model, profile: physiology, baseline: baseline, showPoints: showPoints) { open(metric) }
                .agaraZoomSource(AppRoute.metricDetail(metric), in: zoomNS)
        }
    }

    @ViewBuilder
    private func bpCard(_ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        if let model = card(store, .bloodPressure) {
            VitalBloodPressureCard(
                model: model,
                systolic: store.systolicSamples.last?.value,
                diastolic: store.diastolicSamples.last?.value,
                systolicZones: VitalsThresholdEngine.zones(for: .bloodPressure, profile: physiology),
                diastolicZones: VitalsThresholdEngine.diastolicReferenceZones(),
                onTap: { open(.bloodPressure) }
            )
            .agaraZoomSource(AppRoute.metricDetail(.bloodPressure), in: zoomNS)
        }
    }

    private func open(_ metric: MetricKind) {
        path.append(AppRoute.metricDetail(metric))
    }

    // MARK: - E2E tooling

    #if DEBUG
    /// Once per process: `-autoMeasure <id>` (a `MeasurementSpec` id, e.g. `heartRate`) opens the hub, then picks
    /// that tile the way a tap does — for destinations XCUITest can't drive (the Mac "Designed for iPad"
    /// build). Pair with `-startTab vitals`. It waits for the ring to connect (up to 60 s), then goes
    /// ahead regardless, so the no-ring / Bluetooth-off path is exercised too.
    private static var didAutoMeasure = false

    private func autoMeasureIfRequested() async {
        guard !Self.didAutoMeasure, isActive,
              let id = DebugLaunch.string("autoMeasure") else { return }
        Self.didAutoMeasure = true
        for _ in 0..<120 where ble.state != .connected {
            try? await Task.sleep(for: .milliseconds(500))
        }
        E2ETrace.log("autoMeasure \(id): ring state \(ble.state)")
        sheet = .hub
        try? await Task.sleep(for: .seconds(1.5))
        guard let spec = MeasurementRegistry.spec(id: id) else {
            E2ETrace.log("autoMeasure \(id): unknown id")
            return
        }
        E2ETrace.log("autoMeasure \(id): opening the measurement")
        sheet = .measure(spec)
    }
    #endif

    // MARK: - Store lifecycle

    private func ensureStore() {
        if store == nil { store = VitalsStore(modelContext: modelContext, profile: profile) }
    }
}

/// The Vitals screen's one sheet slot: the measure hub, or the measurement ring for a chosen test.
private enum VitalsSheet: Identifiable, Hashable {
    case hub
    case measure(MeasurementSpec)

    var id: String {
        switch self {
        case .hub: return "hub"
        case let .measure(spec): return "measure.\(spec.id)"
        }
    }

    static func == (lhs: VitalsSheet, rhs: VitalsSheet) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
