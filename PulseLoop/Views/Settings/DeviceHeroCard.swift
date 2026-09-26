import SwiftUI
import SwiftData

/// Pure, view-agnostic description of the ring's state for the Settings hero card.
/// All branching lives here so `DeviceHeroCard` stays declarative and this stays unit-testable.
struct DeviceHeroStatus: Equatable {
    enum Action: Equatable {
        case disconnect
        case connect
        case setUp
        case pending // a connect attempt is in flight (connecting / reconnecting / scanning)
    }

    let title: String
    let statusLine: String
    let statusTint: Color
    let batteryText: String?
    let syncText: String?
    let action: Action
    /// Connected and on the charger — the card shows "Charging · NN %" with the charging glyph.
    var isCharging: Bool = false

    var actionTitle: String {
        switch action {
        case .disconnect: return "Disconnect"
        case .connect: return "Connect"
        case .setUp: return "Set up a ring"
        case .pending: return "Connecting…"
        }
    }

    /// The action button is inert while a connection attempt is in flight, so a tap can't cancel or
    /// restart an in-progress (re)connect.
    var actionEnabled: Bool { action != .pending }

    /// `connectedName` reflects the live connection (nil unless connected); `knownName` is the
    /// last stored device (survives disconnect). Separating them distinguishes "known but
    /// disconnected" (`.connect`) from "never paired" (`.setUp`). `nickname` is the user's name for the
    /// ring; when set it replaces the model name in the title (never the paired/unpaired decision).
    static func make(
        state: RingConnectionState,
        connectedName: String?,
        knownName: String?,
        nickname: String? = nil,
        batteryPercent: Int?,
        lastSync: Date?,
        now: Date,
        isCharging: Bool = false,
        chargeEstimate: ChargeEstimator.Estimate? = nil
    ) -> DeviceHeroStatus {
        let title = (connectedName ?? knownName)
            .map { RingNickname.displayName(nickname: nickname, modelName: $0) }
            ?? "No ring connected"

        let statusLine: String
        let statusTint: Color
        switch state {
        case .connected:
            statusLine = "Connected"; statusTint = AgaraColors.success
        case .connecting, .reconnecting:
            statusLine = "Connecting…"; statusTint = AgaraColors.warning
        case .scanning:
            statusLine = "Searching…"; statusTint = AgaraColors.warning
        case .failed:
            statusLine = "Connection failed"; statusTint = AgaraColors.danger
        case .idle, .disconnected:
            statusLine = knownName == nil ? "No ring paired" : "Disconnected"
            statusTint = AgaraColors.textSecondary
        }

        let batteryText = batteryPercent.map { "\(max(0, min(100, $0)))%" }
        let charging = isCharging && state == .connected
        let chargingLine = ChargeEstimator.statusLine(percent: batteryPercent, estimate: chargeEstimate)

        let syncText: String?
        if let lastSync {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            syncText = "Synced " + formatter.localizedString(for: lastSync, relativeTo: now)
        } else {
            syncText = nil
        }

        let action: Action
        switch state {
        case .connected:
            action = .disconnect
        case .connecting, .reconnecting, .scanning:
            action = .pending
        case .idle, .disconnected, .failed:
            action = knownName != nil ? .connect : .setUp
        }

        return DeviceHeroStatus(
            title: title, statusLine: charging ? chargingLine : statusLine,
            statusTint: charging ? AgaraColors.success : statusTint,
            batteryText: batteryText, syncText: syncText, action: action, isCharging: charging
        )
    }
}

