import Foundation
import UserNotifications
import SwiftUI

/// The nudge push layer: three categories on the existing `AgaraNotifications` layer (consistency block A — AGENTS.md
/// Rule 10 says extend the one notification layer, never fork it), one action identifier per button, and the one
/// `perform(action:on:)` that both a card tap and a push action go through.
extension AgaraNotificationCategory {
    /// The buttons each nudge category offers on the lock screen / banner, from the approved spec:
    /// recovery = Keep goal / Lighter today / Why?, stress = Breathe 2 min / Not now,
    /// generic = Why? / Not now / Open ring.
    var nudgeActions: [NudgeAction] {
        switch self {
        case .coachRecovery: [.keepGoal, .lighterToday, .why]
        case .coachStress: [.breathe, .notNow]
        case .coachGeneric: [.why, .notNow, .openRing]
        default: []
        }
    }

    /// `UNNotificationAction`s for the category. An action that needs the app (the confirmation for "Lighter today", the
    /// seeded coach answer for "Why?") runs in the foreground; "Not now" is satisfied from the background.
    var actions: [UNNotificationAction] {
        nudgeActions.map { action in
            let needsApp: Bool
            switch action {
            case .why, .lighterToday, .keepGoal, .breathe, .openRing: needsApp = true
            case .notNow: needsApp = false
            }
            return UNNotificationAction(identifier: action.notificationIdentifier, title: action.title,
                                        options: needsApp ? [.foreground] : [])
        }
    }
}

/// `userInfo` keys a nudge push carries, so a tap (or a button) can rebuild the seeded coach answer without the model
/// and without re-running the policy.
enum NudgeNotificationKey {
    static let rule = "agara.nudge.rule"
    static let title = "agara.nudge.title"
    static let body = "agara.nudge.body"
    static let seed = "agara.nudge.seed"
}

extension AgaraNotification {
    /// One push for one nudge. `onlyInBackground` stays false: a nudge is an alert, not progress news.
    static func nudge(_ nudge: CoachNudge) -> AgaraNotification {
        AgaraNotification(
            id: nudge.id,
            category: nudge.category.notificationCategory,
            title: nudge.title,
            body: nudge.body,
            deepLink: nil,
            onlyInBackground: false,
            silent: false,
            extraUserInfo: [
                NudgeNotificationKey.rule: nudge.rule,
                NudgeNotificationKey.title: nudge.title,
                NudgeNotificationKey.body: nudge.body,
                NudgeNotificationKey.seed: nudge.seedMessage,
            ]
        )
    }

    /// The nudge a push payload describes, for the seeded coach answer on tap.
    static func nudgeSeed(from userInfo: [AnyHashable: Any]) -> CoachSeed? {
        guard let rule = userInfo[NudgeNotificationKey.rule] as? String,
              let seed = userInfo[NudgeNotificationKey.seed] as? String else { return nil }
        return CoachSeed(rule: rule,
                         title: userInfo[NudgeNotificationKey.title] as? String ?? "",
                         message: seed,
                         suggestions: CoachSeed.suggestions(forRule: rule))
    }
}

/// The one place a nudge button does something. A card tap and a notification action both land here, so "Not now"
/// pauses and is recorded identically from both.
@MainActor
@Observable
final class NudgeDelivery {
    static let shared = NudgeDelivery()

    /// The nudge whose "Lighter today" prompt is up (the shared `ConfirmAction`, Rule 10).
    var confirmingLighter: CoachNudge?
    /// The nudge whose breathing session is open (C1's "Breathe 2 min").
    var breathingFor: CoachNudge?
    /// Set to send the user somewhere outside the screen (a push action can arrive before Today is on screen).
    var pendingDeepLink: AgaraDeepLink?
    /// Which percent the "Lighter today" confirmation offers.
    var lighterPercent = DailyGoalOverride.percents[0]

    /// Run one button. Returns the outcome recorded in the ledger, so a test can assert the tap's effect rather than
    /// its pixels.
    @discardableResult
    func perform(_ action: NudgeAction, on nudge: CoachNudge, now: Date = Date()) -> NudgeOutcome {
        let ledger = NudgeLedgerStore.shared
        switch action {
        case .keepGoal:
            // A tap on the goal is an answer: the override (if any) is dropped and the category's learning tolerance resets.
            DailyGoalOverrideStore.shared.clear()
            return ledger.record(nudge, outcome: .keptGoal, now: now).outcome
        case .lighterToday:
            confirmingLighter = nudge
            return ledger.record(nudge, outcome: .tapped, now: now).outcome
        case .why:
            CoachNavigation.shared.open(seed: CoachSeed(nudge))
            return ledger.record(nudge, outcome: .whyOpened, now: now).outcome
        case .notNow:
            ledger.snooze(nudge.category, until: NudgeDelivery.nextWake(now: now))
            return ledger.record(nudge, outcome: .notNow, now: now).outcome
        case .breathe:
            breathingFor = nudge
            return ledger.record(nudge, outcome: .tapped, now: now).outcome
        case .openRing:
            pendingDeepLink = .wearable
            return ledger.record(nudge, outcome: .openedRing, now: now).outcome
        }
    }

    /// "Not now" pauses the category until the user's next wake time, not for a fixed hour.
    static func nextWake(now: Date = Date(), wakeHour: Int = 8) -> Date {
        let calendar = Calendar.current
        if let today = calendar.date(bySettingHour: wakeHour, minute: 0, second: 0, of: now), today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(12 * 3600)
    }
}
