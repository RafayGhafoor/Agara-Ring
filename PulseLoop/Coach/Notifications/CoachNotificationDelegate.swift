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
    /// Asks `MainTabView` to bring the Coach tab forward (summary-card tap, notification deep link, a card in
    /// Today). The coach is a tab of its own now, so there is no sheet to present and no floating button to press —
    /// the request only selects the tab, and the tab's state decides what it shows.
    var wantsCoachTab = false

    /// Open the coach on a specific conversation (deep link).
    func open(_ conversationId: UUID) {
        requestedConversationId = conversationId
        wantsCoachTab = true
    }

    /// Open the coach with no specific conversation.
    /// Clears any prior deep-link id so it doesn't reopen a stale thread.
    func openRoot() {
        requestedConversationId = nil
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
        if let idString = info[CoachNotificationService.conversationIdKey] as? String,
           let id = UUID(uuidString: idString) {
            await MainActor.run { CoachNavigation.shared.open(id) }
        } else if let link = AgaraNotifications.deepLink(from: info) {
            await MainActor.run { AgaraDeepLinks.shared.pending = link }
        }
    }
}
