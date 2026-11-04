import SwiftUI
import SwiftData

/// The EV40 Daily Tracker on screen: the Today card, the tracker, the history and a past day.
///
/// One card language for all of them (`AgaraColors.card` + `.agaraGlass`, the radius the other cards use), one
/// progress bar (`Ev40ProgressBar`), one checkbox row (`Ev40DisciplineRow`) and one formatter (`Ev40Repo.displayDate`).
/// Copy that both platforms must agree on comes from the catalog (`AgaraCopy.ev40*`); counts and plurals are native.
///
/// The Today card reads SwiftData directly through `@Query`, so a tick made on the tracker updates the card behind it
/// with no manual refresh, and the card's own `scenePhase` hook re-reads "today" when the app comes back after
/// midnight (the checklist is keyed by the local date, so a new day is simply a row that does not exist yet).

// MARK: - Today card

struct Ev40TodayCard: View {
    /// Every tracker row (one per day; a year is ~365 small rows) — the card only needs today's.
    @Query private var days: [Ev40Day]
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = AppClock.now

    let onOpen: () -> Void

    private var todayKey: String { Ev40Repo.dayKey(now) }
    private var mask: Int {
        days.first { $0.dateKey == todayKey }.map { Ev40Disciplines.normalised($0.mask) } ?? 0
    }
    private var done: Int { Ev40Disciplines.count(mask) }
    private var isComplete: Bool { Ev40Disciplines.isComplete(mask) }

    var body: some View {
        Button(action: onOpen) {
            if isComplete { completeRow } else { fullCard }
        }
        .buttonStyle(.agaraTap)
        .accessibilityIdentifier("ev40.card")
        .accessibilityLabel("EV40 Daily Tracker, \(done) of \(Ev40Disciplines.all.count) disciplines completed today")
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = AppClock.now } }
    }

    /// Plan D6: once all eight are ticked the full card collapses to one line for the rest of the local day — the
    /// tracker and the history stay one tap away, and the full card is back after midnight.
    private var completeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AgaraColors.success)
            Text(AgaraCopy.ev40CardComplete)
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textPrimary)
            Text("\(done)/\(Ev40Disciplines.all.count)")
                .font(AgaraFont.numberM)
                .foregroundStyle(AgaraColors.success)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgaraColors.textMuted)
        }
        .padding(.horizontal, AgaraShape.cardPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                .fill(AgaraColors.success.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                .strokeBorder(AgaraColors.success.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("ev40.card.complete")
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AgaraColors.accent)
                Text(AgaraCopy.ev40CardEyebrow)
                    .font(AgaraFont.micro)
                    .tracking(1.6)
                    .foregroundStyle(AgaraColors.textMuted)
                Spacer(minLength: 0)
                Text(AgaraCopy.ev40CardPillToday)
                    .font(AgaraFont.nano)
                    .tracking(1.2)
                    .foregroundStyle(AgaraColors.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AgaraColors.success.opacity(0.16)))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(done)/\(Ev40Disciplines.all.count)")
                    .font(AgaraFont.numberXL)
                    .foregroundStyle(AgaraColors.textPrimary)
                Text(AgaraCopy.ev40CardCompletedLabel)
                    .font(AgaraFont.body)
                    .foregroundStyle(AgaraColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Ev40ProgressBar(done: done, total: Ev40Disciplines.all.count, tint: AgaraColors.success)
            HStack(spacing: 6) {
                Text(AgaraCopy.ev40CardFooter)
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textMuted)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(AgaraCopy.ev40CardCta)
                        .font(AgaraFont.caption.weight(.bold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(AgaraColors.accent)
            }
        }
        .padding(.horizontal, AgaraShape.cardPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous)
                .fill(AgaraColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: AgaraShape.radiusCard, style: .continuous)
                        .strokeBorder(AgaraColors.success.opacity(0.18), lineWidth: 1)
                )
        )
        .accessibilityIdentifier("ev40.card.full")
    }
}

// MARK: - Shared bits

