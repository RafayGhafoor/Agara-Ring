import SwiftUI

/// The Today coach card as it must render **now**.
///
/// `CoachSummaryService.refreshTodayIfNeeded` regenerates the stored card only when the data signature changed **and**
/// two hours have passed, so between refreshes the stored text describes an older day: on 2026-10-28 the card said
/// "1,238 steps … latest reading is 100 bpm" beside tiles showing 2,247 steps and 98 bpm. So the card's numbers are
/// taken from the tiles' own prepared state at render time (`TodayStore.summary` / `TodayStore.cards`), the prose
/// stays the stored summary's, and one caption states how old the reading behind those numbers is (owner D2).
struct CoachTodayCard: Equatable {
    let headline: String
    let body: String
    let chips: [String]
    /// "Updated 47m ago" — the tiles' own age text for the latest reading. Nil when the tiles show no age (no
    /// reading yet, or sample data, whose timestamps are invented).
    let freshness: String?

    /// - Parameters:
    ///   - summary: the stored card (prose + chips) — regenerated at most every two hours.
    ///   - heartRate: the prepared heart-rate tile model — used only for its age, never for a second copy of its value.
    ///   - showAge: the tiles' rule: sample data carries invented timestamps, so the tiles show no age.
    ///
    /// **Why the card keeps the summary's own numbers** (2026-11-01, D12): the generated prose embeds them ("you're at
    /// 1,238 steps … latest reading 100 bpm"), so promoting a live numbers line into the headline while keeping that
    /// prose would print two sets of figures that disagree *on the same card* — worse than the mismatch it was meant to
    /// fix. The card therefore stays internally consistent and states its age instead (owner D2: freshness = validity).
    /// Making the numbers live needs the generator to stop embedding values in the prose — a coach-service change,
    /// tracked as the follow-up in docs/features/coach-card.md.
    static func make(summary: CoachSummary, heartRate: VitalCardViewModel?,
                     showAge: Bool) -> CoachTodayCard {
        CoachTodayCard(
            headline: summary.title,
            body: summary.body,
            chips: summary.chips,
            freshness: freshness(updatedText: heartRate?.lastUpdatedText, showAge: showAge)
        )
    }

    /// The D2 caption: the tile's own age for the latest reading (`TodayTileContext.age`), never a second clock over
    /// the same timestamp. Pure, so the caption is testable without a whole tile model.
    static func freshness(updatedText: String?, showAge: Bool) -> String? {
        guard showAge, let updatedText else { return nil }
        return "\(AgaraCopy.coachUpdatedPrefix) \(TodayTileContext.age(updatedText))"
    }

    /// The card shown while the coach is on but no summary has been generated yet: no data claims, so no live numbers
    /// and no freshness caption.
    static func placeholder(isCalibrating: Bool) -> CoachTodayCard {
        CoachTodayCard(
            headline: isCalibrating ? "Baseline in progress" : "Want a recap?",
            body: isCalibrating
                ? "I can help explain what data is collected and what is still missing."
                : "Want a summary from the latest ring context? Tap to open the coach.",
            chips: [],
            freshness: nil
        )
    }
}

/// The Today coach card: the shared `CoachMessageCard` plus the D2 freshness caption underneath it.
struct CoachTodayCardView: View {
    let card: CoachTodayCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoachMessageCard(headline: card.headline, body: card.body, chips: card.chips)
            if let freshness = card.freshness {
                Text(freshness)
                    .font(AgaraFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(AgaraColors.textMuted)
                    .padding(.leading, 18)
                    .accessibilityIdentifier("coach.card.freshness")
            }
        }
    }
}
