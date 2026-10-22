import SwiftUI

/// Wearable › Firmware row with the update check (flag `firmwareCheck`): "00.12.07 · Up to date",
/// "Update available · 00.12.10" (tap → release sheet), a "Check" button, and — with `firmwareDownload` —
/// "Ready to install · 00.12.10" once the file is downloaded and verified. No ring writes.
struct FirmwareRow: View {
    let installed: String
    let identity: FirmwareIdentity?
    let checker: FirmwareUpdateChecker
    @State private var showsRelease = false

    private var summary: String {
        switch checker.status {
        case .unknown: return installed
        case .checking: return "\(installed) · Checking…"
        case .upToDate: return "\(installed) · Up to date"
        case let .available(release): return "Update available · \(release.version)"
        case let .downloading(release): return "Downloading \(release.version)…"
        case let .ready(release): return "Ready to install · \(release.version)"
        case .error:
            if let release = checker.latestRelease { return "Update available · \(release.version)" }
            return "\(installed) · Couldn't check"
        }
    }

    private var hasRelease: Bool { checker.latestRelease != nil }

    private var canCheck: Bool {
        guard identity != nil else { return false }
        switch checker.status {
        case .checking, .downloading: return false
        default: return true
        }
    }

    var body: some View {
        FormValueRow(title: "Firmware") {
            HStack(spacing: 10) {
                if hasRelease {
                    Button { showsRelease = true } label: {
                        HStack(spacing: 4) {
                            Text(summary).foregroundStyle(AgaraColors.accent)
                            Image(systemName: "chevron.right").font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the release notes")
                } else {
                    Text(summary).foregroundStyle(AgaraColors.textMuted)
                }
                if canCheck, !hasRelease {
                    Button("Check") {
                        guard let identity else { return }
                        Task { await checker.check(identity) }
                    }
                    .font(AgaraFont.body.weight(.semibold))
                    .foregroundStyle(AgaraColors.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Check for firmware update")
                }
            }
            .lineLimit(1)
        }
        .onAppear { if let identity, checker.status == .unknown { checker.restore(identity) } }
        .sheet(isPresented: $showsRelease) {
            FirmwareReleaseSheet(installed: installed, identity: identity, checker: checker)
                .agaraRingEnvironment()
        }
    }
}

/// Release notes and size for the newer firmware; the Download action and its result when
/// `firmwareDownload` is on; once Ready, the Install section (debug builds with `firmwareInstall` on).
struct FirmwareReleaseSheet: View {
    let installed: String
    let identity: FirmwareIdentity?
    let checker: FirmwareUpdateChecker
    @Environment(\.dismiss) private var dismiss
    @State private var features = AgaraFeatureStore.shared
    @State private var installer = FirmwareInstallController.shared

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let release = checker.latestRelease {
                        SettingsGroup(header: "Firmware \(release.version)") {
                            FormValueRow(title: "Installed") { Text(installed).foregroundStyle(AgaraColors.textMuted) }
                            FormValueRow(title: "Size") {
                                Text(Self.sizeFormatter.string(fromByteCount: release.size)).foregroundStyle(AgaraColors.textMuted)
                            }
                        }
                        SettingsGroup(header: "What's new") {
                            FormField {
                                Text(release.notes.isEmpty ? "No release notes." : release.notes)
                                    .font(AgaraFont.body)
                                    .foregroundStyle(AgaraColors.textPrimary)
                                    .textSelection(.enabled)
                            }
                        }
                        if features.isOn(.firmwareDownload) { downloadSection }
                    } else {
                        Text("Your ring's firmware is up to date.")
                            .font(AgaraFont.body)
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                }
                .padding(20)
            }
            .background(AgaraColors.background.ignoresSafeArea())
            .navigationTitle("Firmware update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var downloadSection: some View {
        switch checker.status {
        case .available:
            PrimaryButton(title: "Download", systemImage: "arrow.down.circle") { Task { await checker.download() } }
        case .downloading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Downloading…").foregroundStyle(AgaraColors.textMuted)
            }
        case let .ready(release):
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Ready to install · on the ring's charger, battery ≥ \(AgaraConfig.Ring.firmwareMinBatteryPercent) %",
                    systemImage: "checkmark.seal.fill"
                )
                .font(AgaraFont.body)
                .foregroundStyle(AgaraColors.success)
                if installer.enabled {
                    FirmwareInstallSection(version: release.version) {
                        // Close the sheet first: the full-screen progress is presented from the app root.
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            installer.start()
                        }
                    }
                }
            }
        case let .error(message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textMuted)
                SecondaryButton(title: "Download", systemImage: "arrow.down.circle") { Task { await checker.download() } }
            }
        default:
            EmptyView()
        }
    }
}
