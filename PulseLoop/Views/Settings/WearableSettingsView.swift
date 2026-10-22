import SwiftUI
import SwiftData
import UserNotifications

/// Wearable detail screen: the ring card (status, battery, Sync now), the ring actions (find / disconnect /
/// forget / pair), the ring details, auto-measure, battery alerts and history — Android's order. Relocated from the old flat `SettingsView` Ring section.
struct WearableSettingsView: View {
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var devices: [Device]
    @Binding var path: NavigationPath
    @State private var features = AgaraFeatureStore.shared
    @State private var showsRename = false
    /// Disconnect / Forget awaiting confirmation (`ConfirmAction`, the one confirmation component).
    @State private var confirm: ConfirmAction?
    @State private var firmwareChecker = FirmwareUpdateChecker.shared
    /// Find ring's proximity screen is up (flag `find_ring_proximity`).
    @State private var showsFindRing = false

    /// The firmware-update lookup key, from the ring's persisted `a1` identity (nil until a connect saw it).
    private var firmwareIdentity: FirmwareIdentity? {
        guard let device = devices.first, let number = device.deviceNumber,
              let version = device.firmwareVersion, let test = device.firmwareTestVersion else { return nil }
        return FirmwareIdentity(deviceNumber: number, version: version, testVersion: test)
    }

    private var charging: Bool { features.isOn(.chargingState) && ble.isCharging }

    /// Find ring is offered when the flag is on and the ring says it can (or hasn't said yet).
    private var canFindRing: Bool {
        guard features.isOn(.findRing) else { return false }
        if features.isOn(.capabilityProbe), let caps = devices.first?.ringCapabilities { return caps.findDevice }
        return true
    }

    /// the ring reports battery in-band (not via a GATT characteristic), so it lands on the persisted
    /// `Device` rather than `ble.batteryPercent`. Mirror the header's fallback so this never shows "--"
    /// when the header shows a value.
    private var batteryPercent: Int? { ble.batteryPercent ?? devices.first?.batteryPercent }
    private var wearableDisplayName: String {
        let storedModel = WearableModel.model(id: devices.first?.wearableModelID)
        return ble.activeWearableModel?.displayName
            ?? storedModel?.displayName
            ?? ble.activeDeviceType?.displayName
            ?? devices.first?.deviceType.displayName
            ?? "Connected ring"
    }

    /// The ring's name as the user sees it everywhere: its nickname, else the model name.
    private var ringName: String {
        RingNickname.displayName(nickname: devices.first?.nickname, modelName: wearableDisplayName)
    }

