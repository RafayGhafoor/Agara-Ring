import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// Settings › Data & Export (consistency framework phase 5): everything that moves data in or out of the app,
/// in one place instead of inside Privacy.
///   • Backup — export the full dataset to a compressed JSON file (`.json.gz`, optionally with diagnostics), or
///     import one (replace-all, confirmed).
///   • Diagnostics — export a diagnostics bundle; opt in to Bluetooth capture; clear captured packets.
///   • Demo data — clear or reseed sample data, only behind the `demo_data` flag (off in release).
/// Privacy (unpair/reset) keeps its own screen, `PrivacySettingsView`.
struct DataExportSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    /// The navigation stack, to open Storage.
    @Binding var path: NavigationPath
    @State private var diagnosticsURL: URL?
    /// Mirrors `RawPacketCapture.userOptedIn` so the toggle re-renders; the defaults key is the truth.
    @State private var captureRawPackets = RawPacketCapture.userOptedIn

    /// The destructive action awaiting confirmation (clear, import-replace) — `ConfirmAction`.
    @State private var confirm: ConfirmAction?
    @State private var features = AgaraFeatureStore.shared

    // Backup (full export/import) state.
    @State private var exportURL: URL?
    /// Include diagnostics (captured raw BLE packets) in the backup — Android's "include diagnostics"; off by default.
    @State private var exportIncludesPackets = false
    @State private var showImporter = false
    /// Non-nil while an export/import runs; the label shown under the blocking spinner.
    @State private var workingLabel: String?
    @State private var backupError: String?
    @State private var showImportSuccess = false

    /// The destructive clears in Diagnostics / Demo data — each confirmed first (audit batch B).
    enum ClearAction: Equatable {
        case capturedPackets, demoData, reseedDemo

        var title: String {
            switch self {
            case .capturedPackets: return "Clear captured packets?"
            case .demoData: return "Clear demo data?"
            case .reseedDemo: return "Replace data with demo data?"
            }
        }

        var message: String {
            switch self {
            case .capturedPackets:
                return "The Bluetooth packets captured for diagnostics are deleted. Your health data stays."
            case .demoData:
                return "Everything stored in the app is deleted — demo and ring data alike. This can't be undone."
            case .reseedDemo:
                return "Everything stored in the app is deleted and replaced with sample data. This can't be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .capturedPackets, .demoData: return "Clear"
            case .reseedDemo: return "Replace"
            }
        }
    }

    private func ask(_ action: ClearAction) {
        // Demo data copy comes from brand.yaml (both apps); the packet clear is iOS-only diagnostics.
        switch action {
        case .demoData: confirm = .clearDemo { performClear(action) }
        case .reseedDemo: confirm = .reseedDemo { performClear(action) }
        case .capturedPackets:
            confirm = ConfirmAction(key: "clear.\(action)", title: action.title, message: action.message,
                                    confirmLabel: action.confirmLabel) { performClear(action) }
        }
    }

    private func performClear(_ action: ClearAction) {
        switch action {
        case .capturedPackets:
            DebugRepository.pruneRawPackets(maxRows: 0, context: modelContext)
            try? modelContext.save()
        case .demoData:
            SeedData.clearAll(modelContext)
            let fresh = UserProfile()
            fresh.onboardingCompleted = true
            fresh.baselineCompleted = true
            modelContext.insert(fresh)
            try? modelContext.save()
        case .reseedDemo:
            SeedData.clearAll(modelContext)
            SeedData.seedDemo(modelContext, completeOnboarding: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(
                    header: "Backup",
                    footer: "Export everything — metrics, sleep, workouts, coach history, meals, settings — to a "
                        + "compressed JSON file (.json.gz) you can save, AirDrop, analyze, or import on Android. "
                        + "Importing a backup replaces all data in the app. API keys are never included."
                ) {
                    actionRow("Export all data", systemImage: "square.and.arrow.up.on.square") {
                        exportAllData()
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(AgaraFont.body)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .frame(width: 24)
                        Toggle(isOn: $exportIncludesPackets) {
                            Text("Include diagnostics")
                                .font(AgaraFont.body)
                                .foregroundStyle(AgaraColors.textPrimary)
                        }
                        .tint(AgaraColors.accent)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    actionRow("Import data…", systemImage: "square.and.arrow.down") {
                        showImporter = true
                    }
                }

                if features.isOn(.storageSettings) {
                    SettingsGroup(
                        header: "Storage",
                        footer: "What the app keeps on this phone, your storage limit, and Bluetooth diagnostics."
                    ) {
                        actionRow("Storage", systemImage: "internaldrive") { path.append(AppRoute.settingsStorage) }
                            .accessibilityIdentifier("openStorage")
                    }
                }

                SettingsGroup(
                    header: "Diagnostics",
                    footer: features.isOn(.storageSettings)
                        ? "A local snapshot for troubleshooting — nothing leaves the device unless you share it. "
                            + "Bluetooth capture and Clear raw data are in Storage."
                        : "A local snapshot for troubleshooting — nothing leaves the device unless you share it. "
                            + "Bluetooth capture stores the raw packets exchanged with your ring (which encode your "
                            + "health readings) and includes them in exports; leave it off unless support asked for it."
                ) {
                    actionRow("Export diagnostics", systemImage: "square.and.arrow.up") {
                        diagnosticsURL = DiagnosticsExporter.exportFile(context: modelContext)
                    }
                    if !features.isOn(.storageSettings) {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(AgaraFont.body)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .frame(width: 24)
                        Toggle(isOn: Binding(
                            get: { captureRawPackets },
                            set: { enabled in
                                captureRawPackets = enabled
                                RawPacketCapture.userOptedIn = enabled
                            }
                        )) {
                            Text("Capture Bluetooth diagnostics")
                                .font(AgaraFont.body)
                                .foregroundStyle(AgaraColors.textPrimary)
                        }
                        .tint(AgaraColors.accent)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    actionRow("Clear captured packets", systemImage: "trash") {
                        ask(ClearAction.capturedPackets)
                    }
                    }
                }

                // Demo data rows only behind the `demo_data` flag (off in release; debug turns it on via the
                // feature-flag override) — consistency plan B.
                if features.isOn(.demoData), StoreCapture.showsDebugChrome {
                    SettingsGroup(
                        header: "Demo data",
                        footer: "Sample data for exploring the app without a ring."
                    ) {
                        actionRow("Clear demo data", systemImage: "trash") {
                            ask(ClearAction.demoData)
                        }
                        actionRow("Reseed demo data", systemImage: "arrow.clockwise") {
                            ask(ClearAction.reseedDemo)
                        }
                    }
                }
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("Data & Export")
        // Blocking overlay while an export/import runs — the work yields regularly, so the
        // spinner stays animated; the screen is disabled underneath.
        .overlay {
            if let workingLabel {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView(workingLabel)
                        .tint(AgaraColors.accent)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .disabled(workingLabel != nil)
        .confirmAction($confirm)
        .sheet(item: $diagnosticsURL) { url in
            DiagnosticsShareSheet(items: [url])
                .agaraRingEnvironment()
        }
        .sheet(item: $exportURL) { url in
            DiagnosticsShareSheet(items: [url])
                .agaraRingEnvironment()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .gzip, .data]) { result in
            guard case let .success(url) = result else { return }
            if DataArchiveService.hasAnyData(context: modelContext) {
                confirm = .replaceAllData { importData(from: url) }   // destructive — confirm first
            } else {
                importData(from: url)
            }
        }
        .alert("Couldn't complete", isPresented: Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupError ?? "")
        }
        .alert("Import complete", isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your data has been restored from the backup.")
        }
    }

    // MARK: - Rows

    /// A flat, full-width settings row (icon + title) that runs `action`. No inner capsule — it sits
    /// directly inside `SettingsGroup`, which supplies the grouped glass surface + hairline dividers,
    /// so it matches the app's other grouped rows. `tint` colors both icon and title (danger for the
    /// destructive App-data actions).
    private func actionRow(
        _ title: String,
        systemImage: String,
        tint: Color = AgaraColors.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(AgaraFont.body)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(AgaraFont.body)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Backup actions

    private func exportAllData() {
        workingLabel = "Exporting…"
        Task {
            defer { workingLabel = nil }
            do {
                exportURL = try await DataArchiveService.exportFile(
                    context: modelContext, includeRawPackets: exportIncludesPackets
                )
            } catch {
                backupError = error.localizedDescription
            }
        }
    }

    private func importData(from url: URL) {
        workingLabel = "Importing…"
        Task {
            defer { workingLabel = nil }
            do {
                // fileImporter URLs are security-scoped; read the bytes immediately, then work
                // from memory.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try await DataArchiveService.importArchive(data, context: modelContext)
                showImportSuccess = true
            } catch {
                backupError = error.localizedDescription
            }
        }
    }
}
