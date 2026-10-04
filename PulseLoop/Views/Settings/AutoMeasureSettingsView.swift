import SwiftUI
import SwiftData

/// Settings › Auto-measure (flag `auto_measure_settings`): one group per metric in the ring's own `b3` schedule,
/// each with an on/off toggle and an interval picker offering only what the ring accepts (multiples of the row's
/// step, up to 4 h). Rows the ring locks (the heart-rhythm scatter, window-limited) are shown read-only. Built
/// entirely from the schedule the ring reports (`AutoMeasure`), so a metric the ring adds needs no new UI.
/// Replaces the old "Measurement Frequency" screen, which the Agara ring never qualified for.
struct AutoMeasureSettingsView: View {
    @Environment(RingBLEClient.self) private var ble
    @Query private var devices: [Device]
    @State private var store = AutoMeasureStore.shared
    @State private var features = AgaraFeatureStore.shared
    @State private var livePrefs = VeepooLivePrefsStore.shared

    /// The ring's schedule: this session's latest report, else the one persisted on the device row.
    private var schedule: [AutoMeasureEntry] {
        let live = store.schedule
        let all = live.isEmpty ? (devices.first?.autoMeasureSchedule ?? []) : live
        // Rows for metrics behind a flag (BP type 1, glucose 2, blood components 8) stay hidden while it is off.
        return all.filter { Self.isOffered($0.type, isOn: { AgaraFeatureStore.isOn($0) }) }.sorted { $0.type < $1.type }
    }

    private var connected: Bool { ble.state == .connected }

    /// The one-line explanation under the toggle (same wording as Android).
    static let liveHeartRateExplanation = "Streams your pulse continuously while connected; uses more ring battery."

    /// Whether the schedule row for a ring type code is shown — the rule lives in `AutoMeasure.isOffered`.
    static func isOffered(_ type: Int, isOn: (AgaraFeature) -> Bool) -> Bool {
        AutoMeasure.isOffered(type, isOn: isOn)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("How often your ring measures on its own, even when your phone is away. Shorter intervals use more ring battery.")
                    .font(AgaraFont.subheadline)
                    .foregroundStyle(AgaraColors.textSecondary)
                    .padding(.horizontal, 4)
                // Spec item 1: the continuous `D0` stream, off by default (`ring_live_hr_default_on`), flag `live_hr_toggle`.
                if features.isOn(.liveHrToggle) {
                    SettingsGroup(footer: Self.liveHeartRateExplanation) {
                        FormToggleRow(title: "Live heart rate", isOn: $livePrefs.liveHeartRateEnabled)
                            .accessibilityIdentifier("autoMeasure.liveHeartRate")
                    }
                }
                if !connected {
                    Label("Connect your ring to change these settings.", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(AgaraFont.subheadline)
                        .foregroundStyle(AgaraColors.warning)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("autoMeasure.offline")
                }
                if schedule.isEmpty {
                    SettingsGroup(footer: "The schedule appears once your ring has connected and reported it.") {
                        FormValueRow(title: "Schedule") {
                            Text(connected ? "Reading…" : "Not read yet").foregroundStyle(AgaraColors.textMuted)
                        }
                    }
                } else {
                    ForEach(schedule) { entry in
                        AutoMeasureRow(entry: store.displayed(entry), write: store.writes[entry.type], editable: connected) {
                            store.set($0)
                        }
                    }
                }
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Auto-measure")
    }
}

/// One metric: toggle + interval menu, or a read-only summary when the ring locks it.
private struct AutoMeasureRow: View {
    let entry: AutoMeasureEntry
    let write: AutoMeasureStore.WriteState?
    let editable: Bool
    let onChange: (AutoMeasureEntry) -> Void

    private var locked: Bool { AutoMeasure.isLocked(entry) }

    private var footer: String? {
        switch write {
        case .saving?: return "Saving to your ring…"
        case let .failed(message)?: return message
        case nil: break
        }
        if locked { return "Set by the ring; it can't be changed here." }
        return nil
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { entry.enabled }, set: { value in
            var next = entry
            next.enabled = value
            onChange(next)
        })
    }

    var body: some View {
        SettingsGroup(header: entry.title, footer: footer) {
            if locked {
                FormValueRow(title: "Schedule") {
                    Text(entry.summary).foregroundStyle(AgaraColors.textMuted)
                }
                .accessibilityIdentifier("autoMeasure.locked.\(entry.type)")
            } else {
                FormToggleRow(title: "Measure automatically", isOn: enabledBinding)
                    .disabled(!editable || write == .saving)
                    .accessibilityIdentifier("autoMeasure.toggle.\(entry.type)")
                if entry.enabled {
                    FormValueRow(title: "Every") {
                        Menu {
                            ForEach(AutoMeasure.intervals(for: entry), id: \.self) { minutes in
                                Button {
                                    guard minutes != entry.intervalMinutes else { return }
                                    var next = entry
                                    next.intervalMinutes = minutes
                                    onChange(next)
                                } label: {
                                    let option = AutoMeasure.optionLabel(minutes: minutes, for: entry)
                                    if minutes == entry.intervalMinutes {
                                        Label(option, systemImage: "checkmark")
                                    } else {
                                        Text(option)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(AutoMeasure.label(minutes: entry.intervalMinutes)).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(AgaraFont.caption2).imageScale(.small)
                            }
                            .font(AgaraFont.body)
                            .foregroundStyle(AgaraColors.accent)
                        }
                        .disabled(!editable || write == .saving)
                        .accessibilityIdentifier("autoMeasure.interval.\(entry.type)")
                        .accessibilityValue(AutoMeasure.label(minutes: entry.intervalMinutes))
                    }
                }
                if !entry.isAllDay {
                    FormValueRow(title: "Hours") {
                        Text(String(format: "%02d:%02d–%02d:%02d", entry.startHour, entry.startMinute, entry.endHour, entry.endMinute))
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                }
            }
        }
        // Hidden marker the E2E test polls: "saving" / "failed" / "idle".
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("\(entry.title) write state")
                .accessibilityIdentifier("autoMeasure.state.\(entry.type)")
                .accessibilityValue(write == .saving ? "saving" : (write == nil ? "idle" : "failed"))
        }
    }
}
