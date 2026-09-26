import SwiftUI

/// The in-app sync indicator under the app header: the sweeping bar, and — once the day loop reports — which
/// day is being read and what has come down so far ("Syncing day 3 of 8 · 4,210 steps"). Reads the one
/// sync-progress model (`SyncProgress`); the bar alone shows while the handshake runs before the first day.
struct SyncStatusHeader: View {
    @State private var progress = SyncProgress.shared

    var body: some View {
        VStack(spacing: 4) {
            SyncProgressBar()
            if progress.isSyncing, progress.totalDays > 0 {
                Text("Syncing \(progress.progressSummary.prefix(1).lowercased())\(progress.progressSummary.dropFirst())")
                    .font(AgaraFont.caption2)
                    .foregroundStyle(AgaraColors.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("sync.status")
            }
        }
    }
}
