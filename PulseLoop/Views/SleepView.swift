import SwiftUI
import SwiftData

struct SleepView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var allSummaries: [CoachSummary]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: SleepRangeKey
    @State private var coachStore = CoachSettingsStore.shared
    @State private var selectedSleepPage = 0
    @State private var scrolledSleepPage: Int?
    /// 0 = today's reference night; N = N days earlier. Drives the Day-view date stepper.
    @State private var dayOffset = 0
    @State private var showDayPicker = false
    /// Edge the incoming day's content pushes in from (leading = stepping back, trailing = forward).
    @State private var dayNavEdge: Edge = .trailing
    /// Observed so the tab re-fetches when a background sync writes new sleep data (matches
    /// Today/Vitals). Without it, `sleepRange` is a plain call the body never re-runs on sync.
    @State private var dataChange = AgaraDataChange.shared
    /// True while a press-and-hold scrub is active on a hypnogram. Pauses this screen's scroll
    /// views (outer vertical + session carousel) so the scrub drag doesn't pan them.
    @State private var hypnogramScrubbing = false
    /// Memo for the tab's store reads (see `body`). A reference type, so filling it during a body pass
    /// doesn't count as a state change.
    @State private var tabCache = SleepTabCache()

    init() {
        let raw = DebugLaunch.string("startSleepRange")
        _range = State(initialValue: SleepRangeKey.allCases.first { $0.rawValue == raw } ?? .day)
    }

    private var summaryService: CoachSummaryService { CoachSummaryService(modelContext: modelContext) }
    private var coachEnabled: Bool { AgaraFeatureStore.shared.isOn(.coach) && coachStore.settings.coachMasterEnabled }

    private var daySummary: CoachSummary? {
        allSummaries.filter { $0.kind == "sleep_day" }.max(by: { $0.updatedAt < $1.updatedAt })
    }
    private func rangeSummary(_ range: SleepRangeKey) -> CoachSummary? {
        allSummaries.first { $0.kind == "sleep_range_\(range.rawValue)" }
    }

    var body: some View {
        // Day view is anchored on a selectable night: shift `now` back `dayOffset` days and let
        // `sleepRange`/`dayReferenceNight` apply the usual 4 AM "last night" flip. Week/Month/Year
        // keep their own anchor (dayOffset is ignored there).
        let token = dataChange.token   // subscribe: re-run the body (and re-fetch below) on each synced batch
        let effectiveNow = Calendar.current.date(byAdding: .day, value: -dayOffset, to: AppClock.now) ?? AppClock.now
        // The fetches run once per (range, day, data batch, reference night) — not on every body pass (a
        // scrub, a carousel page or a sheet toggle re-runs the body; the Year range is a year of nights).
        let anchor = range == .day ? SleepService.dayReferenceNight(now: effectiveNow) : Calendar.current.startOfDay(for: AppClock.now)
        let loaded = tabCache.value(for: "\(range.rawValue)|\(dayOffset)|\(token)|\(anchor.timeIntervalSince1970)") {
            SleepTabData(
                summary: SleepService.sleepRange(range, context: modelContext, now: range == .day ? effectiveNow : AppClock.now),
                goalMinutes: MetricsRepository.goals(context: modelContext)?.sleepMinutes,
                activitySteps: MetricsRepository.latestActivity(context: modelContext)?.steps,
                earliestDay: SleepRepository.sessions(context: modelContext).first.map { Calendar.current.startOfDay(for: $0.date) }
            )
        }
        let summary = loaded.summary
        let goalMin = loaded.goalMinutes
        let activitySteps = loaded.activitySteps

        ScrollView {
            VStack(spacing: 16) {
                SleepRangeSelectorView(selection: $range)

                if range == .day {
                    dayNavHeader(shownDay: SleepService.dayReferenceNight(now: effectiveNow))
                    dayView(summary: summary, activitySteps: activitySteps, isToday: dayOffset == 0)
                        .id(dayOffset)
                        .transition(reduceMotion ? .opacity : .push(from: dayNavEdge))
                } else {
                    aggregateView(summary: summary, goalMin: goalMin)
                }

                // Where the sleep guidance comes from (App Review 1.4.1).
                HealthSourcesFooter(section: HealthSources.sleepSection, allSourcesIdentifier: "sleep.sources")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        // Applies to every scrollable below (outer + carousel), so an active scrub owns the drag.
        .scrollDisabled(hypnogramScrubbing)
        .background(AgaraColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .agaraScrollEdges()
        .onChange(of: range) { _, newRange in
            // Returning to Day from an aggregate range always lands on today, not a stale offset.
            if newRange == .day { resetToToday() }
        }
        .sensoryFeedback(.selection, trigger: dayOffset)
        .onChange(of: dayOffset) { _, newOffset in announceDay(newOffset) }
        .sheet(isPresented: $showDayPicker) { dayPickerSheet.agaraRingEnvironment() }
        .task(id: "\(range.rawValue)-\(dayOffset)") {
            guard coachEnabled else { return }
            if range == .day {
                // Only the live "last night" gets an LLM summary refresh; browsing history never
                // regenerates/clobbers today's summary.
                if dayOffset == 0 { await summaryService.refreshSleepDayIfNeeded() }
            } else {
                await summaryService.refreshSleepRangeIfNeeded(range)
            }
        }
    }

    /// A summary-backed coach card; falls back to the scripted `SleepCoach` until
    /// the LLM summary is generated. Tapping opens the seeded chat thread.
    /// Hidden entirely when the AI Coach master switch is off.
    @ViewBuilder
    private func summaryCard(_ summary: CoachSummary?, fallback: SleepCoach) -> some View {
        if coachEnabled {
            if let summary {
                Button { summaryService.openInChat(summary) } label: {
                    CoachMessageCard(headline: summary.title, body: summary.body, chips: summary.chips)
                }
                .buttonStyle(.plain)
            } else {
                CoachMessageCard(headline: fallback.headline, body: fallback.body, chips: fallback.chips)
            }
        }
    }

    // MARK: Day

    @ViewBuilder
    private func dayView(summary: SleepRangeSummary, activitySteps: Int?, isToday: Bool) -> some View {
        let sessions = SleepInsights.validSessions(summary.sessions).sorted { $0.session.startAt < $1.session.startAt }
        if sessions.isEmpty {
            // The "wear your ring" explainer lives in the architecture card ONLY — the hero and
            // stage cards just dash out, so the message isn't repeated all over one page.
            SleepHeroCardView(label: SleepInsights.rangeHeroLabel[.day] ?? "Last Sleep", value: "—", score: nil)
            VisualizationCard(eyebrow: "Stages", title: "Night timeline", legend: false) {
                InlineEmptyState(title: "No sleep recorded", message: "Wear your ring overnight to see your hypnogram here.")
                    .frame(height: 180)
            }
            SleepStageSummaryCardsView(deep: "—", light: "—", rem: "—", awake: "—")
        } else {
            // The primary (longest) session drives the day-level coach fallback.
            let primary = sessions.max { $0.session.totalMinutes < $1.session.totalMinutes } ?? sessions[0]
            // The day (night + naps) is what the Today tile scores; the coach fallback speaks about the same number.
            let wholeDay = SleepDay(sessions: sessions)
            let primaryScore = wholeDay?.score ?? SleepScore.calculate(primary)
            let dayFallback = SleepInsights.dayCoach(primary, score: primaryScore.score, awakePct: primaryScore.awakePct, deepPct: primaryScore.deepPct, activitySteps: activitySteps)

            if sessions.count == 1 {
                // Single session: render exactly as before, no carousel chrome. It is the day's main sleep by
                // definition, so it keeps its score.
                sessionPage(sessions[0], isMain: true)
            } else {
                // Several sessions: the whole day first (the number the Today tile shows), then each session's page.
                // A nap's page carries no score of its own (owner 2026-11-04, option (a)) — the day's score above it
                // still includes the nap.
                if let wholeDay { dayTotalRow(wholeDay) }
                sleepCarousel(sessions: sessions, wholeDay: wholeDay)
            }
            // The LLM day summary describes last night only; on a past day fall back to the
            // scripted coach (deterministically computed from that day's own primary session).
            summaryCard(isToday ? daySummary : nil, fallback: dayFallback)
        }
    }

    /// The whole day in one line: total asleep (night + naps), its breakdown, and the day's score — compact, because
    /// each session page below carries its own hero.
    private func dayTotalRow(_ day: SleepDay) -> some View {
        let score = day.score
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whole day")
                    .font(AgaraFont.caption.weight(.semibold))
                    .foregroundStyle(AgaraColors.textMuted)
                Text(SleepFormat.duration(day.totalMinutes))
                    .font(AgaraFont.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(AgaraColors.textPrimary)
                if let breakdown = day.breakdownCaption {
                    Text(breakdown)
                        .font(AgaraFont.caption).monospacedDigit()
                        .foregroundStyle(AgaraColors.textSecondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(score.score)")
                    .font(AgaraFont.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(AgaraColors.textPrimary)
                Text("SCORE")
                    .font(AgaraFont.caption2.weight(.semibold))
                    .foregroundStyle(AgaraColors.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgaraColors.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sleep.dayTotal")
    }

    /// One session's stack: Hero + hypnogram VisualizationCard + stage cards.
    @ViewBuilder
    private func sessionPage(_ s: SleepSummary, isMain: Bool) -> some View {
        // A nap is not a night: no score, no rating, and the eyebrow says what the page is. `nil` score would still
        // draw a dash ("unavailable"), so the nap page hides the whole score column instead.
        let score = SleepDay.heroShowsScore(isMain: isMain) ? SleepScore.calculate(s) : nil
        SleepHeroCardView(
            label: SleepDay.heroLabel(isMain: isMain),
            value: SleepFormat.duration(s.session.totalMinutes),
            support: "\(SleepFormat.clockTime(s.session.startAt)) to \(SleepFormat.clockTime(s.session.endAt))",
            score: score?.score,
            scoreLabel: score?.label.rawValue,
            showsScore: SleepDay.heroShowsScore(isMain: isMain)
        )
        .accessibilityIdentifier(isMain ? "sleep.hero.main" : "sleep.hero.nap")
        // E-P2: the score explains itself. Hung off the score column that only exists when `heroShowsScore` is true, so a
        // nap page can never show a breakdown for a score it does not display.
        if let score, SleepDay.heroShowsScore(isMain: isMain) {
            SleepScoreBreakdownCard(score: score)
        }
        VisualizationCard(eyebrow: "Stages", title: "Night timeline", legend: true) {
            SleepHypnogramView(blocks: s.blocks, totalMin: s.session.totalMinutes, startTs: s.session.startAt,
                               onScrubActiveChanged: { hypnogramScrubbing = $0 })
        }
        // "Recorded in N parts" (port of Android's Records card): only for a night the ring split.
        let runs = SleepRecordRuns.runs(s.blocks)
        if runs.count > 1 {
            VisualizationCard(eyebrow: "Records", title: "The ring recorded this night in \(runs.count) parts", legend: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(index + 1)").font(AgaraFont.caption2).foregroundStyle(AgaraColors.textMuted)
                                .frame(width: 18, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(SleepFormat.clockTime(run.startAt)) – \(SleepFormat.clockTime(run.endAt))")
                                    .font(AgaraFont.subheadline).foregroundStyle(AgaraColors.textPrimary)
                                Text("Asleep \(SleepFormat.duration(run.asleepMinutes))")
                                    .font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                            }
                        }
                        if index < runs.count - 1 {
                            let gap = Int(runs[index + 1].startAt.timeIntervalSince(run.endAt) / 60)
                            Text("Awake \(SleepFormat.duration(gap)) between")
                                .font(AgaraFont.caption).foregroundStyle(AgaraColors.textMuted)
                                .padding(.leading, 18)
                        }
                    }
                }
            }
            .accessibilityIdentifier("sleep.records")
        }
        SleepStageSummaryCardsView(
            deep: SleepFormat.duration(s.deepMinutes),
            light: SleepFormat.duration(s.lightMinutes),
            rem: SleepFormat.duration(s.remMinutes),
            awake: SleepFormat.duration(s.awakeMinutes)
        )
    }

    /// Horizontal paged carousel across multiple sleep sessions in one day.
    /// Sizes to the tallest visible page (no fixed height) and shows a dot row.
    @ViewBuilder
    private func sleepCarousel(sessions: [SleepSummary], wholeDay: SleepDay?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.session.id) { idx, s in
                    VStack(spacing: 16) {
                        Text("\(idx + 1) of \(sessions.count) · \(SleepFormat.clockTime(s.session.startAt))–\(SleepFormat.clockTime(s.session.endAt))")
                            .font(AgaraFont.caption)
                            .foregroundStyle(AgaraColors.textSecondary)
                            .textCase(.uppercase)
                            .kerning(0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        sessionPage(s, isMain: wholeDay?.isMain(s) ?? true)
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(idx)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledSleepPage)
        .onChange(of: scrolledSleepPage) { _, newValue in
            if let newValue { selectedSleepPage = newValue }
        }
        // Reset to the first page whenever the day's session set changes (and on appear), so a
        // stale index can't linger past the dots when a different day or fewer sessions load.
        .onChange(of: sessions.map(\.session.id), initial: true) { _, _ in
            selectedSleepPage = 0
            scrolledSleepPage = 0
        }
        // VoiceOver can't reach off-screen carousel pages via horizontal swipe, so expose the
        // carousel as a single adjustable element: swipe up/down steps sessions and scrolls to them.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sleep session")
        .accessibilityValue(sessionCarouselA11yValue(sessions: sessions))
        .accessibilityAdjustableAction { direction in
            let current = min(max(0, selectedSleepPage), sessions.count - 1)
            let next: Int
            switch direction {
            case .increment: next = min(sessions.count - 1, current + 1)
            case .decrement: next = max(0, current - 1)
            @unknown default: next = current
            }
            guard next != selectedSleepPage else { return }
            selectedSleepPage = next
            withAnimation(reduceMotion ? nil : AgaraMotion.spring) { scrolledSleepPage = next }
        }

        // Page indicator dots.
        HStack(spacing: 8) {
            ForEach(sessions.indices, id: \.self) { i in
                Circle()
                    .fill(i == selectedSleepPage ? AgaraColors.accent : AgaraColors.textSecondary.opacity(0.3))
                    .frame(width: 7, height: 7)
                    .animation(reduceMotion ? nil : AgaraMotion.spring, value: selectedSleepPage)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    /// VoiceOver value for the adjustable carousel: "2 of 3, 1:20 PM to 2:05 PM".
    private func sessionCarouselA11yValue(sessions: [SleepSummary]) -> String {
        guard !sessions.isEmpty else { return "" }
        let idx = min(max(0, selectedSleepPage), sessions.count - 1)
        let s = sessions[idx]
        return "\(idx + 1) of \(sessions.count), \(SleepFormat.clockTime(s.session.startAt)) to \(SleepFormat.clockTime(s.session.endAt))"
    }

    // MARK: Day navigation

    /// The date stepper above the Day content: ‹ older · date · newer ›. Horizontal swipe is owned
    /// by the session carousel, so days move only via these taps / the date picker.
    @ViewBuilder
    private func dayNavHeader(shownDay: Date) -> some View {
        let labels = dayLabels(shownDay)
        HStack(spacing: 8) {
            chevronButton("chevron.left", enabled: dayOffset < maxDayOffset, label: "Previous day",
                          disabledHint: "Earliest recorded sleep") { stepDay(older: true) }
            Spacer(minLength: 4)
            Button { showDayPicker = true } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(labels.primary)
                            .font(AgaraFont.headline)
                            .foregroundStyle(AgaraColors.textPrimary)
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AgaraColors.textMuted)
                    }
                    // Always render the subtitle line (a space when empty) so the hero card never
                    // shifts vertically as you cross the Today/Yesterday/weekday label boundaries.
                    Text(labels.secondary.isEmpty ? " " : labels.secondary)
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textSecondary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                        .contentTransition(.opacity)
                }
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : AgaraMotion.spring, value: dayOffset)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits([.isButton, .isHeader])
            .accessibilityLabel(voiceLabel(shownDay))
            .accessibilityHint("Opens a date picker to choose a day")
            Spacer(minLength: 4)
            chevronButton("chevron.right", enabled: dayOffset > 0, label: "Next day",
                          disabledHint: "You're viewing the most recent day") { stepDay(older: false) }
        }
        .frame(maxWidth: .infinity)
    }

    /// A ≥44pt tappable chevron; glass disc only while enabled, muted glyph when at a bound.
    @ViewBuilder
    private func chevronButton(_ system: String, enabled: Bool, label: String,
                               disabledHint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(AgaraFont.headline.weight(.semibold))
                .foregroundStyle(enabled ? AgaraColors.textPrimary : AgaraColors.textMuted)
                .frame(width: 44, height: 44)
                .background {
                    if enabled {
                        Circle().fill(Color.clear).frame(width: 36, height: 36).agaraGlass(Circle(), interactive: true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.agaraTap)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(enabled ? "" : (disabledHint ?? ""))
        .help(label)
    }

    /// Graphical date picker bounded to [oldest browsable day ... today].
    private var dayPickerSheet: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: AppClock.now)
        let selection = Binding<Date>(
            get: { calendar.date(byAdding: .day, value: -dayOffset, to: today) ?? today },
            set: { setDay(to: $0) }
        )
        return NavigationStack {
            DatePicker("Day", selection: selection, in: floorDay...today, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Choose a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDayPicker = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// Earliest recorded night (sessions are sorted ascending by date), start-of-day.
    private var earliestDataDay: Date? {
        tabCache.earliestDay ?? SleepRepository.sessions(context: modelContext).first.map { Calendar.current.startOfDay(for: $0.date) }
    }
    /// How many days back the stepper may travel: up to one week before the earliest recorded
    /// night, clamped to a 1-year floor. 0 (locked to today) when there's no data at all.
    private var maxDayOffset: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: AppClock.now)
        guard let earliest = earliestDataDay else { return 0 }
        let earliestMinus7 = calendar.date(byAdding: .day, value: -7, to: earliest) ?? earliest
        let yearAgo = calendar.date(byAdding: .day, value: -365, to: today) ?? today
        let floor = max(earliestMinus7, yearAgo)   // the more-recent of the two bounds
        return max(0, calendar.dateComponents([.day], from: floor, to: today).day ?? 0)
    }
    private var floorDay: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: AppClock.now)
        return calendar.date(byAdding: .day, value: -maxDayOffset, to: today) ?? today
    }

    private func resetToToday() {
        dayOffset = 0
        selectedSleepPage = 0
        scrolledSleepPage = nil
    }
    private func stepDay(older: Bool) {
        let target = older ? dayOffset + 1 : dayOffset - 1
        let clamped = min(maxDayOffset, max(0, target))
        guard clamped != dayOffset else { return }
        dayNavEdge = older ? .leading : .trailing
        withAnimation(reduceMotion ? nil : AgaraMotion.spring) { dayOffset = clamped }
        selectedSleepPage = 0
        scrolledSleepPage = nil
    }
    private func setDay(to date: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: AppClock.now)
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        let clamped = min(maxDayOffset, max(0, offset))
        dayNavEdge = clamped > dayOffset ? .leading : .trailing   // further back = enters from leading
        withAnimation(reduceMotion ? nil : AgaraMotion.spring) { dayOffset = clamped }
        selectedSleepPage = 0
        scrolledSleepPage = nil
        showDayPicker = false
    }

    /// Primary (relative) + secondary (absolute) date strings for the header label.
    private func dayLabels(_ shownDay: Date) -> (primary: String, secondary: String) {
        let calendar = Calendar.current
        let absolute = shownDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if AppClock.isToday(shownDay, calendar: calendar) { return ("Today", absolute) }
        if AppClock.isYesterday(shownDay, calendar: calendar) { return ("Yesterday", absolute) }
        let daysAgo = calendar.dateComponents([.day], from: shownDay, to: calendar.startOfDay(for: AppClock.now)).day ?? 0
        if daysAgo < 7 {
            return (shownDay.formatted(.dateTime.weekday(.wide)), shownDay.formatted(.dateTime.month(.abbreviated).day()))
        }
        let sameYear = calendar.component(.year, from: shownDay) == calendar.component(.year, from: AppClock.now)
        let primary = sameYear ? absolute : shownDay.formatted(.dateTime.month(.abbreviated).day().year())
        return (primary, "")
    }
    /// Full spoken date for VoiceOver (never abbreviated glyphs).
    private func voiceLabel(_ shownDay: Date) -> String {
        let calendar = Calendar.current
        let full = shownDay.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if AppClock.isToday(shownDay, calendar: calendar) { return "Today, \(full)" }
        if AppClock.isYesterday(shownDay, calendar: calendar) { return "Yesterday, \(full)" }
        let sameYear = calendar.component(.year, from: shownDay) == calendar.component(.year, from: AppClock.now)
        return sameYear ? full : shownDay.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// Speak the newly-selected day + its session count — the carousel repopulates silently and
    /// focus stays on the chevron, so VoiceOver users otherwise get no confirmation of the change.
    private func announceDay(_ offset: Int) {
        let now = Calendar.current.date(byAdding: .day, value: -offset, to: AppClock.now) ?? AppClock.now
        let sessionCount = SleepInsights.validSessions(SleepService.sleepRange(.day, context: modelContext, now: now).sessions).count
        let day = SleepService.dayReferenceNight(now: now)
        let sessionsPhrase = sessionCount == 0
            ? "No sleep recorded"
            : "\(sessionCount) sleep session\(sessionCount == 1 ? "" : "s")"
        AccessibilityNotification.Announcement("\(voiceLabel(day)). \(sessionsPhrase).").post()
    }

    // MARK: Aggregate

    @ViewBuilder
    private func aggregateView(summary: SleepRangeSummary, goalMin: Int?) -> some View {
        // Collapse naps into their day so the hero's "N of M nights tracked" counts distinct nights,
        // consistent with the (already-collapsing) averages and coach copy.
        let valid = SleepInsights.collapseByDay(SleepInsights.validSessions(summary.sessions))
        let enough = valid.count >= 2
        let avgMin = SleepInsights.averageDuration(valid)
        let avgScore = SleepInsights.averageScore(valid)
        let stageAvg = SleepInsights.averageStages(valid)
        let coach = SleepInsights.aggregateCoach(range: range, sessions: summary.sessions, expectedNights: summary.expectedNights, goalMin: goalMin)
        let noData = SleepInsights.noDataState(range)
        let heroSupport = range == .year
            ? "Tracked \(valid.count) \(valid.count == 1 ? "night" : "nights") this year"
            : "\(valid.count) of \(summary.expectedNights) nights tracked"
        let bars = range == .year
            ? SleepInsights.buildMonthBuckets(end: summary.end, sessions: summary.sessions)
            : SleepInsights.buildNightAxis(start: summary.start, end: summary.end, sessions: summary.sessions, range: range)
        let vizTitle = range == .year ? "Monthly average" : "Nightly sleep"

        // Hero card opens the page; coach card closes it.
        SleepHeroCardView(
            label: SleepInsights.rangeHeroLabel[range] ?? "Sleep",
            value: enough ? SleepFormat.duration(avgMin) : noData.value,
            support: heroSupport,
            score: enough ? avgScore : nil,
            scoreLabel: enough ? avgScore.map { SleepScore.qualityLabel($0).rawValue } : nil,
            noData: !enough
        )
        VisualizationCard(eyebrow: "Duration", title: vizTitle, legend: false) {
            SleepDurationHistogramChart(
                bars: bars, goalMin: goalMin, slim: range == .month,
                onSelect: { index in
                    guard bars.indices.contains(index), let date = bars[index].date else { return }
                    let calendar = Calendar.current
                    switch range {
                    case .year:
                        // A year bar is a month, so its natural destination is the month view.
                        range = .month
                    case .week, .month:
                        // A bar is a night: anchor the day view on it.
                        let days = calendar.dateComponents(
                            [.day],
                            from: calendar.startOfDay(for: date),
                            to: calendar.startOfDay(for: AppClock.now)
                        ).day ?? 0
                        dayOffset = max(0, days)
                        range = .day
                    case .day:
                        break
                    }
                },
                barWidth: range == .week ? 30 : nil, weekBars: range == .week
            )
        }
        SleepStageSummaryCardsView(
            prefix: "Avg ",
            deep: stageAvg.map { SleepFormat.duration($0.deep) } ?? "—",
            light: stageAvg.map { SleepFormat.duration($0.light) } ?? "—",
            rem: stageAvg.map { SleepFormat.duration($0.rem) } ?? "—",
            awake: stageAvg.map { SleepFormat.duration($0.awake) } ?? "—"
        )
        summaryCard(rangeSummary(range), fallback: coach)
    }
}

/// Card wrapper for sleep visualizations (eyebrow + title + optional stage legend).
private struct VisualizationCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let legend: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrow.uppercased()).font(AgaraFont.caption2).tracking(1.8).foregroundStyle(AgaraColors.textMuted)
                    Text(title).font(AgaraFont.bodyEmphasis).foregroundStyle(AgaraColors.textPrimary)
                }
                Spacer()
                if legend {
                    HStack(spacing: 8) {
                        legendItem("Deep", SleepStageColors.deep)
                        legendItem("Light", SleepStageColors.light)
                        legendItem("REM", SleepStageColors.rem)
                        legendItem("Awake", SleepStageColors.awake)
                    }
                    .fixedSize()
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .agaraGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sampleChip(.bottomTrailing)
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(AgaraFont.nano.weight(.regular)).foregroundStyle(AgaraColors.textSecondary)
        }
    }
}

