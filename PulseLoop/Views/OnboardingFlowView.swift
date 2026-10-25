import SwiftUI
import SwiftData

struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @State private var path = OnboardingProgressStore().loadPath()

    let onFinished: () -> Void
    private let progressStore = OnboardingProgressStore()
    private var step: OnboardingStep { path.last ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(
                step: step,
                canGoBack: path.count > 1,
                showsSkip: step == .profile,
                onBack: goBack,
                onSkip: { push(.goals) }
            )

            Group {
                switch step {
                case .welcome:
                    OnboardingWelcomeView(
                        getStarted: { push(.ring) },
                        exploreWithoutRing: {
                            SampleDataStore.shared.markExploring()   // sample data loads when onboarding finishes
                            push(.profile)
                        }
                    )
                case .ring:
                    OnboardingPairView(
                        connected: advanceAfterConnection,
                        skipped: { push(.profile) }
                    )
                case .syncing:
                    OnboardingSyncingView(next: { push(.profile) })
                case .profile:
                    OnboardingProfileView(next: { push(.goals) })
                case .goals:
                    OnboardingGoalsView(next: { push(.coach) })
                case .coach:
                    OnboardingCoachView(next: { push(.baseline) })
                case .baseline:
                    OnboardingBaselineView(finish: finish)
                }
            }
            .id(step)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .animation(.snappy(duration: 0.3), value: step)
        .background(AgaraColors.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
    }

    private func push(_ next: OnboardingStep) {
        guard step != next else { return }
        path.append(next)
        progressStore.savePath(path)
    }

    private func goBack() {
        guard path.count > 1 else { return }
        path.removeLast()
        progressStore.savePath(path)
    }

    /// Called once the pairing screen's "Name your ring" step is saved or skipped. The connected
    /// confirmation was already on screen during that step; next is the Syncing step (history coming down).
    private func advanceAfterConnection() {
        SampleDataStore.shared.clearExploring()   // a real ring is being paired: no sample data
        guard step == .ring else { return }
        push(.syncing)
    }

    private func finish() {
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile(units: ProfileDraft.preferredUnits(for: .current))
            modelContext.insert(profile)
        }
        profile.onboardingCompleted = true
        profile.baselineCompleted = true
        profile.updatedAt = AppClock.now
        try? modelContext.save()
        // "Explore without ring": load the labelled sample set (banner + chips on every tab) now that a profile exists.
        SampleDataStore.shared.activateIfExploring(context: modelContext)
        progressStore.clear()
        onFinished()
    }
}

private struct OnboardingTopBar: View {
    let step: OnboardingStep
    let canGoBack: Bool
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                topBarSlot {
                    if canGoBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(AgaraFont.callout.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Back")
                    }
                }
                Spacer()
                Text("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")
                    .font(AgaraFont.caption.weight(.semibold))
                    .foregroundStyle(AgaraColors.textMuted)
                    .monospacedDigit()
                Spacer()
                topBarSlot {
                    if showsSkip {
                        Button("Skip", action: onSkip)
                            .font(AgaraFont.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
            .foregroundStyle(AgaraColors.textSecondary)

            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item.index <= step.index ? AgaraColors.accent : AgaraColors.cardSoft)
                        .frame(height: 4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Onboarding progress")
            .accessibilityValue("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func topBarSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            content()
        }
        .frame(width: 60, height: 44)
    }
}

/// One icon + title + one-line detail + tint, shared by the Welcome feature tiles and the Baseline
/// timeline. A named struct rather than a 4-tuple (SwiftLint `large_tuple`) — `title` is the identity.
struct OnboardingItem: Identifiable {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    var id: String { title }
}

struct OnboardingWelcomeView: View {
    let getStarted: () -> Void
    let exploreWithoutRing: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let features = [
        OnboardingItem(icon: "dollarsign.circle.fill", title: "No subscription", detail: "Own your ring data", tint: AgaraColors.success),
        OnboardingItem(icon: "lock.shield.fill", title: "Privacy first", detail: "Stays local unless you sync", tint: AgaraColors.info),
        // The AI coach is off in the store release (flag `coach`), so the tile only claims it when it exists.
        AgaraFeatureStore.isOn(.coach)
            ? OnboardingItem(icon: "sparkles", title: "AI coach", detail: "Learns your baseline", tint: AgaraColors.accent)
            : OnboardingItem(icon: "heart.fill", title: "Apple Health", detail: "Optional export", tint: AgaraColors.accent),
        OnboardingItem(icon: "waveform.path.ecg", title: "Your vitals", detail: "HR, SpO₂, HRV, stress", tint: AgaraColors.heartRate),
        OnboardingItem(icon: "moon.stars.fill", title: "Sleep tracking", detail: "Stages & trends", tint: AgaraColors.sleep),
        OnboardingItem(icon: "figure.run", title: "Workouts", detail: "Live activity tracking", tint: AgaraColors.steps),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private let headerSubtitle = AgaraCopy.onboardingSubtitle

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityBody
            } else {
                fittedBody
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter { footer }
        }
    }

    // Fitted, no-scroll layout for standard Dynamic Type sizes.
    private var fittedBody: some View {
        OnboardingFittedBand { s in
            VStack(spacing: 0) {
                logo(size: (78 * s).rounded())

                Spacer().frame(height: (14 * s).rounded())

                FittedOnboardingHeader(title: AgaraCopy.onboardingSetupTitle, subtitle: headerSubtitle, s: s)

                Spacer().frame(height: (16 * s).rounded())

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(features) { feature in
                        tile(feature, s: s)
                    }
                }
            }
        }
    }

