import Foundation
import UserNotifications

/// Shared deep-link state. Setting `requestedConversationId` makes `MainTabView`
/// switch to the Coach tab and `CoachView` open that conversation. Used by both
/// daily-check-in notification taps and Today/Sleep summary-card taps.
@MainActor
@Observable
final class CoachNavigation {
    static let shared = CoachNavigation()
    var requestedConversationId: UUID?
    /// A nudge's seeded answer: set by a nudge card's "Why?" tap or by a nudge push, rendered at 0 tokens. The tab
    /// shows it above the thread until the user sends a question or dismisses it.
    var requestedSeed: CoachSeed?
    /// Asks `MainTabView` to bring the Coach tab forward (summary-card tap, notification deep link, a card in
    /// Today). The coach is a tab of its own now, so there is no sheet to present and no floating button to press —
    /// the request only selects the tab, and the tab's state decides what it shows.
    var wantsCoachTab = false

    /// The coach's own actions live in the app header on the Coach tab (one top bar, not two), but their state lives in
    /// `CoachView`. The header posts a request; the view answers it. Counters rather than flags, so two taps are two
    /// requests and nothing has to be reset.
    private(set) var newChatRequests = 0
    private(set) var historyRequests = 0
    private(set) var usageRequests = 0
    private(set) var consentRequests = 0

    func requestNewChat() { newChatRequests += 1 }
    func requestHistory() { historyRequests += 1 }
    func requestUsage() { usageRequests += 1 }
    /// The header's "tap to agree" line: the tab presents the coach consent sheet.
    func requestConsent() { consentRequests += 1 }

    /// Open the coach on a specific conversation (deep link).
    func open(_ conversationId: UUID) {
        requestedSeed = nil
        requestedConversationId = conversationId
        wantsCoachTab = true
    }

    /// Open the coach with a nudge already written out (spec §6): the message, its evidence numbers, a chart spec and
    /// three suggested questions. No model call happens until the user sends one of them.
    func open(seed: CoachSeed) {
        requestedConversationId = nil
        requestedSeed = seed
        wantsCoachTab = true
    }

    /// Open the coach with no specific conversation.
    /// Clears any prior deep-link id so it doesn't reopen a stale thread.
    func openRoot() {
        requestedConversationId = nil
        requestedSeed = nil
        wantsCoachTab = true
    }
}

/// UNUserNotificationCenter delegate for every `AgaraNotifications` category: shows alerts (coach, battery)
/// while foreground, keeps progress news (measurement, sync) out of the way — the in-app UI shows those — and
/// routes a tap to its deep link (the coach thread, the Measure sheet, Today, Wearable).
final class CoachNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        switch notification.request.content.categoryIdentifier {
        case AgaraNotificationCategory.measurement.identifier, AgaraNotificationCategory.sync.identifier:
            return [.list]
        default:
            return [.banner, .sound]
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        // A nudge button: run it through the same `perform` a card tap uses, so the ledger and the snooze agree.
        if let action = NudgeAction.allCases.first(where: { $0.notificationIdentifier == response.actionIdentifier }) {
            await MainActor.run {
                if let seed = AgaraNotification.nudgeSeed(from: info) {
                    NudgeDeliveryService.shared.perform(action, on: Self.nudge(for: seed))
                }
            }
            return
        }
        if let idString = info[CoachNotificationService.conversationIdKey] as? String,
           let id = UUID(uuidString: idString) {
            await MainActor.run { CoachNavigation.shared.open(id) }
        } else if let seed = AgaraNotification.nudgeSeed(from: info) {
            // The notification body itself: the seeded coach answer, not a model call.
            await MainActor.run { CoachNavigation.shared.open(seed: seed) }
        } else if let link = AgaraNotifications.deepLink(from: info) {
            await MainActor.run { AgaraDeepLinks.shared.pending = link }
        }
    }

    /// The nudge a push payload describes, rebuilt from its `userInfo` (a notification callback has no model context, so
    /// the live evidence is not re-queried). Enough for every button: "Not now" pauses the category, "Why?" opens the
    /// seed, "Open ring" routes, "Keep goal" clears an override.
    private static func nudge(for seed: CoachSeed) -> CoachNudge {
        // The category comes from the rule itself — one source of truth, no second switch to drift.
        let rule = NudgeRule(rawValue: seed.rule) ?? .g1
        return CoachNudge(
            rule: rule,
            category: rule.category,
            delivery: .push,
            title: seed.title,
            body: seed.title,
            seed: seed.message,
            evidence: [],
            buttons: NudgeAction.allCases,
            fingerprint: "push-\(seed.rule)",
            severity: 0,
            templateID: "push",
            isCelebration: rule.isCelebration)
    }
}
