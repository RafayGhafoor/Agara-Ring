import SwiftUI

/// Confirm/Cancel card for a `PendingAction` the coach proposed but hasn't run.
/// Tapping Confirm executes the real mutation; Cancel dismisses it.
struct CoachActionCardView: View {
    let action: PendingAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var isDestructive: Bool { action.kind == .deleteActivitySession }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(AgaraFont.caption.weight(.regular))
                    .foregroundStyle(isDestructive ? AgaraColors.danger : AgaraColors.warning)
                Text("Confirm action")
                    .font(AgaraFont.micro.weight(.semibold)).tracking(1.0)
                    .foregroundStyle(AgaraColors.textMuted)
            }
            Text(action.summary)
                .font(AgaraFont.footnote.weight(.regular))
                .foregroundStyle(AgaraColors.textPrimary)

            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(AgaraFont.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(AgaraColors.textPrimary)
                        // Solid tile, not glass: this button sits inside the card's own glass,
                        // and glass can't sample glass (renders flat). A subtle white sheen +
                        // hairline mirrors the Settings icon tile.
                        .background(
                            LinearGradient(
                                colors: [AgaraColors.textPrimary.opacity(0.16), AgaraColors.textPrimary.opacity(0.07)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            in: Capsule()
                        )
                        .overlay(Capsule().strokeBorder(AgaraColors.textPrimary.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Button(action: onConfirm) {
                    Text(action.confirmLabel)
                        .font(AgaraFont.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(AgaraColors.textPrimary)
                        // Solid accent/danger fill (not tinted glass): keeps the destructive
                        // affordance visible while avoiding glass-inside-glass flattening.
                        .background(isDestructive ? AgaraColors.danger : AgaraColors.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous),
                    tint: isDestructive ? AgaraColors.danger : AgaraColors.warning)
    }
}
