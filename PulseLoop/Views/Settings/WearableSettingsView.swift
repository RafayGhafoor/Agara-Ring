import SwiftUI
import SwiftData

/// Wearable detail screen: connection state and the ring actions (sync / find / disconnect / forget /
/// pair). Relocated from the old flat `SettingsView` Ring section.
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
    private var liveHeartRateBinding: Binding<Bool> {
        @Bindable var store = VeepooLivePrefsStore.shared
        return $store.liveHeartRateEnabled
    }

    /// `RelativeDateTimeFormatter` is expensive to allocate; reuse one instance instead of building
    /// a fresh formatter on every access.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var lastSyncedLabel: String {
        guard let date = coordinator.lastSyncAt else { return "Not yet" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if ble.state == .connected {
                    SettingsGroup(header: "Connected ring") {
                        nameRow
                        FormValueRow(title: "Device") { Text(wearableDisplayName).foregroundStyle(AgaraColors.textMuted) }
                        FormValueRow(title: "Battery") {
                            if charging {
                                HStack(spacing: 6) {
                                    RingBatteryGlyph(percent: batteryPercent, dotColor: nil, size: 22, charging: true)
                                        .accessibilityHidden(true)
                                    Text(ChargeEstimator.statusLine(percent: batteryPercent, estimate: ble.chargeEstimate))
                                        .foregroundStyle(AgaraColors.success)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                    if case .fullIn? = ble.chargeEstimate {
                                        HelpTip(AgaraHelp.chargingEstimate)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                Text(batteryPercent.map { "\($0)%" } ?? "--").foregroundStyle(AgaraColors.textMuted)
                            }
                        }
                        if features.isOn(.firmwareCheck), let firmware = devices.first?.firmwareVersion, !firmware.isEmpty {
                            FirmwareRow(installed: firmware, identity: firmwareIdentity, checker: firmwareChecker)
                        } else if features.isOn(.capabilityProbe), let firmware = devices.first?.firmwareVersion, !firmware.isEmpty {
                            FormValueRow(title: "Firmware") { Text(firmware).foregroundStyle(AgaraColors.textMuted) }
                        }
                        FormValueRow(title: "Last synced") { Text(lastSyncedLabel).foregroundStyle(AgaraColors.textMuted) }
                    }
                    if features.isOn(.autoMeasureSettings), let schedule = devices.first?.autoMeasureSchedule, !schedule.isEmpty {
                        SettingsGroup(
                            header: "Automatic measurements",
                            footer: "How often the ring measures on its own. Read from the ring — editing comes later."
                        ) {
                            ForEach(schedule) { entry in
                                FormValueRow(title: entry.title) {
                                    Text(entry.summary).foregroundStyle(AgaraColors.textMuted)
                                }
                            }
                        }
                    }
                    BatteryHistorySection()
                    // Veepoo/TK20: continuous HR streaming is optional (battery). Other families have
                    // no live HR channel, so the toggle only appears for the Agara ring.
                    if ble.activeDeviceType == .veepoo {
                        SettingsGroup(
                            header: "Live data",
                            footer: "Streams heart rate continuously while connected so the HR card ticks in real time (drains battery). Turn off to revert to periodic updates only."
                        ) {
                            FormToggleRow(title: "Live heart rate", isOn: liveHeartRateBinding)
                        }
                    }
                    HStack(spacing: 10) {
                        SecondaryButton(title: "Sync now", systemImage: "arrow.triangle.2.circlepath") { coordinator.syncNow() }
                        if canFindRing {
                            // The ring vibrates for up to 10 s; tap again to stop it sooner.
                            if coordinator.isFindingRing {
                                SecondaryButton(title: "Stop", systemImage: "stop.fill") { coordinator.stopFindingRing() }
                            } else {
                                SecondaryButton(title: "Find ring", systemImage: "bell.fill") { coordinator.findRing() }
                                    .accessibilityHint(AgaraHelp.findRing)
                                    .help(AgaraHelp.findRing)
                            }
                        }
                    }
                    SecondaryButton(title: "Disconnect", systemImage: "xmark") {
                        confirm = .disconnectRing { [ble] in ble.disconnect() }
                    }
                    // Forget unbinds the ring: the one destructive action here (Android matches).
                    DestructiveButton(title: "Forget ring", systemImage: "trash") { confirm = .forgetRing { [ble] in ble.forget() } }
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
                }
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Wearable")
        // Same copy as Android's confirmation (audit batch A #24) — now in `ConfirmAction.forgetRing`.
        .confirmAction($confirm)
        .sheet(isPresented: $showsRename) {
            RenameRingSheet(
                initialText: RingNickname.prefill(identifier: ble.deviceIdentifier, row: devices.first),
                peripheralIdentifier: ble.deviceIdentifier
            )
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
        let end = Date()
        let start: Date
        switch range {
        case .twentyFourHours: start = Calendar.current.date(byAdding: .hour, value: -24, to: end) ?? end
        default:               start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        }
        let rows = MetricsRepository.batterySamples(start: start, end: end, context: modelContext)
        samples = rows.map { ChartSample(timestamp: $0.timestamp, value: Double($0.percent)) }
    }
}