    // Accessibility fallback: keep the scrolling body so large type never clips.
    private var accessibilityBody: some View {
        ScrollView {
            VStack(spacing: 18) {
                logo(size: 92)
                CompactOnboardingHeader(title: AgaraCopy.onboardingSetupTitle, subtitle: headerSubtitle)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(features) { feature in
                        VStack(spacing: 8) {
                            tileIcon(feature, s: 1)
                            Text(feature.title)
                                .font(AgaraFont.headline)
                                .foregroundStyle(AgaraColors.textPrimary)
                                .multilineTextAlignment(.center)
                            Text(feature.detail)
                                .font(AgaraFont.footnote.weight(.regular))
                                .foregroundStyle(AgaraColors.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 13)
                        .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func logo(size: CGFloat) -> some View {
        Image("agara-badge")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: AgaraColors.accent.opacity(0.22), radius: 16)
            .accessibilityHidden(true)
    }

    private func tileIcon(_ feature: OnboardingItem, s: CGFloat) -> some View {
        Image(systemName: feature.icon)
            .font(.system(size: (18 * s).rounded()))
            .foregroundStyle(feature.tint)
            .frame(width: (34 * s).rounded(), height: (34 * s).rounded())
            .background(feature.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tile(_ feature: OnboardingItem, s: CGFloat) -> some View {
        VStack(spacing: 6) {
            tileIcon(feature, s: s)
            Text(feature.title)
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(feature.detail)
                .font(AgaraFont.caption)
                .foregroundStyle(AgaraColors.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity)
        .frame(height: (92 * s).rounded(), alignment: .center)
        .padding(.horizontal, 13)
        .agaraGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: "Get started", systemImage: "arrow.right", action: getStarted)
            Button("Explore without ring", action: exploreWithoutRing)
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textSecondary)
                .frame(height: 44)
            LegalLinkRow()
        }
    }
}

struct OnboardingProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var profiles: [UserProfile]
    @State private var draft = ProfileDraft()
    @State private var loaded = false

    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CompactOnboardingHeader(
                    title: "Profile",
                    subtitle: "Used to tune calories, activity goals, and summaries."
                )
                ProfileEditorView(draft: $draft)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: loadIfNeeded)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Continue", systemImage: "arrow.right", action: saveAndContinue)
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = ProfileDraft(profile: profiles.first)
    }

    private func saveAndContinue() {
        let profile: UserProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }
        draft.apply(to: profile)
        try? modelContext.save()
        coordinator.applyUserProfile()
        // Weight/height/age/sex shift every term of the daily calorie estimate.
        DailyCalorieEstimator.recomputeRecentDays(context: modelContext)
        next()
    }
}

struct OnboardingGoalsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var goals: [UserGoal]
    @Query private var profiles: [UserProfile]
    @State private var draft = GoalDraft(units: .metric)
    @State private var loaded = false

    let next: () -> Void
    private var units: UnitsPreference { profiles.first?.units ?? ProfileDraft.preferredUnits(for: .current) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CompactOnboardingHeader(
                    title: "Daily goals",
                    subtitle: "Start with recommended targets. You can change these anytime."
                )
                GoalEditorView(draft: $draft, units: units, includeWeeklyWorkouts: false)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: loadIfNeeded)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Save goals", systemImage: "checkmark", action: saveAndContinue)
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        draft = GoalDraft(goal: goals.first, units: units)
    }

    private func saveAndContinue() {
        let goal: UserGoal
        if let existing = goals.first {
            goal = existing
        } else {
            goal = UserGoal()
            modelContext.insert(goal)
        }
        draft.apply(to: goal, units: units, includeWeeklyWorkouts: false)
        try? modelContext.save()
        coordinator.setGoal(steps: Int(draft.steps))
        next()
    }
}

