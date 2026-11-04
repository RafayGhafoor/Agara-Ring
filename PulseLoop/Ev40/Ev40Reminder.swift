import Foundation
import SwiftData
import UserNotifications

/// The EV40 daily reminder (plan decision D5): one local notification a day at a time the user picks — default 20:00
/// local, on — posted only when today's checklist is **not** already complete, and its tap always lands on the tracker.
///
/// The scheduling is deliberately boring and testable. The **decisions** are pure functions (`nextFireDates`,
/// `shouldPost`); the thin part below only talks to `AgaraNotifications` (the one notification layer, Rule 10) and
/// SwiftData. Because a repeating calendar trigger cannot skip a single day, the window is 14 day-keyed one-shot
/// requests, re-armed whenever the app comes to the foreground, the settings change or a tick completes the day —
/// completing the day removes today's, so an already-finished checklist is never nagged about.
@MainActor
enum Ev40Reminder {
    /// How many days ahead the schedule is kept armed. Two weeks outlives a fortnight without opening the app; the
    /// foreground re-arm makes it self-healing after that.
    nonisolated static let horizonDays = 14

    /// The identifier prefix of the day-keyed requests: `agara.ev40.<yyyy-MM-dd>`.
    nonisolated static let requestPrefix = "agara.ev40."

    struct Settings: Equatable, Sendable {
        var enabled: Bool
        var hour: Int
        var minute: Int

        /// Plan D5: on, 20:00 local. The owner's choice, recorded in the plan.
        static let `default` = Settings(enabled: true, hour: 20, minute: 0)

        var displayTime: String { String(format: "%02d:%02d", hour, minute) }
    }

    private enum Key {
        static let enabled = "agara.ev40.reminder.enabled"
        static let hour = "agara.ev40.reminder.hour"
        static let minute = "agara.ev40.reminder.minute"
        static let lastPostedDay = "agara.ev40.reminder.lastPostedDay"
    }

    // MARK: Settings

    nonisolated static func settings(defaults: UserDefaults = .standard) -> Settings {
        guard defaults.object(forKey: Key.enabled) != nil else { return .default }
        let hour = defaults.object(forKey: Key.hour) as? Int ?? Settings.default.hour
        let minute = defaults.object(forKey: Key.minute) as? Int ?? Settings.default.minute
        return Settings(enabled: defaults.bool(forKey: Key.enabled),
                        hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59))
    }

    static func save(_ settings: Settings, defaults: UserDefaults = .standard) {
        defaults.set(settings.enabled, forKey: Key.enabled)
        defaults.set(settings.hour, forKey: Key.hour)
        defaults.set(settings.minute, forKey: Key.minute)
    }

    // MARK: Pure decisions (tested)

    /// The fire times of the next `days` days: `hour:minute` local, today's only while it is still ahead.
    nonisolated static func nextFireDates(now: Date, hour: Int, minute: Int, days: Int = horizonDays,
                                          calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        for offset in 0..<max(0, days) {
            guard let base = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            var parts = calendar.dateComponents([.year, .month, .day], from: base)
            parts.hour = hour
            parts.minute = minute
            parts.second = 0
            guard let fire = calendar.date(from: parts), fire > now else { continue }   // today's time may have passed
            out.append(fire)
        }
        return out
    }

    /// Whether a fire is due right now: the switch is on, the time has come, the checklist is not complete, and nothing
    /// has been posted today yet (so the worker/notification cannot double-post after a re-arm).
    nonisolated static func shouldPost(now: Date, settings: Settings, mask: Int, lastPostedDay: String?,
                                       calendar: Calendar = .current) -> Bool {
        guard settings.enabled else { return false }
        guard !Ev40Disciplines.isComplete(mask) else { return false }
        let today = AgaraCloudDays.dayString(now, calendar: calendar)
        guard lastPostedDay != today else { return false }
        let nowParts = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (nowParts.hour ?? 0) * 60 + (nowParts.minute ?? 0)
        return nowMinutes >= settings.hour * 60 + settings.minute
    }

    nonisolated static func requestID(for dayKey: String) -> String { requestPrefix + dayKey }

    // MARK: Side effects

    /// Re-arm the whole window: remove every request of ours, then add one per remaining day — skipping today when the
    /// checklist is already complete (plan D6/D5: never nag about a finished day).
    static func refresh(context: ModelContext? = nil, now: Date = AppClock.now, calendar: Calendar = .current) async {
        let settings = settings()
        let center = UNUserNotificationCenter.current()
        // Also drop requests left behind by a previous hour/minute choice or a time-zone change.
        let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(requestPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        guard settings.enabled else { return }
        guard await AgaraNotifications.shared.isAuthorizedToPost() else { return }

        let dayKey = AgaraCloudDays.dayString(now, calendar: calendar)
        let complete = context.map { Ev40Disciplines.isComplete(Ev40Repo.todayMask(context: $0, now: now, calendar: calendar)) } ?? false
        let dates = nextFireDates(now: now, hour: settings.hour, minute: settings.minute, calendar: calendar)
        for fire in dates {
            let key = AgaraCloudDays.dayString(fire, calendar: calendar)
            if complete, key == dayKey { continue }
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            parts.second = 0
            await AgaraNotifications.shared.schedule(
                .ev40Reminder(id: requestID(for: key)), at: parts,
            )
        }
    }

    /// Post the reminder now if it is due (used by the debug/test path; the shipped reminder is a scheduled local
    /// notification, so nothing wakes the app for it).
    @discardableResult
    static func postIfDue(context: ModelContext, now: Date = AppClock.now, calendar: Calendar = .current) async -> Bool {
        let settings = settings()
        let mask = Ev40Repo.todayMask(context: context, now: now, calendar: calendar)
        let lastPosted = UserDefaults.standard.string(forKey: Key.lastPostedDay)
        guard shouldPost(now: now, settings: settings, mask: mask, lastPostedDay: lastPosted, calendar: calendar) else { return false }
        let posted = await AgaraNotifications.shared.post(.ev40Reminder())
        if posted { UserDefaults.standard.set(AgaraCloudDays.dayString(now, calendar: calendar), forKey: Key.lastPostedDay) }
        return posted
    }
}

extension AgaraNotification {
    /// The daily EV40 check-in. Copy comes from the brand catalog (Rule 5); the tap opens the tracker.
    static func ev40Reminder(id: String = "agara.ev40.reminder") -> AgaraNotification {
        AgaraNotification(id: id, category: .ev40, title: AgaraCopy.ev40ReminderTitle, body: AgaraCopy.ev40ReminderBody,
                          deepLink: .ev40, onlyInBackground: false)
    }
}
