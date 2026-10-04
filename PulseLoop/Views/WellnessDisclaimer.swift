import SwiftUI

/// The one-time wellness disclaimer (store launch, phase 1 item 2; Apple 1.4.1, Play Health Content policy).
/// Shown once per install before onboarding starts (so before pairing); re-shown read-only from About › Legal.
/// Copy is `brand.yaml` (`wellness_disclaimer_*`), so it is the same text on both apps.
enum WellnessDisclaimer {
    /// UserDefaults key: the user tapped "I understand". New key, not install-bound.
    static let acceptedKey = "agara.wellnessDisclaimerAccepted"

    static func isAccepted(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: acceptedKey) }
    static func accept(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: acceptedKey) }

    /// Test tooling (`-acceptDisclaimer YES`, debug builds only) so UI tests and screenshot runs skip the screen.
    static var launchArgumentAccepts: Bool { DebugLaunch.bool("acceptDisclaimer") }
}

/// Full-screen acknowledgement. `onAccept == nil` shows it read-only (About › Legal) with a Close button instead.
struct WellnessDisclaimerView: View {
    var onAccept: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(AgaraColors.accent)
                        .padding(.top, 40)
                        .accessibilityHidden(true)
                    Text(AgaraCopy.wellnessDisclaimerTitle)
                        .font(AgaraFont.title2.weight(.bold))
                        .foregroundStyle(AgaraColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("disclaimer.title")
                    Text(AgaraCopy.wellnessDisclaimerBody)
                        .font(AgaraFont.body)
                        .foregroundStyle(AgaraColors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("disclaimer.body")
                    LegalLinkRow()
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 0) {
                if let onAccept {
                    PrimaryButton(title: AgaraCopy.wellnessDisclaimerAccept, systemImage: "checkmark", action: onAccept)
                        .accessibilityIdentifier("disclaimer.accept")
                } else if let onClose {
                    PrimaryButton(title: "Close", systemImage: "xmark", action: onClose)
                        .accessibilityIdentifier("disclaimer.close")
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(AgaraColors.background.ignoresSafeArea())
    }
}

// MARK: - Legal links (privacy, terms, support) — brand.yaml `*_url`; a row hides when its URL is empty

enum LegalLinks {
    static var all: [AboutSettingsView.AboutLink] {
        [
            AboutSettingsView.link("privacy", "Privacy policy", "hand.raised.fill", AgaraCopy.privacyPolicyUrl),
            AboutSettingsView.link("terms", "Terms of use", "doc.text.fill", AgaraCopy.termsUrl),
            AboutSettingsView.link("support", "Support", "questionmark.circle.fill", AgaraCopy.supportUrl),
        ].compactMap { $0 }
    }
}

/// Inline links for the onboarding / disclaimer screens.
struct LegalLinkRow: View {
    var body: some View {
        let links = LegalLinks.all
        if !links.isEmpty {
            HStack(spacing: 18) {
                ForEach(links) { link in
                    Link(link.label, destination: link.url)
                        .font(AgaraFont.footnote.weight(.semibold))
                        .foregroundStyle(AgaraColors.accent)
                        .accessibilityIdentifier("legal.\(link.id)")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}

/// Settings group with the legal rows (About, Settings › Privacy). Empty catalog URLs hide their rows; the group hides
/// when none are left. `showsDisclaimer` adds the row that re-opens the wellness disclaimer (About › Legal).
struct LegalSettingsGroup: View {
    var showsDisclaimer = false
    @State private var showingDisclaimer = false

    var body: some View {
        let links = LegalLinks.all
        if !links.isEmpty || showsDisclaimer {
            SettingsGroup(header: "Legal") {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        HStack(spacing: 12) {
                            Image(systemName: link.systemImage)
                                .foregroundStyle(AgaraColors.accent)
                                .frame(width: 24)
                            Text(link.label)
                                .font(AgaraFont.body)
                                .foregroundStyle(AgaraColors.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(AgaraFont.caption2.weight(.semibold))
                                .foregroundStyle(AgaraColors.textMuted)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("legal.\(link.id)")
                }
                if showsDisclaimer {
                    Button { showingDisclaimer = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.text.square.fill")
                                .foregroundStyle(AgaraColors.accent)
                                .frame(width: 24)
                            Text(AgaraCopy.wellnessDisclaimerTitle)
                                .font(AgaraFont.body)
                                .foregroundStyle(AgaraColors.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(AgaraFont.footnote.weight(.semibold))
                                .foregroundStyle(AgaraColors.textMuted)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("legal.disclaimer")
                }
            }
            .sheet(isPresented: $showingDisclaimer) {
                WellnessDisclaimerView(onClose: { showingDisclaimer = false })
                    .agaraRingEnvironment()
            }
        }
    }
}
