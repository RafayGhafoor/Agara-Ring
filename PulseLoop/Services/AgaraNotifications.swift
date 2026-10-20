import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// The one notification layer (consistency framework, block A — AGENTS.md Rule 10). Every local notification
/// the app posts goes through `AgaraNotifications.shared.post(_:)`: one category per kind of news, titles from
/// the brand catalog (`AgaraCopy.notification*`), a deep link the tap follows, per-id throttling, and the
/// "only while the app is in the background" rule for progress news (decision 2 of the plan: in the
/// foreground the in-app UI shows progress and results). Mirrors Android's `AgaraNotifications` (channels
/// there, categories here).
enum AgaraNotificationCategory: String, CaseIterable {
    case measurement, sync, firmware, battery, coach
    /// The three proactive-nudge categories (spec: `agara.coach.recovery`, `agara.coach.stress`,
    /// `agara.coach.generic`). Their buttons and the seeded coach answer they open are defined in
    /// `Coach/Nudges/NudgeNotifications.swift` — this layer stays the one place categories are registered.
    case coachRecovery = "coach.recovery"
    case coachStress = "coach.stress"
    case coachGeneric = "coach.generic"

    /// `UNNotificationCategory` identifier (also the thread, so each kind groups on the lock screen).
    var identifier: String { "agara.\(rawValue)" }
}

/// Where a tapped notification takes the user. Stored in `userInfo` under `AgaraNotifications.deepLinkKey`.
enum AgaraDeepLink: String, Equatable {
    /// Vitals, with the Measure sheet showing the running (or finished) measurement.
    case measure
    /// Today (the header shows the sync bar).
    case sync
    /// Settings › Wearable (battery, firmware, ring actions).
    case wearable
    /// The Coach sheet (a conversation id may ride along in `userInfo`).
    case coach
}

struct AgaraNotification: Equatable {
    /// Replaces any earlier notification with the same id (progress → result reuse one id).
    let id: String
    let category: AgaraNotificationCategory
    let title: String
    let body: String
    var deepLink: AgaraDeepLink?
    /// Post only while the app is in the background (progress and result news). Alerts that matter in the
    /// foreground too (battery, coach check-ins) pass false.
    var onlyInBackground = true
    /// Minimum seconds between two posts with this id (progress updates); 0 = no throttle.
    var throttle: TimeInterval = 0
    /// Silent update (no sound) — progress notifications replace each other quietly.
    var silent = false
    var extraUserInfo: [String: String] = [:]
}

@MainActor
final class AgaraNotifications {
    static let shared = AgaraNotifications()

    nonisolated static let deepLinkKey = "agara.deepLink"

    /// Whether the app is in the background right now. Tracked from the application lifecycle; tests set it.
    var isAppInBackground: Bool
    /// The delivery step (UNUserNotificationCenter in the app; a recorder in tests).
    var deliver: (UNNotificationRequest) async -> Void
    var removeDelivered: ([String]) -> Void
    var now: () -> Date = Date.init

    private var lastPosted: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []

    init(isAppInBackground: Bool? = nil,
         deliver: ((UNNotificationRequest) async -> Void)? = nil,
         removeDelivered: (([String]) -> Void)? = nil) {
        #if canImport(UIKit)
        self.isAppInBackground = isAppInBackground ?? (UIApplication.shared.applicationState == .background)
        #else
        self.isAppInBackground = isAppInBackground ?? false
        #endif
        self.deliver = deliver ?? { request in try? await UNUserNotificationCenter.current().add(request) }
        self.removeDelivered = removeDelivered ?? { ids in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Register the categories and follow the app lifecycle. Called once at launch (not under unit tests).
    func start() {
        UNUserNotificationCenter.current().setNotificationCategories(Set(AgaraNotificationCategory.allCases.map {
            // `actions` is empty for the non-nudge categories and carries the nudge buttons for the three coach ones
            // (`NudgeNotifications.swift`).
            UNNotificationCategory(identifier: $0.identifier, actions: $0.actions, intentIdentifiers: [], options: [])
        }))
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidChangeState(background: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidChangeState(background: false) }
        })
        #endif
    }

    /// Lifecycle hook: the observers below (measurement, sync) get told so they can post "still running" news
    /// the moment the user leaves, and clear it when they come back.
    private(set) var backgroundHandlers: [(Bool) -> Void] = []

