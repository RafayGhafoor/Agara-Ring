import SwiftUI

/// C1's "Breathe 2 min": a two-minute paced breathing session (4 s in, 6 s out). Deliberately **not** a measurement —
/// it starts no ring stream, sends no command and records nothing to the store; the only thing it writes is the ledger
/// entry the sheet's host makes when it closes ("did a breathing session").
///
/// Motion goes through the app's shared animation values (`AgaraMotion`) and respects Reduce Motion: the circle then
/// holds still and the words alone keep the pace, so the session works for someone who asked for less motion.
struct BreathingSessionView: View {
    /// 4 s inhale + 6 s exhale, twelve cycles ~= two minutes.
    private static let inhale: TimeInterval = 4
    private static let exhale: TimeInterval = 6
    private static let cycles = 12

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startedAt = Date()
    @State private var expanded = false
    @State private var finished = false
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    private var total: TimeInterval { (Self.inhale + Self.exhale) * Double(Self.cycles) }
    private var progress: Double { min(1, elapsed / total) }
    private var phase: String { Int(elapsed) % Int(Self.inhale + Self.exhale) < Int(Self.inhale) ? "Breathe in" : "Breathe out" }
    private var remaining: Int { max(0, Int((total - elapsed).rounded(.up))) }

    var body: some View {
        VStack(spacing: 22) {
            Text(finished ? "Well done" : "Two quiet minutes")
                .font(AgaraFont.title)
                .foregroundStyle(AgaraColors.textPrimary)

            ZStack {
                Circle()
                    .fill(AgaraColors.accent.opacity(0.12))
                    .frame(width: 220, height: 220)
                Circle()
                    .fill(AgaraColors.accent.opacity(0.22))
                    .frame(width: 190, height: 190)
                    .scaleEffect(reduceMotion ? 1 : (expanded ? 1.12 : 0.78))
                    .animation(reduceMotion ? nil : .easeInOut(duration: expanded ? Self.inhale : Self.exhale),
                               value: expanded)
                Text(finished ? "Done" : phase)
                    .font(AgaraFont.headline)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .accessibilityIdentifier("breathing.phase")
            }
            .frame(height: 240)
            .accessibilityIdentifier("breathing.session")

            if !finished {
                Text("\(remaining / 60):" + String(format: "%02d", remaining % 60))
                    .font(AgaraFont.subheadline)
                    .foregroundStyle(AgaraColors.textSecondary)
                    .monospacedDigit()
                ProgressView(value: progress)
                    .tint(AgaraColors.accent)
                    .padding(.horizontal, 40)
            } else {
                Text("Your pace is back to normal. Nothing was measured or stored.")
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button(finished ? "Close" : "Finish early") {
                stop()
                dismiss()
            }
            .font(AgaraFont.subheadline.weight(.semibold))
            .foregroundStyle(AgaraColors.accent)
            .accessibilityIdentifier("breathing.close")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(AgaraColors.background.ignoresSafeArea())
        .onAppear { start() }
        .onDisappear { timer?.invalidate() }
    }

    private func start() {
        startedAt = Date()
        expanded = true
        timer?.invalidate()
        // One 0.25 s tick drives the countdown and the phase word; the circle's own animation is what the eye follows.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                elapsed = Date().timeIntervalSince(startedAt)
                let inInhale = Int(elapsed) % Int(Self.inhale + Self.exhale) < Int(Self.inhale)
                expanded = inInhale
                if elapsed >= total {
                    finished = true
                    timer?.invalidate()
                }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