    /// "Name · <name> · Rename" — opens the same editor as the pairing "Name your ring" step.
    private var nameRow: some View {
        FormValueRow(title: "Name") {
            HStack(spacing: 10) {
                Text(ringName)
                    .foregroundStyle(AgaraColors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Rename") { showsRename = true }
                    .font(AgaraFont.body.weight(.semibold))
                    .foregroundStyle(AgaraColors.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Rename ring")
                    .accessibilityValue(ringName)
            }
        }
    }

    /// Binding into the shared live-streaming preference (default on).

    /// `RelativeDateTimeFormatter` is expensive to allocate; reuse one instance instead of building
    /// a fresh formatter on every access.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var lastSyncedLabel: String {
        guard let date = coordinator.lastSyncAt else { return "Not yet" }
        return StoreCapture.relative(Self.relativeFormatter.localizedString(for: date, relativeTo: AppClock.now))
    }

    /// "Connected · synced 2 min ago", or the charging line ("Charging · 64 % · Full in ~20 min") on the charger.
    private var statusLine: String {
        if charging { return ChargeEstimator.statusLine(percent: batteryPercent, estimate: ble.chargeEstimate) }
        guard let date = coordinator.lastSyncAt else { return "Connected" }
        let ago = StoreCapture.isActive || AppClock.now.timeIntervalSince(date) < 60 ? "just now" : Self.relativeFormatter.localizedString(for: date, relativeTo: AppClock.now)
        return "Connected · synced \(ago)"
    }

    /// The ring card (polish spec item 4, mirrors Android's): glyph, name, status, battery, then Sync now.
    private var ringCard: some View {
        SettingsGroup {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    RingBatteryGlyph(percent: batteryPercent, dotColor: AgaraColors.success, size: 52, charging: charging)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ringName)
                            .font(AgaraFont.title3.weight(.semibold))
                            .foregroundStyle(AgaraColors.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(statusLine)
                                .font(AgaraFont.footnote)
                                .foregroundStyle(AgaraColors.success)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if charging, case .fullIn? = ble.chargeEstimate { HelpTip(AgaraHelp.chargingEstimate) }
                        }
                    }
                    Spacer(minLength: 8)
                    Text(batteryPercent.map { "\($0)%" } ?? "--")
                        .font(AgaraFont.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(charging ? AgaraColors.success
                                         : batteryPercent.map { BatteryTier(percent: $0).color } ?? AgaraColors.textMuted)
                        .accessibilityLabel("Battery \(batteryPercent.map { "\($0)%" } ?? "unknown")")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wearable.ringCard")
                Button { coordinator.syncNow() } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .font(AgaraFont.callout.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(AgaraColors.textPrimary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(AgaraColors.textPrimary.opacity(0.14), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wearable.syncNow")
            }
            .padding(16)
        }
    }

    /// Find ring · Disconnect · Forget in one group (consistency plan B). Disconnect and Forget ask first
    /// (`ConfirmAction`, copy from `brand.yaml`); Forget is the one destructive row.
    private var ringActions: some View {
        SettingsGroup(header: "Ring actions") {
            if features.isOn(.findRingProximity) {
                // The proximity screen; it vibrates the ring only on its own "Make it vibrate" button.
                Button { showsFindRing = true } label: { ringActionLabel("Find ring", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.plain)
                    .accessibilityHint(AgaraCopy.findRingHint)
            } else if canFindRing {
                // The ring vibrates for up to 10 s; tap again to stop it sooner.
                if coordinator.isFindingRing {
                    Button { coordinator.stopFindingRing() } label: { ringActionLabel("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.plain)
                } else {
                    Button { coordinator.findRing() } label: { ringActionLabel("Find ring", systemImage: "bell.fill") }
                        .buttonStyle(.plain)
                        .accessibilityHint(AgaraHelp.findRing)
                        .help(AgaraHelp.findRing)
                }
            }
            Button { confirm = .disconnectRing { [ble] in ble.disconnect() } } label: {
                ringActionLabel("Disconnect", systemImage: "xmark.circle")
            }
            .buttonStyle(.plain)
            Button { confirm = .forgetRing { [ble] in ble.forget() } } label: {
                ringActionLabel("Forget ring", systemImage: "trash", tint: AgaraColors.danger)
            }
            .buttonStyle(.plain)
        }
    }

    /// A full-width action row (icon + title) inside a `SettingsGroup`.
    private func ringActionLabel(_ title: String, systemImage: String, tint: Color = AgaraColors.textPrimary,
                                 chevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(AgaraFont.body)
                .foregroundStyle(tint == AgaraColors.textPrimary ? AgaraColors.accent : tint)
                .frame(width: 24)
            Text(title)
                .font(AgaraFont.body)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(AgaraFont.footnote.weight(.semibold))
                    .foregroundStyle(AgaraColors.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if ble.state == .connected {
                    // Polish spec item 4 (same order as Android): ring card → Ring actions → Ring details →
                    // Auto-measure → Low-battery alert → Battery history.
                    ringCard
                    ringActions
                    SettingsGroup(header: "Ring details") {
                        nameRow
                        FormValueRow(title: "Model") { Text(wearableDisplayName).foregroundStyle(AgaraColors.textMuted) }
                        if features.isOn(.firmwareCheck), let firmware = devices.first?.firmwareVersion, !firmware.isEmpty {
                            FirmwareRow(installed: firmware, identity: firmwareIdentity, checker: firmwareChecker)
                        } else if features.isOn(.capabilityProbe), let firmware = devices.first?.firmwareVersion, !firmware.isEmpty {
                            FormValueRow(title: "Firmware") { Text(firmware).foregroundStyle(AgaraColors.textMuted) }
                        }
                        FormValueRow(title: "Last synced") { Text(lastSyncedLabel).foregroundStyle(AgaraColors.textMuted) }
                    }
                    if AutoMeasure.showsSettingsRow(flagOn: features.isOn(.autoMeasureSettings),
                                                    schedule: devices.first?.autoMeasureSchedule ?? [],
                                                    supportsAutoMeasure: devices.first?.ringCapabilities?.autoMeasure == true) {
                        SettingsGroup(footer: "How often the ring measures on its own.") {
                            Button { path.append(AppRoute.settingsAutoMeasure) } label: {
                                ringActionLabel("Auto-measure", systemImage: "timer", chevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    RingBatteryAlertToggle()
                    BatteryHistorySection()
                    // The "Live heart rate" toggle lives at the top of Auto-measure (spec item 1, both apps).
                } else {
                    SettingsGroup(header: "No ring connected") {
                        if ble.hasLastKnownRing && devices.first != nil { nameRow }
                        FormValueRow(title: "Status") { Text(ble.state.rawValue.capitalized).foregroundStyle(AgaraColors.textMuted) }
                    }
                    PrimaryButton(title: "Add a ring", systemImage: "plus.circle") {
                        path.append(AppRoute.pairing)
                    }
                    if ble.hasLastKnownRing && ble.state != .reconnecting {
                        SecondaryButton(title: "Reconnect last ring", systemImage: "arrow.clockwise") { ble.connectLastKnown() }
                        DestructiveButton(title: "Forget ring", systemImage: "trash") { confirm = .forgetRing { [ble] in ble.forget() } }
                    }
                    RingBatteryAlertToggle()
                }
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Wearable")
        // Same copy as Android's confirmation (audit batch A #24) — now in `ConfirmAction.forgetRing`.
        .confirmAction($confirm)
        .fullScreenCover(isPresented: $showsFindRing) {
            FindRingView(canVibrate: canFindRing)
                .agaraRingEnvironment()
        }
        .sheet(isPresented: $showsRename) {
            RenameRingSheet(
                initialText: RingNickname.prefill(identifier: ble.deviceIdentifier, row: devices.first),
                peripheralIdentifier: ble.deviceIdentifier
            )
            .agaraRingEnvironment()
        }
    }
}

/// Low-battery notifications for the ring (20 % and 10 %). Lives on the Wearable screen so it is reachable
/// with the coach off (it used to sit under Coach Check-Ins; parity audit 2026-09-26). The truth is the raw
/// `BatteryAlertMonitor.enabledKey` default (absent = on).
struct RingBatteryAlertToggle: View {
    @State private var enabled = UserDefaults.standard.object(forKey: BatteryAlertMonitor.enabledKey) as? Bool ?? true
    @State private var denied = false

    var body: some View {
        SettingsGroup(
            header: "Ring battery alerts",
            footer: denied ? AgaraCopy.notificationsDisabled : "Get a heads-up when your ring drops below 20% and 10%."
        ) {
            FormToggleRow(title: "Low battery notifications", isOn: Binding(get: { enabled }, set: set))
                .accessibilityIdentifier("wearable.batteryAlerts")
        }
    }

    /// Turning on asks for notification permission first; refused leaves it off with the hint.
    private func set(_ on: Bool) {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: BatteryAlertMonitor.enabledKey)
            return
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            enabled = granted
            denied = !granted
            UserDefaults.standard.set(granted, forKey: BatteryAlertMonitor.enabledKey)
        }
    }
}

/// Battery-drainage chart for the connected ring. Reads the throttled `BatterySample` history (written
/// by `EventPersistenceSubscriber`) for the selected window and draws it with the shared `ZoneLineChart`
/// on a fixed 0–100 axis. The fetch is on-demand (only while this screen is visible) and re-runs when the
/// window changes or new data is persisted — so it adds no ongoing cost.
private struct BatteryHistorySection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var dataChange = AgaraDataChange.shared
    @State private var range: MetricRange = .twentyFourHours
    @State private var samples: [ChartSample] = []

    /// Only the two windows that make sense for battery: a day of drainage, or a week of cycles.
    private static let ranges: [MetricRange] = [.twentyFourHours, .sevenDays]

    private func rangeLabel(_ r: MetricRange) -> String { r == .twentyFourHours ? "24h" : "7d" }

    private func color(for percent: Double) -> Color {
        BatteryTier(percent: Int(percent.rounded())).color
    }

    var body: some View {
        SettingsGroup(header: "Battery history") {
            FormValueRow(title: "Range") {
                Picker("Range", selection: $range) {
                    ForEach(Self.ranges, id: \.self) { Text(rangeLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            FormField {
                // The shared chart (`AgaraChart` via `ZoneLineChart`): tap, hover or press-and-drag shows the
                // level at that time — the battery chart was the one graph without a value marker.
                ZoneLineChart(
                    samples: samples,
                    metric: .heartRate,          // axis styling only; battery uses its own domain + colors
                    yDomain: 0...100,
                    range: range,
                    showAxes: true,
                    height: 160,
                    yTicks: [0, 25, 50, 75, 100],
                    interactive: true,
                    valueLabel: { "\(Int($0.rounded()))%" },
                    accessibilityTitle: "Battery history",
                    empty: AgaraChartEmpty(
                        text: "Not enough data yet — battery history builds up as your ring reports its level.",
                        minimumPoints: 2
                    ),
                    colorForValue: color(for:)
                )
                .accessibilityIdentifier("battery.chart")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
    }

    private func reload() {
        let end = AppClock.now
        let start: Date
        switch range {
        case .twentyFourHours: start = Calendar.current.date(byAdding: .hour, value: -24, to: end) ?? end
        default:               start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        }
        let rows = MetricsRepository.batterySamples(start: start, end: end, context: modelContext)
        samples = rows.map { ChartSample(timestamp: $0.timestamp, value: Double($0.percent)) }
    }
}