/// What the Sleep tab reads from the store for one (range, day, data batch).
struct SleepTabData {
    let summary: SleepRangeSummary
    let goalMinutes: Int?
    let activitySteps: Int?
    let earliestDay: Date?
}

/// One-entry memo for `SleepView`'s fetches, keyed by what they depend on.
final class SleepTabCache {
    private var key: String?
    private var data: SleepTabData?
    var earliestDay: Date? { data?.earliestDay }

    func value(for key: String, _ load: () -> SleepTabData) -> SleepTabData {
        if key == self.key, let data { return data }
        let fresh = load()
        self.key = key
        data = fresh
        return fresh
    }
}

/// "Why this score?" — the components the score was actually built from, with the points each earned, and an
/// "estimated" note when the ring did not label the whole night (item E-P2).
///
/// Collapsed by default and hidden entirely when the scorer has no breakdown (the v1 scorer, i.e. `sleep_score_v2`
/// off), because there is nothing honest to show then.
private struct SleepScoreBreakdownCard: View {
    let score: SleepScoreResult
    @State private var open = false

    var body: some View {
        if !score.components.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(open ? "Hide the breakdown" : "Why this score?")
                            .font(AgaraFont.caption.weight(.semibold))
                            .foregroundStyle(AgaraColors.accent)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(AgaraFont.caption2.weight(.semibold))
                            .foregroundStyle(AgaraColors.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sleep.score.breakdown")

                if open {
                    if score.estimated {
                        Text("Estimated — the ring didn't label the whole night, so this is an average over what it did.")
                            .font(AgaraFont.caption2)
                            .foregroundStyle(AgaraColors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("sleep.score.estimated")
                    }
                    ForEach(score.components) { c in
                        HStack(spacing: 8) {
                            Text(Self.title(c.id)).font(AgaraFont.caption).foregroundStyle(AgaraColors.textPrimary)
                            Text(Self.value(c) + c.unit)
                                .font(AgaraFont.caption2).monospacedDigit().foregroundStyle(AgaraColors.textMuted)
                            Spacer(minLength: 0)
                            // A fixed-size track: a GeometryReader inside a scrolling stack hung the app under the UI test
                            // (watchdog kill, no crash report), and 5 pt of bar does not need to be screen-proportional.
                            ZStack(alignment: .leading) {
                                Capsule().fill(AgaraColors.borderSubtle).frame(width: 90, height: 5)
                                Capsule().fill(AgaraColors.accent).frame(width: max(2, 90 * c.earned), height: 5)
                            }
                            Text("\(Int(c.points.rounded())) / \(Int(c.weight.rounded()))")
                                .font(AgaraFont.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(AgaraColors.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sleep.score.component.\(c.id)")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AgaraColors.card))
            .transition(.opacity)
        }
    }

    private static func title(_ id: String) -> String {
        switch id {
        case "duration": return "Duration"
        case "deep": return "Deep sleep"
        case "rem": return "REM sleep"
        case "light": return "Light sleep"
        case "awake": return "Awake time"
        default: return id.capitalized
        }
    }

    /// 7.9 h / 16 % — one decimal where it matters, never "16.0".
    private static func value(_ c: SleepScoreComponent) -> String {
        abs(c.value.rounded() - c.value) < 0.05 ? String(Int(c.value.rounded())) : String(format: "%.1f", c.value)
    }
}
