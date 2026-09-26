import SwiftUI

/// About (consistency framework phase 5): a hero (the AGARA wordmark, product name, tagline), the real version from the bundle
/// ("1.0.0 (1)" — tap it 7× to unlock Developer), the brand description, an icon row for the social links (tinted squares with captions) and a
/// contact row (email, phone), then the licences as small secondary text behind a "Licences" row and a small
/// upstream credit. All copy and links come from `docs/strings/brand.yaml` (`AgaraCopy`); an empty link hides
/// its icon.
struct AboutSettingsView: View {
    @Binding var path: NavigationPath
    /// Persisted developer unlock, surfaced as the Settings "Developer" row.
    @AppStorage("developerUnlocked") private var developerUnlocked = false
    @State private var versionTapCount = 0
    @State private var lastVersionTap: Date?
    @State private var toast: String?
    @State private var toastToken = 0
    @State private var showsLicences = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Android-style: 7 quick taps on the version unlock Developer options.
    private let developerTapThreshold = 7

    /// 0…1 progress toward unlock, used to build an accent tint as taps accumulate.
    private var tapProgress: Double {
        guard !developerUnlocked else { return 0 }
        return Double(min(versionTapCount, developerTapThreshold - 1)) / Double(developerTapThreshold - 1)
    }

    private let repoURL = URL(string: "https://github.com/saksham2001/PulseLoopiOS")!

    /// "1.0.0 (1)", read from the bundle so it can't drift from the shipped build.
    static var appVersionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// One social/contact link; nil when the catalog value is empty (the row then hides it).
    struct AboutLink: Identifiable {
        let id: String
        let label: String
        let systemImage: String
        let url: URL
    }

