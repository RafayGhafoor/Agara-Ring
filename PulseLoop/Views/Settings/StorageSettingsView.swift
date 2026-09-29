import SwiftUI
import SwiftData

/// Settings › Data & Export › Storage (store launch, phase 3; flag `storage_settings`).
///   • Usage — one stacked bar and a row per class (icon tile, label, size). Sizes come from SQLite's `dbstat`, "≈" when estimated.
///   • Storage limit and how long detail is kept — choices from the shared catalog.
///   • Always kept — static copy: what the limit never touches.
///   • Diagnostics — raw Bluetooth capture (moved here from Data & Export) and Clear raw data, through the one confirmation.
///   • Optimize now — compaction, cleanup and the cap ladder, progress on the one sync-progress model.
/// Ordinary labels are native; the destructive confirmation copy comes from the catalog (`confirm_clear_raw_data_*`).
struct StorageSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var center = StorageCenter.shared
    @State private var progress = SyncProgress.shared
    @State private var confirm: ConfirmAction?
    @State private var captureRawPackets = RawPacketCapture.userOptedIn
    @State private var capMb = StoragePrefs().capMb
    @State private var retentionDays = StoragePrefs().detailRetentionDays
    @State private var observedSpanDays: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                bannerView
                usageGroup
                limitGroup
                alwaysKeptGroup
                diagnosticsGroup
                optimizeGroup
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Storage")
        .confirmAction($confirm)
        .task {
            await center.refreshUsage()
            observedSpanDays = spanDays()
        }
        .accessibilityIdentifier("storageSettings")
    }

    // MARK: - Banner

    @ViewBuilder private var bannerView: some View {
        switch center.banner {
        case .none:
            EmptyView()
        case let .overLimit(used, cap):
            banner(icon: "externaldrive.badge.exclamationmark", tint: AgaraColors.warning,
                   title: "Over your limit",
                   text: "\(Self.size(used)) is stored and your limit is \(Self.size(cap)). What is left is kept because it isn't backed up "
                       + "yet or is your own content. Raise the limit, or export a backup and clear coach history.")
        case let .lowDisk(free):
            banner(icon: "internaldrive", tint: AgaraColors.warning, title: "Your phone is low on space",
                   text: "\(Self.size(free)) is free. Bluetooth diagnostics are paused and space won't be reclaimed until more is free. "
                       + "Your readings keep being saved.")
        case let .criticalDisk(free):
            banner(icon: "exclamationmark.triangle.fill", tint: AgaraColors.danger, title: "Your phone is almost out of space",
                   text: "\(Self.size(free)) is free. Readings and summaries are still saved, but caches are paused and importing a backup "
                       + "is unavailable until you free some space.")
        }
    }

    private func banner(icon: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: icon, style: .tinted(tint), size: .medium)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AgaraFont.subheadline.weight(.semibold)).foregroundStyle(AgaraColors.textPrimary)
                Text(text).font(AgaraFont.caption).foregroundStyle(AgaraColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .agaraGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storageBanner")
    }

    // MARK: - Usage

    private static let classOrder: [StorageClass] = [.healthReadings, .dailySummaries, .workouts, .coach, .diagnostics, .caches, .other]

    static func tint(_ c: StorageClass) -> Color {
        switch c {
        case .healthReadings: return AgaraColors.heartRate
        case .dailySummaries: return AgaraColors.sleep
        case .workouts: return AgaraColors.steps
        case .coach: return AgaraColors.accent
        case .diagnostics: return AgaraColors.warning
        case .caches: return AgaraColors.hrv
        case .other: return AgaraColors.textMuted
        }
    }

    /// "18.6 MB": one decimal above 1 MB, whole KB below.
    static func size(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%d KB", Int((Double(bytes) / 1024).rounded()))
    }

    private var usageGroup: some View {
        let usage = center.usage
        let approx = (usage?.exact ?? true) ? "" : "≈ "
        let used = usage?.usedBytes ?? 0
        let capText = StoragePrefs().capBytes.map { Self.size($0) } ?? "no limit"
        return SettingsGroup(header: "Usage", footer: usage == nil ? nil : "Sizes are for what the app stores on this phone.") {
            FormField {
                VStack(alignment: .leading, spacing: 10) {
                    Text(usage == nil ? "Measuring…" : "\(approx)\(Self.size(used)) of \(capText)")
                        .font(AgaraFont.title3.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                        .accessibilityIdentifier("storageTotal")
                    UsageBar(usage: usage, cap: StoragePrefs().capBytes)
                        .frame(height: 12)
                }
            }
            ForEach(Self.classOrder.filter { (usage?.bytes($0) ?? 0) > 0 || $0 != .other }) { c in
                UsageRow(symbol: c.symbol, tint: Self.tint(c), title: c.title,
                         value: usage == nil ? "—" : "\(approx)\(Self.size(usage?.bytes(c) ?? 0))")
            }
            if let reclaimable = usage?.reclaimableBytes, reclaimable > 0 {
                UsageRow(symbol: "arrow.down.right.and.arrow.up.left", tint: AgaraColors.textMuted,
                         title: "Free space inside the database", value: Self.size(reclaimable), muted: true)
            }
        }
    }

    // MARK: - Limit and retention

    private var limitGroup: some View {
        SettingsGroup(
            header: "Limits",
            footer: limitFooter
        ) {
            FormMenuRow(title: "Storage limit", value: Self.capLabel(capMb)) {
                Picker("Storage limit", selection: Binding(get: { capMb }, set: { capMb = $0; StoragePrefs().capMb = $0 })) {
                    ForEach(StoragePrefs.capOptionsMb, id: \.self) { Text(Self.capLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
            }
            FormMenuRow(title: "Keep detailed readings", value: Self.retentionLabel(retentionDays)) {
                Picker("Keep detailed readings", selection: Binding(get: { retentionDays },
                                                                    set: { retentionDays = $0; StoragePrefs().detailRetentionDays = $0 })) {
                    ForEach(StoragePrefs.retentionOptionsDays, id: \.self) { Text(Self.retentionLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
    }

    private var limitFooter: String {
        var text = "When storage goes over 90% of the limit, Agara Ring first clears diagnostics, old logs and caches, then optimizes. "
            + "Older detail is summarised only after it has been backed up; nothing is removed while your data isn't."
        if let rate = yearlyRateBytes { text += " About \(Self.size(rate)) a year at your usage." }
        return text
    }

    static func capLabel(_ mb: Int) -> String {
        switch mb {
        case 0: return "No limit"
        case 1000: return "1 GB"
        default: return "\(mb) MB"
        }
    }

    static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 365: return "1 year"
        case 180: return "6 months"
        default: return "\(days) days"
        }
    }

    /// Bytes per year at the observed rate: readings size over the span the data covers (needs 2+ days of history).
    private var yearlyRateBytes: Int64? {
        guard let usage = center.usage, let span = observedSpanDays, span >= 2 else { return nil }
        return Int64(Double(usage.bytes(.healthReadings)) / span * 365)
    }

    private func spanDays() -> Double? {
        guard let oldest = MetricsRepository.oldestMeasurementTimestamp(context: modelContext) else { return nil }
        return Date().timeIntervalSince(oldest) / 86_400
    }

    // MARK: - Always kept

    private var alwaysKeptGroup: some View {
        SettingsGroup(header: "Always kept") {
            FormField {
                VStack(alignment: .leading, spacing: 8) {
                    keptLine("Daily summaries: steps, calories, distance and each night's sleep and stages")
                    keptLine("Daily lowest, average and highest for every vital")
                    keptLine("Your workouts and routes")
                    keptLine("Your profile, goals and coach conversations")
                    keptLine("Anything not yet backed up to Agara Cloud")
                }
            }
        }
    }

    private func keptLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(AgaraFont.footnote).foregroundStyle(AgaraColors.success)
            Text(text).font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsGroup: some View {
        SettingsGroup(
            header: "Diagnostics",
            footer: "Keeps the last \(AgaraConfig.Storage.rawPacketsWindowHours) hours of Bluetooth packets (up to "
                + "\(AgaraConfig.Storage.rawPacketsMaxRows.formatted()) packets), \(center.usage.map { Self.size($0.bytes(.diagnostics)) } ?? "—") "
                + "of diagnostics in all. They encode your health readings, so capture stays off unless support asked for it."
        ) {
            FormToggleRow(title: "Capture Bluetooth diagnostics", isOn: Binding(
                get: { captureRawPackets },
                set: { captureRawPackets = $0; RawPacketCapture.userOptedIn = $0 }
            ))
            Button {
                confirm = .clearRawData { clearRawData() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash").font(AgaraFont.body).foregroundStyle(AgaraColors.danger).frame(width: 24)
                    Text("Clear raw data").font(AgaraFont.body).foregroundStyle(AgaraColors.danger)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clearRawData")
        }
    }

    private func clearRawData() {
        try? modelContext.delete(model: RawPacketRecord.self)
        try? modelContext.delete(model: RawPacketRow.self)
        try? modelContext.save()
        Task { await center.refreshUsage() }
    }

    // MARK: - Optimize

    private var optimizeGroup: some View {
        SettingsGroup(header: "Maintenance", footer: optimizeFooter) {
            if let job = progress.job {
                FormField {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(job.title).font(AgaraFont.body).foregroundStyle(AgaraColors.textPrimary)
                            Spacer()
                            Text("\(Int((job.fraction * 100).rounded()))%").font(AgaraFont.body.monospacedDigit()).foregroundStyle(AgaraColors.textSecondary)
                        }
                        ProgressView(value: job.fraction).tint(AgaraColors.accent)
                        Text(job.detail).font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                    }
                }
            }
            Button {
                center.optimizeNow()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(AgaraFont.body).foregroundStyle(center.canOptimize ? AgaraColors.accent : AgaraColors.textMuted).frame(width: 24)
                    Text("Optimize now").font(AgaraFont.body).foregroundStyle(center.canOptimize ? AgaraColors.textPrimary : AgaraColors.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!center.canOptimize)
            .accessibilityIdentifier("optimizeNow")
        }
    }

    private var optimizeFooter: String {
        var parts = ["Compacts older readings, clears old logs and caches, and gives free space back. It never blocks your ring from syncing."]
        if let last = center.lastRunAt { parts.append("Last run \(last.formatted(.relative(presentation: .named)))." ) }
        if !center.canOptimize && !center.isRunning { parts.append("Unavailable while your phone is low on space or the battery is under 20% and not charging.") }
        return parts.joined(separator: " ")
    }
}

/// One usage row: the icon tile, the label and the size.
private struct UsageRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    var muted = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: symbol, style: .tinted(tint), size: .small)
            Text(title).font(AgaraFont.body).foregroundStyle(muted ? AgaraColors.textMuted : AgaraColors.textPrimary)
                .lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Text(value).font(AgaraFont.body.monospacedDigit()).foregroundStyle(AgaraColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }
}

/// One stacked bar: a segment per class in proportion to its bytes; when a limit is set the bar spans the limit (or the
/// usage, if that is larger) so the empty tail reads as headroom.
private struct UsageBar: View {
    let usage: StorageUsage?
    let cap: Int64?

    var body: some View {
        GeometryReader { geo in
            let total = max(usage?.usedBytes ?? 0, cap ?? 0, 1)
            HStack(spacing: 1) {
                if let usage {
                    ForEach(StorageSettingsView.orderedClasses) { c in
                        let b = usage.bytes(c)
                        if b > 0 {
                            Rectangle()
                                .fill(StorageSettingsView.tint(c))
                                .frame(width: max(2, geo.size.width * CGFloat(b) / CGFloat(total)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(AgaraColors.cardSoft)
            .clipShape(Capsule())
        }
        .accessibilityElement()
        .accessibilityLabel(usage.map { "Storage used: \(StorageSettingsView.size($0.usedBytes))" } ?? "Measuring storage")
    }
}

extension StorageSettingsView {
    fileprivate static var orderedClasses: [StorageClass] { classOrder }
}