/// The coach choice, before the user lands in the app: Agara Cloud (the advanced coach; needs an account and the AI
/// disclosure) or the on-device model (private, offline, simpler answers). "Decide later" keeps the release default
/// (Agara Cloud) without marking a choice, so the Coach tab's own state card can ask when the user opens it.
struct OnboardingCoachView: View {
    @State private var cloud = AgaraCloud.shared
    @State private var showCloud = false
    let next: () -> Void

    private var signedIn: Bool { cloud.isSignedIn }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CompactOnboardingHeader(
                    title: "Choose your coach",
                    subtitle: "Agara Cloud analyses your trends; the on-device coach keeps everything on this phone. You can change this later."
                )

                choice(
                    icon: "cloud.fill", tint: AgaraColors.accent, title: "Agara Cloud", badge: "Recommended",
                    detail: "28-day baselines, trends, readiness and sleep patterns. Needs a free account; your numbers go to our coach server.",
                    primary: signedIn ? "Use Agara Cloud" : "Sign in or create account",
                    identifier: "onboarding.coach.cloud"
                ) {
                    if signedIn { choose(.agaraCloud) } else { showCloud = true }
                }

                choice(
                    icon: "iphone", tint: AgaraColors.info, title: "On this phone", badge: nil,
                    detail: "Private and offline. Simpler answers: no long-term trends or readiness analysis.",
                    primary: "Use on this phone",
                    identifier: "onboarding.coach.onDevice"
                ) {
                    choose(.appleOnDevice)
                }

                Button("Decide later") { next() }
                    .font(AgaraFont.footnote.weight(.medium))
                    .foregroundStyle(AgaraColors.textMuted)
                    .accessibilityIdentifier("onboarding.coach.later")
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showCloud) {
            NavigationStack {
                AgaraCloudSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showCloud = false }
                        }
                    }
            }
            .agaraRingEnvironment()
        }
        .onChange(of: showCloud) { _, open in
            // The sheet walks consent → sign up/in → verify. If it closed with an account, take the cloud choice now.
            if !open, signedIn { choose(.agaraCloud) }
        }
    }

    private func choose(_ mode: CoachProviderMode) {
        var settings = CoachSettingsStore.shared.settings
        settings.providerMode = mode
        settings.providerChosen = true
        CoachSettingsStore.shared.settings = settings
        // Someone who has just been shown the cloud option and chose the phone does not need the Coach tab's cloud
        // notice on top; users who were already on-device before this step existed still see it.
        if mode == .appleOnDevice {
            UserDefaults.standard.set(true, forKey: "coach.cloudUpsell.dismissed")
        }
        next()
    }

    @ViewBuilder
    private func choice(icon: String, tint: Color, title: String, badge: String?, detail: String,
                        primary: String, identifier: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(AgaraFont.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(title).font(AgaraFont.headline.weight(.semibold)).foregroundStyle(AgaraColors.textPrimary)
                if let badge {
                    Text(badge.uppercased())
                        .font(AgaraFont.caption2.weight(.bold))
                        .foregroundStyle(AgaraColors.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tint))
                }
                Spacer()
            }
            Text(detail)
                .font(AgaraFont.footnote)
                .foregroundStyle(AgaraColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: primary, systemImage: title == "Agara Cloud" ? "person.fill" : "iphone", action: action)
                .accessibilityIdentifier(identifier)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgaraColors.card))
    }
}

struct OnboardingBaselineView: View {
    let finish: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Drives the medallion (rings + checkmark) and staggered timeline reveal.
    @State private var appeared = false

