import SwiftUI

// Health-information citations (App Review 1.4.1, 2026-10-20). The list itself is generated from
// `docs/strings/sources.yaml` into `AgaraSources` (Generated/AgaraCopy.swift) — same list and order as Android.
// Three surfaces show it, all built from the pieces below so they look and behave alike (AGENTS Rule 10):
// * `HealthSourcesView` — the full screen (route `AppRoute.healthSources`), reached from the Vitals footer,
//   Settings › Resources and Settings › About;
// * `HealthSourcesFooter` — the "Where these ranges come from" card at the bottom of a metric's detail screen
//   and the Sleep tab, with an "All sources" link to the full screen;
// * `HealthSourcesLinkCard` — the one-row "Sources & references" card at the bottom of the Vitals list.

/// Maps app screens to `AgaraSources` sections and gives each section its on-screen heading.
enum HealthSources {
    static let sleepSection = "sleep"

    /// The citation section behind a metric's ranges and labels, or nil when the metric has none
    /// (estimated or flag-off metrics show no interpretation in the store build).
    static func section(for metric: MetricKind) -> String? {
        switch metric {
        case .heartRate: return "heart_rate"
        case .spo2: return "spo2"
        case .hrv: return "hrv"
        case .stress: return "stress"
        default: return nil
        }
    }

    /// Section heading: the metric's own title (`MetricKind.title`), "Sleep" for sleep.
    static func title(for section: String) -> String {
        switch section {
        case "heart_rate": return MetricKind.heartRate.title
        case "spo2": return MetricKind.spo2.title
        case "hrv": return MetricKind.hrv.title
        case "stress": return MetricKind.stress.title
        case sleepSection: return "Sleep"
        default: return section
        }
    }

    static func url(_ source: AgaraSources.Source) -> URL? { URL(string: source.url) }
}

// MARK: - Full screen

/// Every source, grouped by metric. `section` scrolls straight to one group (from a metric's "All sources").
struct HealthSourcesView: View {
    var section: String? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(AgaraCopy.sourcesIntro)
                        .font(AgaraFont.footnote)
                        .foregroundStyle(AgaraColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("sources.intro")
                    ForEach(AgaraSources.sections, id: \.self) { section in
                        SettingsGroup(header: HealthSources.title(for: section)) {
                            ForEach(AgaraSources.forSection(section)) { source in
                                HealthSourceRow(source: source, showsSupports: true)
                                    .accessibilityIdentifier("sources.row.\(source.id)")
                            }
                        }
                        .id(section)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("sources.section.\(section)")
                    }
                }
                .padding()
                .padding(.bottom, 24)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sources.screen")
            }
            .onAppear {
                guard let section, AgaraSources.sections.contains(section) else { return }
                // After the first layout pass, or the target has no frame yet.
                DispatchQueue.main.async { proxy.scrollTo(section, anchor: .top) }
            }
        }
        .background(AgaraColors.background)
        .pageChrome(AgaraCopy.sourcesTitle)
    }
}

/// One citation: title (wraps), publisher, optionally what it supports; the whole row opens the source.
struct HealthSourceRow: View {
    let source: AgaraSources.Source
    var showsSupports = false

    var body: some View {
        if let url = HealthSources.url(source) {
            Link(destination: url) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.title)
                            .font(AgaraFont.body)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(source.publisher)
                            .font(AgaraFont.caption)
                            .foregroundStyle(AgaraColors.textMuted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if showsSupports {
                            Text(source.supports)
                                .font(AgaraFont.footnote)
                                .foregroundStyle(AgaraColors.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 3)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(AgaraFont.caption2.weight(.semibold))
                        .foregroundStyle(AgaraColors.textMuted)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityHint("Opens the source in your browser.")
        }
    }
}

// MARK: - Footer on metric / sleep screens

/// "Where these ranges come from": the section's sources (title + publisher, each a link) and "All sources".
struct HealthSourcesFooter: View {
    let section: String
    /// Identifier of the "All sources" link: `metric.sources` on metric details, `sleep.sources` on Sleep.
    var allSourcesIdentifier = "metric.sources"

    var body: some View {
        let sources = AgaraSources.forSection(section)
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgaraCopy.sourcesMetricFooter.uppercased())
                    .font(AgaraFont.caption2.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(AgaraColors.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                ForEach(sources) { source in
                    HealthSourceRow(source: source)
                        .accessibilityIdentifier("sources.footer.\(source.id)")
                }
                Divider().overlay(AgaraColors.borderSubtle).padding(.leading, 16)
                NavigationLink(value: AppRoute.healthSources(section)) {
                    HStack {
                        Text("All sources")
                            .font(AgaraFont.subheadline.weight(.semibold))
                            .foregroundStyle(AgaraColors.accent)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(AgaraFont.footnote.weight(.semibold))
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(allSourcesIdentifier)
                .accessibilityHint("Opens \(AgaraCopy.sourcesTitle)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
        }
    }
}

// MARK: - Vitals list footer

/// The "Sources & references" card at the end of the Vitals list — opens the full screen.
struct HealthSourcesLinkCard: View {
    var body: some View {
        NavigationLink(value: AppRoute.healthSources(nil)) {
            HStack(spacing: 14) {
                IconTile(systemName: "book.closed", style: .accent, size: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgaraCopy.sourcesTitle)
                        .font(AgaraFont.body.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text(AgaraCopy.sourcesMetricFooter)
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(AgaraFont.footnote.weight(.semibold))
                    .foregroundStyle(AgaraColors.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .agaraGlass(RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("vitals.sources")
    }
}