/// Rich ring-connectivity card at the top of Settings. The card (or its trailing chevron) opens the
/// Wearable screen; a separate action button connects/disconnects/sets up. The two are distinct
/// controls so both are reachable by touch and VoiceOver.
struct DeviceHeroCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Binding var path: NavigationPath
    /// Re-read the stored device after a persist (a rename lands here without any BLE state change).
    @State private var dataChange = AgaraDataChange.shared

    var body: some View {
        // One SwiftData read for the stored device, reused for name, battery, and art.
        let _ = dataChange.token
        let device = DeviceRepository.current(context: modelContext)
        let deviceType = ble.activeDeviceType ?? device?.deviceType
        let wearableModel = ble.activeWearableModel ?? WearableModel.model(id: device?.wearableModelID)
        let battery = ble.batteryPercent ?? device?.batteryPercent
        let status = DeviceHeroStatus.make(
            state: ble.state,
            connectedName: ble.state == .connected ? wearableModel?.displayName ?? ble.activeDeviceType?.displayName : nil,
            knownName: wearableModel?.displayName ?? deviceType?.displayName,
            nickname: device?.nickname,
            batteryPercent: battery,
            lastSync: coordinator.lastSyncAt,
            now: Date(),
            isCharging: AgaraFeatureStore.shared.isOn(.chargingState) && ble.isCharging,
            chargeEstimate: ble.chargeEstimate
        )

        // The connected card is purely informational and opens Wearable settings, where Disconnect
        // lives. Setup/reconnect remain available here only when the ring is not connected.
        VStack(spacing: 10) {
            Button { path.append(AppRoute.settingsWearable) } label: {
                // Art, text block and the battery + chevron share one centre line; the chip used to sit
                // at the top-right with the chevron below it, lined up with nothing.
                HStack(alignment: .center, spacing: 16) {
                    RingArtView(
                        tint: AgaraColors.info,
                        size: 72,
                        imageName: wearableModel?.imageName
                    )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.title)
                            .font(AgaraFont.title3)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(status.statusLine)
                            .font(AgaraFont.footnote.weight(.regular))
                            .foregroundStyle(status.statusTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        if let syncText = status.syncText {
                            Text(syncText)
                                .font(AgaraFont.caption.weight(.regular))
                                .foregroundStyle(AgaraColors.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    HStack(spacing: 6) {
                        if status.isCharging {
                            RingBatteryGlyph(percent: battery, dotColor: nil, size: 30, charging: true)
                                .accessibilityHidden(true)
                        } else if let batteryText = status.batteryText, let battery, battery > 0 {
                            // Coloured by the shared battery tiers (it was always green, even at 20 %).
                            let tint = BatteryTier(percent: battery).color
                            HStack(spacing: 4) {
                                Image(systemName: "battery.\(Int((Double(min(battery, 100)) / 25).rounded()) * 25)percent")
                                Text(batteryText)
                            }
                                .font(AgaraFont.caption.weight(.semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(tint.opacity(0.12), in: Capsule())
                                .opacity(ble.state == .connected ? 1 : 0.6)
                                .fixedSize()
                        }

                        Image(systemName: "chevron.right")
                            .font(AgaraFont.footnote.weight(.semibold))
                            .foregroundStyle(AgaraColors.textMuted)
                            .frame(width: 20, height: 20)
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardAccessibilityLabel(status))
            .accessibilityHint("Opens ring settings")

            if status.action != .disconnect {
                Button(action: { performAction(status.action) }) {
                    Text(status.actionTitle)
                        .font(AgaraFont.footnote.weight(.semibold))
                        .foregroundStyle(status.actionEnabled ? AgaraColors.textPrimary : AgaraColors.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Plain liquid glass (no accent tint); interactive when enabled.
                        .agaraGlass(Capsule(), interactive: status.actionEnabled)
                }
                .buttonStyle(.plain)
                .disabled(!status.actionEnabled)
                .accessibilityLabel(status.actionTitle)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        // Liquid glass hero card. The container lets the card glass and the inner
        // Connect-pill glass coexist as one managed group (glass can't sample glass,
        // so a bare nested glass would render flat).
        .agaraGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .agaraGlassContainer(spacing: 24)
    }

    private func cardAccessibilityLabel(_ status: DeviceHeroStatus) -> String {
        [
            status.title,
            status.statusLine,
            status.batteryText.map { "Battery \($0)" },
            status.syncText,
        ]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func performAction(_ action: DeviceHeroStatus.Action) {
        switch action {
        case .disconnect: ble.disconnect()
        case .connect: ble.connectLastKnown()
        case .setUp: path.append(AppRoute.pairing)
        case .pending: break
        }
    }


}