/// The one progress bar of the feature (track + fill, capsule ends).
struct Ev40ProgressBar: View {
    let done: Int
    let total: Int
    var tint: Color = AgaraColors.success

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(AgaraColors.cardSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.22), value: fraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One discipline: glyph, name, and the checkbox. Tapping the row toggles it (the whole row is the target, which is
/// what makes it quick to use); a read-only day renders the same row without a button.
struct Ev40DisciplineRow: View {
    let discipline: Ev40Discipline
    let isOn: Bool
    var isEditable: Bool
    var onToggle: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: discipline.symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(isOn ? AgaraColors.success : AgaraColors.textSecondary)
            Text(discipline.title)
                .font(AgaraFont.body)
                .foregroundStyle(AgaraColors.textPrimary)
            Spacer(minLength: 8)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(isOn ? AgaraColors.success : AgaraColors.textMuted.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: AgaraShape.radiusControl, style: .continuous)
                .fill(isOn ? AgaraColors.success.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())

        if isEditable, let onToggle {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier(discipline.testID)
                .accessibilityLabel(discipline.title)
                .accessibilityValue(isOn ? "Completed" : "Not completed")
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(discipline.testID)
                .accessibilityLabel("\(discipline.title), \(isOn ? "completed" : "not completed")")
        }
    }
}

// MARK: - Tracker screen

struct Ev40TrackerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = AppClock.now
    let path: Binding<NavigationPath>

    private var key: String { Ev40Repo.dayKey(now) }
    private var mask: Int { Ev40Repo.todayMask(context: modelContext, now: now) }
    private var done: Int { Ev40Disciplines.count(mask) }
    private var isComplete: Bool { Ev40Disciplines.isComplete(mask) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                progressCard
                VStack(spacing: 6) {
                    ForEach(Ev40Disciplines.all) { discipline in
                        Ev40DisciplineRow(discipline: discipline,
                                          isOn: Ev40Disciplines.isOn(mask, discipline),
                                          isEditable: true) {
                            Ev40Repo.toggle(discipline, context: modelContext, now: now)
                        }
                    }
                }
                historyLink
            }
            .padding(.horizontal, AgaraShape.gutter)
            .padding(.top, 8)
            .padding(.bottom, AgaraLayout.scrollBottomInset)
        }
        .background(AgaraColors.background)
        .agaraScrollEdges()
        .navigationTitle(AgaraCopy.ev40ScreenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.wrappedValue.append(AppRoute.ev40History) } label: {
                    Image(systemName: "calendar")
                        .foregroundStyle(AgaraColors.accent)
                }
                .accessibilityIdentifier("ev40.historyButton")
                .accessibilityLabel(AgaraCopy.ev40HistoryTitle)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = AppClock.now } }
        .accessibilityIdentifier("ev40.screen")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AgaraCopy.ev40ScreenHeadline)
                .font(AgaraFont.title2)
                .foregroundStyle(AgaraColors.textPrimary)
            Text(AgaraCopy.ev40ScreenSubhead)
                .font(AgaraFont.footnote)
                .foregroundStyle(AgaraColors.textMuted)
            Text(Ev40Repo.displayDate(key))
                .font(AgaraFont.caption)
                .foregroundStyle(AgaraColors.textMuted)
                .padding(.top, 2)
                .accessibilityIdentifier("ev40.todayDate")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var progressCard: some View {
        if isComplete {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AgaraColors.success)
                Text(AgaraCopy.ev40CompleteTitle)
                    .font(AgaraFont.title2)
                    .foregroundStyle(AgaraColors.textPrimary)
                Text(AgaraCopy.ev40CompleteBody)
                    .font(AgaraFont.footnote)
                    .foregroundStyle(AgaraColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                    .fill(AgaraColors.success.opacity(0.12))
            )
            .accessibilityIdentifier("ev40.complete")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(AgaraCopy.ev40ProgressTitle)
                        .font(AgaraFont.subheadline.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                    Spacer(minLength: 8)
                    Text("\(done)/\(Ev40Disciplines.all.count)")
                        .font(AgaraFont.numberL)
                        .foregroundStyle(AgaraColors.success)
                }
                Ev40ProgressBar(done: done, total: Ev40Disciplines.all.count)
                Text(remainingLine)
                    .font(AgaraFont.caption)
                    .foregroundStyle(AgaraColors.textMuted)
                    .accessibilityIdentifier("ev40.progress")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                    .fill(AgaraColors.card)
            )
        }
    }

    /// "3 disciplines completed · 5 remaining" — native pluralisation, the counts are not shared copy.
    private var remainingLine: String {
        let total = Ev40Disciplines.all.count
        let completed = String.localizedStringWithFormat(
            NSLocalizedString("%d disciplines completed", comment: "EV40 tracker: completed count"),
            done)
        if done == 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("%d remaining", comment: "EV40 tracker: remaining count"), total)
        }
        return completed + " · " + String.localizedStringWithFormat(
            NSLocalizedString("%d remaining", comment: "EV40 tracker: remaining count"), total - done)
    }

    private var historyLink: some View {
        Button { path.wrappedValue.append(AppRoute.ev40History) } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AgaraColors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgaraCopy.ev40HistoryLinkTitle)
                        .font(AgaraFont.subheadline.weight(.semibold))
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text(AgaraCopy.ev40HistoryLinkBody)
                        .font(AgaraFont.caption)
                        .foregroundStyle(AgaraColors.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgaraColors.textMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                    .fill(AgaraColors.card)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ev40.historyLink")
    }
}