    static func link(_ id: String, _ label: String, _ systemImage: String, _ raw: String) -> AboutLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return AboutLink(id: id, label: label, systemImage: systemImage, url: url)
    }

    static var socialLinks: [AboutLink] {
        [
            link("website", "Website", "globe", AgaraCopy.socialWebsiteUrl),
            link("instagram", "Instagram", "camera", AgaraCopy.socialInstagramUrl),
            link("telegram", "Telegram", "paperplane.fill", AgaraCopy.socialTelegramUrl),
        ].compactMap { $0 }
    }

    /// `tel:` URL from the displayed number: "(213) 286-1434" → `tel:+12132861434` (NANP numbers get +1).
    static func telURL(_ display: String) -> URL? {
        let digits = display.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        let e164 = digits.count == 10 ? "+1" + digits : (display.hasPrefix("+") ? "+" + digits : digits)
        return URL(string: "tel:" + e164)
    }

    static var contactLinks: [AboutLink] {
        var links: [AboutLink] = []
        let email = AgaraCopy.supportEmail.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, let url = URL(string: "mailto:" + email) {
            links.append(AboutLink(id: "email", label: email, systemImage: "envelope.fill", url: url))
        }
        if let url = telURL(AgaraCopy.supportPhone) {
            links.append(AboutLink(id: "phone", label: AgaraCopy.supportPhone, systemImage: "phone.fill", url: url))
        }
        return links
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                SettingsGroup(footer: AgaraCopy.aboutDescription) {
                    Button(action: registerVersionTap) {
                        FormValueRow(title: "Version") {
                            Text(Self.appVersionLabel).foregroundStyle(AgaraColors.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(VersionRowButtonStyle())
                    .background(AgaraColors.accent.opacity(tapProgress * 0.18))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: versionTapCount)
                    .accessibilityIdentifier("about.version")
                    .accessibilityHint("Tap repeatedly to unlock developer options.")
                    .sensoryFeedback(trigger: versionTapCount) { _, count in
                        guard count > 0 else { return nil }
                        if count >= developerTapThreshold { return .success }
                        return count > 3 ? .impact(weight: .medium) : .impact(weight: .light)
                    }
                }
                if !Self.socialLinks.isEmpty {
                    // Accent-soft rounded squares with the accent glyph and a caption (polish spec item 1).
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(Self.socialLinks) { link in
                            Link(destination: link.url) {
                                VStack(spacing: 6) {
                                    IconTile(systemName: link.systemImage, style: .accent, size: .hero)
                                    Text(link.label)
                                        .font(AgaraFont.caption)
                                        .foregroundStyle(AgaraColors.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(link.label)
                            .accessibilityAddTraits(.isLink)
                            .accessibilityIdentifier("about.social.\(link.id)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if !Self.contactLinks.isEmpty {
                    SettingsGroup(header: "Contact") {
                        ForEach(Self.contactLinks) { link in
                            Link(destination: link.url) {
                                HStack(spacing: 12) {
                                    Image(systemName: link.systemImage)
                                        .foregroundStyle(AgaraColors.accent)
                                        .frame(width: 24)
                                    Text(link.label)
                                        .font(AgaraFont.body)
                                        .foregroundStyle(AgaraColors.textPrimary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("about.contact.\(link.id)")
                        }
                    }
                }
                SettingsGroup {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { showsLicences.toggle() } } label: {
                        HStack {
                            Text("Licences").font(AgaraFont.body).foregroundStyle(AgaraColors.textPrimary)
                            Spacer()
                            Image(systemName: showsLicences ? "chevron.up" : "chevron.down")
                                .font(AgaraFont.footnote.weight(.semibold))
                                .foregroundStyle(AgaraColors.textMuted)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("about.licences")
                    if showsLicences {
                        FormField {
                            Text("Based on PulseLoop by Saksham Bhutani, licensed under Creative Commons Attribution 4.0 International (CC BY 4.0) — free to share and adapt, including commercially, with appropriate credit. Fonts: Manrope (SIL Open Font License 1.1).")
                                .font(AgaraFont.caption)
                                .foregroundStyle(AgaraColors.textSecondary)
                        }
                    }
                }
                linkCard(icon: "arrow.up.right", title: "Built on PulseLoop", subtitle: "GitHub", url: repoURL)
            }
            .padding()
        }
        .background(AgaraColors.background)
        .pageChrome("About")
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .agaraGlass(Capsule())
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            // The same wordmark as the app header (dark type on light themes, white on dark ones), like Android.
            Image(ThemeStore.current.isLight ? "agara-wordmark-dark" : "agara-wordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 22)
                .padding(.top, 28)
                .padding(.bottom, 30)
                .accessibilityHidden(true)
                .accessibilityIdentifier("about.wordmark")
            Text(AgaraCopy.aboutProductName)
                .font(AgaraFont.title2.weight(.bold))
                .foregroundStyle(AgaraColors.textPrimary)
            Text(AgaraCopy.aboutTagline)
                .font(AgaraFont.subheadline)
                .foregroundStyle(AgaraColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("about.hero")
    }

    // MARK: - Developer unlock (tap the version 7×, Android-style)

    private func registerVersionTap() {
        let now = Date()
        if let last = lastVersionTap, now.timeIntervalSince(last) > 2 { versionTapCount = 0 }
        lastVersionTap = now

        guard !developerUnlocked else {
            showToast("Developer options are already enabled.")
            return
        }

        versionTapCount += 1
        let remaining = developerTapThreshold - versionTapCount
        if remaining <= 0 {
            // Leave versionTapCount at the threshold so the trigger observes it (success haptic +
            // final bounce); the `developerUnlocked` guard stops any further counting.
            developerUnlocked = true
            showToast("You are now a developer!")
            path.append(AppRoute.debug)
        } else if remaining <= 3 {
            showToast("You're \(remaining) step\(remaining == 1 ? "" : "s") away from Developer options.")
        }
    }

    private func showToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token { toast = nil }
        }
    }

    private func linkCard(icon: String, title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            FormField {
                HStack(spacing: 8) {
                    // Deliberately understated: this row credits the upstream project and offers a
                    // community link. It is attribution, not a feature, so it reads as a footnote —
                    // no icon tile, smaller type, muted tint.
                    Image(systemName: "arrow.up.right")
                        .font(AgaraFont.caption2.weight(.semibold))
                        .foregroundStyle(AgaraColors.textMuted)
                    Text(title).font(AgaraFont.footnote.weight(.regular)).foregroundStyle(AgaraColors.textSecondary)
                    Spacer(minLength: 8)
                    Text(subtitle).font(AgaraFont.caption2.weight(.regular)).foregroundStyle(AgaraColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Press feedback for the version row: dims briefly while held, marking it as tappable.
private struct VersionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