    func onBackgroundChange(_ handler: @escaping (Bool) -> Void) {
        backgroundHandlers.append(handler)
    }

    func appDidChangeState(background: Bool) {
        isAppInBackground = background
        for handler in backgroundHandlers { handler(background) }
    }

    /// Post (or skip) one notification. Returns whether it was handed to the system.
    @discardableResult
    func post(_ note: AgaraNotification) async -> Bool {
        guard shouldPost(note) else { return false }
        lastPosted[note.id] = now()
        await deliver(Self.request(for: note))
        return true
    }

    /// The pure gate: background rule + throttle. Exposed for tests.
    func shouldPost(_ note: AgaraNotification) -> Bool {
        if note.onlyInBackground, !isAppInBackground { return false }
        if note.throttle > 0, let last = lastPosted[note.id], now().timeIntervalSince(last) < note.throttle {
            return false
        }
        return true
    }

    /// The current notification permission, without asking. `.notDetermined` means the app has never asked.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Whether posting would actually show something. Never prompts: background alerts (battery) use this so
    /// the system dialog can only ever appear where the user was told why (onboarding sync, the Settings toggle,
    /// starting a measurement).
    func isAuthorizedToPost() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Ask for permission once, at a moment the user started something that reports back (a measurement,
    /// a sync they're watching). Returns whether notifications are allowed. Never prompts in E2E runs against
    /// the emulator — a system alert over the app would block the UI tests.
    @discardableResult
    func requestAuthorizationIfUndetermined() async -> Bool {
        #if DEBUG
        if VirtualRingLink.configuredPort != nil { return false }
        #endif
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    func remove(ids: [String]) {
        for id in ids { lastPosted[id] = nil }
        removeDelivered(ids)
    }

    static func request(for note: AgaraNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = note.category.identifier
        content.threadIdentifier = note.category.identifier
        if !note.silent { content.sound = .default }
        var info: [String: String] = note.extraUserInfo
        if let link = note.deepLink { info[deepLinkKey] = link.rawValue }
        content.userInfo = info
        return UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
    }

    /// The deep link a tapped notification carries, if any.
    nonisolated static func deepLink(from userInfo: [AnyHashable: Any]) -> AgaraDeepLink? {
        (userInfo[deepLinkKey] as? String).flatMap(AgaraDeepLink.init(rawValue:))
    }
}

// MARK: - Standard notifications (copy: AgaraCopy for titles; bodies name the metric/state)

extension AgaraNotification {
    static let measurementId = "agara.measurement"
    static let syncId = "agara.sync"

    static func measuring(_ title: String) -> AgaraNotification {
        AgaraNotification(id: measurementId, category: .measurement, title: AgaraCopy.notificationMeasuringTitle,
                          body: "\(title) — keep the ring on and your hand still.", deepLink: .measure, silent: true)
    }

    static func measured(_ title: String, result: String) -> AgaraNotification {
        AgaraNotification(id: measurementId, category: .measurement, title: AgaraCopy.notificationMeasuredTitle,
                          body: "\(title): \(result)", deepLink: .measure)
    }

    static func measurementFailed(_ title: String) -> AgaraNotification {
        AgaraNotification(id: measurementId, category: .measurement, title: AgaraCopy.notificationMeasuredFailedTitle,
                          body: "\(title): \(AgaraCopy.measurementNoReading)", deepLink: .measure)
    }

    static func syncing(_ summary: String) -> AgaraNotification {
        AgaraNotification(id: syncId, category: .sync, title: AgaraCopy.notificationSyncTitle, body: summary,
                          deepLink: .sync, throttle: 10, silent: true)
    }

    static func synced(_ summary: String) -> AgaraNotification {
        AgaraNotification(id: syncId, category: .sync, title: AgaraCopy.notificationSyncDoneTitle, body: summary,
                          deepLink: .sync, silent: true)
    }
}

// MARK: - Deep-link routing

/// The pending deep link from a notification tap. `MainTabView` switches tab / pushes the route; `VitalsView`
/// opens the Measure sheet for `.measure`. Cleared by whoever consumes it.
@MainActor
@Observable
final class AgaraDeepLinks {
    static let shared = AgaraDeepLinks()
    var pending: AgaraDeepLink?
    /// Set when `.measure` was routed to Vitals; VitalsView consumes it by opening the sheet.
    var openMeasureSheet = false
}