// MARK: - History

struct Ev40HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Ev40Day.dateKey, order: .reverse) private var days: [Ev40Day]
    let path: Binding<NavigationPath>

    private var todayKey: String { Ev40Repo.dayKey() }
    /// Only days with at least one tick are log entries; an all-zero row is a day the screen was opened on.
    private var rows: [Ev40Day] { days.filter { Ev40Disciplines.count($0.mask) > 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AgaraCopy.ev40HistoryHeadline)
                        .font(AgaraFont.title2)
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text(AgaraCopy.ev40HistorySubhead)
                        .font(AgaraFont.footnote)
                        .foregroundStyle(AgaraColors.textMuted)
                }
                if rows.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        ForEach(rows) { day in
                            Button { path.wrappedValue.append(AppRoute.ev40Day(day.dateKey)) } label: {
                                historyRow(day)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ev40.history.row.\(day.dateKey)")
                        }
                    }
                }
            }
            .padding(.horizontal, AgaraShape.gutter)
            .padding(.top, 8)
            .padding(.bottom, AgaraLayout.scrollBottomInset)
        }
        .background(AgaraColors.background)
        .agaraScrollEdges()
        .navigationTitle(AgaraCopy.ev40HistoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ev40.history")
    }

    private func historyRow(_ day: Ev40Day) -> some View {
        let done = Ev40Disciplines.count(day.mask)
        let isToday = day.dateKey == todayKey
        let label = isToday ? "\(Ev40Repo.displayDate(day.dateKey)) (\(AgaraCopy.ev40CardPillToday.lowercased()))"
                            : Ev40Repo.displayDate(day.dateKey)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(AgaraFont.subheadline.weight(isToday ? .semibold : .medium))
                    .foregroundStyle(isToday ? AgaraColors.textPrimary : AgaraColors.textSecondary)
                Spacer(minLength: 8)
                Text("\(done)/\(Ev40Disciplines.all.count)")
                    .font(AgaraFont.numberM)
                    .foregroundStyle(done == Ev40Disciplines.all.count ? AgaraColors.success : AgaraColors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgaraColors.textMuted)
            }
            Ev40ProgressBar(done: done, total: Ev40Disciplines.all.count,
                            tint: isToday ? AgaraColors.accent : AgaraColors.success)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                .fill(AgaraColors.card)
        )
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AgaraColors.textMuted)
            Text("No history yet")
                .font(AgaraFont.subheadline.weight(.semibold))
                .foregroundStyle(AgaraColors.textPrimary)
            Text("Check a discipline today and the day shows up here.")
                .font(AgaraFont.caption)
                .foregroundStyle(AgaraColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: AgaraShape.radiusCompact, style: .continuous)
                .fill(AgaraColors.card)
        )
        .accessibilityIdentifier("ev40.history.empty")
    }
}

/// One past day, read-only (plan D4): the accountability log is a record, not a form the user edits days later.
struct Ev40DayView: View {
    @Environment(\.modelContext) private var modelContext
    let dateKey: String

    private var mask: Int { Ev40Repo.row(dateKey, context: modelContext).map { Ev40Disciplines.normalised($0.mask) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Ev40Repo.displayDate(dateKey))
                        .font(AgaraFont.title2)
                        .foregroundStyle(AgaraColors.textPrimary)
                    Text("\(Ev40Disciplines.count(mask))/\(Ev40Disciplines.all.count)")
                        .font(AgaraFont.numberL)
                        .foregroundStyle(AgaraColors.success)
                }
                VStack(spacing: 6) {
                    ForEach(Ev40Disciplines.all) { discipline in
                        Ev40DisciplineRow(discipline: discipline,
                                          isOn: Ev40Disciplines.isOn(mask, discipline),
                                          isEditable: false)
                    }
                }
            }
            .padding(.horizontal, AgaraShape.gutter)
            .padding(.top, 8)
            .padding(.bottom, AgaraLayout.scrollBottomInset)
        }
        .background(AgaraColors.background)
        .agaraScrollEdges()
        .navigationTitle(AgaraCopy.ev40ScreenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ev40.day")
    }
}