    // icon / title / one-line description / node tint. "1" renders as a numbered chip.
    private let milestones = [
        OnboardingItem(
            icon: "1", title: "Today",
            detail: "Activity and live vitals, right away", tint: AgaraColors.info
        ),
        OnboardingItem(
            icon: "moon.fill", title: "First sync",
            detail: "Sleep stages and nightly trends", tint: AgaraColors.sleep
        ),
        OnboardingItem(
            icon: "chart.line.uptrend.xyaxis", title: "Days 3–7",
            detail: "Your personalized baseline unlocks", tint: AgaraColors.success
        ),
    ]

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityBody
            } else {
                fittedBody
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingActionFooter {
                PrimaryButton(title: "Start using \(AgaraCopy.appName)", systemImage: "arrow.right", action: finish)
            }
        }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(AgaraMotion.bouncy) { appeared = true }
            }
        }
    }

    private var fittedBody: some View {
        OnboardingFittedBand { s in
            VStack(spacing: 0) {
                medallion(s: s)

                Spacer().frame(height: (16 * s).rounded())

                eyebrow

                VStack(spacing: 6) {
                    Text("You're all set")
                        .font(AgaraFont.largeTitle)
                        .foregroundStyle(AgaraColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Wear your ring today. Your baseline builds from here.")
                        .font(AgaraFont.callout)
                        .foregroundStyle(AgaraColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.top, 4)

                Spacer().frame(height: (20 * s).rounded())

                timeline(s: s)
            }
        }
    }

    // Accessibility fallback: linear scrolling layout, no scale, no motion gating needed
    // (the .onAppear still sets `appeared = true` so nothing stays hidden).
    private var accessibilityBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                medallion(s: 1)
                eyebrow
                VStack(spacing: 6) {
                    Text("You're all set")
                        .font(AgaraFont.largeTitle)
                        .foregroundStyle(AgaraColors.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Wear your ring today. Your baseline builds from here.")
                        .font(AgaraFont.callout)
                        .foregroundStyle(AgaraColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                timeline(s: 1)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Tier 1: animated success medallion

    private func medallion(s: CGFloat) -> some View {
        ZStack {
            // Outer concentric ring.
            Circle()
                .stroke(AgaraColors.accent.opacity(0.12), lineWidth: 2)
                .frame(width: (140 * s).rounded(), height: (140 * s).rounded())
                .scaleEffect(appeared ? 1.0 : 0.7)
                .opacity(appeared ? 1.0 : 0.0)
            // Inner concentric ring (staggered).
            Circle()
                .stroke(AgaraColors.accent.opacity(0.25), lineWidth: 2)
                .frame(width: (104 * s).rounded(), height: (104 * s).rounded())
                .scaleEffect(appeared ? 1.0 : 0.7)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(reduceMotion ? nil : AgaraMotion.bouncy.delay(0.06), value: appeared)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: (72 * s).rounded()))
                .foregroundStyle(AgaraColors.accent)
                .padding((14 * s).rounded())
                .agaraGlass(Circle())
                .scaleEffect(appeared ? 1.0 : 0.3)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: appeared)
        }
        .agaraGlassContainer()
        .accessibilityHidden(true)
    }

    private var eyebrow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(AgaraFont.caption)
            Text("Setup complete")
                .font(AgaraFont.caption.weight(.semibold))
        }
        .foregroundStyle(AgaraColors.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .agaraGlass(Capsule(), tint: AgaraColors.accent.opacity(0.16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup complete")
    }

    // MARK: - Tier 3: connected vertical glass timeline

    private func timeline(s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: (18 * s).rounded()) {
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                milestoneRow(milestone, index: index, s: s, isLast: index == milestones.count - 1)
            }
        }
        .padding((20 * s).rounded())
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AgaraColors.accent.opacity(0.14), AgaraColors.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: (22 * s).rounded(), style: .continuous)
        )
        .agaraGlass(RoundedRectangle(cornerRadius: (22 * s).rounded(), style: .continuous))
    }

    private func milestoneRow(
        _ milestone: OnboardingItem,
        index: Int,
        s: CGFloat,
        isLast: Bool
    ) -> some View {
        let node = (40 * s).rounded()
        return HStack(alignment: .top, spacing: 12) {
            // Glass node + connecting line to the next node.
            VStack(spacing: 0) {
                Group {
                    if milestone.icon == "1" {
                        Text("1").font(AgaraFont.footnote.weight(.bold))
                    } else {
                        Image(systemName: milestone.icon).font(AgaraFont.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(milestone.tint)
                .frame(width: node, height: node)
                .agaraGlass(Circle(), tint: milestone.tint.opacity(0.18))

                if !isLast {
                    Rectangle()
                        .fill(milestone.tint.opacity(0.35))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: node)

            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.title)
                    .font(AgaraFont.subheadline.weight(.semibold))
                    .foregroundStyle(AgaraColors.textPrimary)
                Text(milestone.detail)
                    .font(AgaraFont.footnote.weight(.regular))
                    .foregroundStyle(AgaraColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, (node - 26) / 2) // vertically center title against the node
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(y: appeared ? 0 : 8)
        .animation(reduceMotion ? nil : AgaraMotion.materialize.delay(0.12 * Double(index)), value: appeared)
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingPairView: View {
    let connected: () -> Void
    let skipped: () -> Void

    var body: some View {
        PairingView(onConnected: connected, onSkip: skipped)
    }
}

struct OnboardingActionFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // Transparent footer: the glass button floats over the content (iOS 26 look),
        // no silver glass bar behind it. Content dissolves under the button when scrolled.
        content
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }
}
