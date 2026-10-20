import SwiftUI

/// The Coach tab's non-`.ready` screen: one glass card that says what is blocking the coach and what the user can do
/// about it. The same card renders every blocked state, so the tab never grows a second visual language, and the two
/// buttons are the only actions a state can offer — a fix (sign in, verify, agree, turn on) and the free way out
/// (the on-device coach).
struct CoachStateCard: View {
    let state: CoachTabState
    /// The quota state's sentence, built by `CoachQuotaStore` because it carries the reset time.
    var quotaBody: String = CoachCopy.quotaUnknownReset
    /// The fix: sign in, verify, agree, turn the coach on, try again.
    let primary: (title: String, action: () -> Void)?
    /// The free way out — on-device, or Settings for the states that have no other action.
    let secondary: (title: String, action: () -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(state.offersOnDevice ? AgaraColors.accent.opacity(0.16) : AgaraColors.cardSoft)
                        .frame(width: 64, height: 64)
                    Image(systemName: icon)
                        .font(AgaraFont.face(26, .semibold))
                        .foregroundStyle(iconTint)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(state.title)
                        .font(AgaraFont.title3.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(state.body(quotaBody: quotaBody))
                        .font(AgaraFont.subheadline.weight(.regular))
                        .foregroundStyle(AgaraColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    if let primary {
                        Button(action: primary.action) {
                            Text(primary.title)
                                .font(AgaraFont.subheadline.weight(.semibold))
                                .foregroundStyle(AgaraColors.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(AgaraColors.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("coach.state.primary")
                    }
                    if let secondary {
                        Button(action: secondary.action) {
                            Text(secondary.title)
                                .font(AgaraFont.subheadline.weight(.medium))
                                .foregroundStyle(AgaraColors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("coach.state.secondary")
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .padding(.top, 12)
            .agaraGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(AgaraColors.background)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.state.\(state.id)")
    }

    private var icon: String {
        switch state {
        case .coachOff: return "sparkles.slash"
        case .signedOut: return "person.crop.circle.badge.questionmark"
        case .emailUnverified: return "envelope.badge"
        case .consentRequired: return "hand.raised.fill"
        case .busy: return "hourglass"
        case .outOfQuota: return "clock.badge.checkmark"
        case .ready: return "sparkles"
        }
    }

    private var iconTint: Color {
        switch state {
        case .outOfQuota, .busy: return AgaraColors.textSecondary
        case .emailUnverified: return AgaraColors.warning
        default: return AgaraColors.accent
        }
    }
}
