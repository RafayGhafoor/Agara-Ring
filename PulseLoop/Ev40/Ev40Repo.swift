import Foundation
import SwiftData

/// Everything that reads or writes `Ev40Day` — one place, so the card, the tracker screen and the history can never
/// disagree about what "today" means or how a tick is stored (Rule 10).
///
/// A day is identified by the user's **local** `yyyy-MM-dd` (`AgaraCloudDays.dayString`, the same helper the cloud
/// day rows use). That is the whole reset rule: at midnight the key changes, so the checklist is a row that does not
/// exist yet — there is no timer, no cleanup job, and yesterday's row keeps its ticks for the history.
@MainActor
enum Ev40Repo {
    /// The key of the day `date` falls on, in the user's calendar. Also the wire `date` (cloud-v2 §2.1).
    nonisolated static func dayKey(_ date: Date = AppClock.now, calendar: Calendar = .current) -> String {
        AgaraCloudDays.dayString(date, calendar: calendar)
    }

    /// The stored row for a key, if any.
    static func row(_ key: String, context: ModelContext) -> Ev40Day? {
        var descriptor = FetchDescriptor<Ev40Day>(predicate: #Predicate { $0.dateKey == key })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func row(_ key: String, creating context: ModelContext) -> Ev40Day {
        if let existing = row(key, context: context) { return existing }
        let created = Ev40Day(dateKey: key)
        context.insert(created)
        return created
    }

    /// Today's checklist, or nil when nothing has been ticked today yet (the card shows 0/8 then — an honest zero,
    /// because "no row" for today simply means "nothing done yet", not "no data").
    static func today(context: ModelContext, now: Date = AppClock.now, calendar: Calendar = .current) -> Ev40Day? {
        row(dayKey(now, calendar: calendar), context: context)
    }

    static func todayMask(context: ModelContext, now: Date = AppClock.now, calendar: Calendar = .current) -> Int {
        today(context: context, now: now, calendar: calendar).map { Ev40Disciplines.normalised($0.mask) } ?? 0
    }

    /// Flip one discipline on today's checklist and save. Returns the new mask.
    @discardableResult
    static func toggle(_ discipline: Ev40Discipline, context: ModelContext, now: Date = AppClock.now,
                       calendar: Calendar = .current) -> Int {
        let day = row(dayKey(now, calendar: calendar), creating: context)
        day.mask = Ev40Disciplines.toggle(Ev40Disciplines.normalised(day.mask), discipline)
        day.updatedAt = now
        try? context.save()
        // The card and the tracker read SwiftData directly; this wakes the coalesced persistence token the Today
        // screen already listens to, so a tick made from the tracker updates the card behind it.
        AgaraDataChange.shared.notify()
        // Completing the day removes today's reminder, and un-ticking it puts it back (plan D5/D6): re-arm the window.
        // The mask is passed in, so the async part never touches this (possibly short-lived) model context.
        let complete = Ev40Disciplines.isComplete(day.mask)
        Task { await Ev40Reminder.refresh(todayComplete: complete) }
        return day.mask
    }

    /// Toggle a discipline on any day, for the read-only history detail's future use and for tests: the screen
    /// itself never calls it for a past day (plan D4).
    @discardableResult
    static func toggle(_ discipline: Ev40Discipline, onKey key: String, context: ModelContext,
                       now: Date = AppClock.now) -> Int {
        let day = row(key, creating: context)
        day.mask = Ev40Disciplines.toggle(Ev40Disciplines.normalised(day.mask), discipline)
        day.updatedAt = now
        try? context.save()
        AgaraDataChange.shared.notify()
        return day.mask
    }

    /// Every stored day, newest first — the accountability log the history screen lists.
    static func history(context: ModelContext, limit: Int = 400) -> [Ev40Day] {
        var descriptor = FetchDescriptor<Ev40Day>(sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Days that carry at least one tick, newest first: the history hides an all-zero day, which is a day the user
    /// opened the screen on but did nothing with — not an entry in the log.
    static func log(context: ModelContext, limit: Int = 400) -> [Ev40Day] {
        history(context: context, limit: limit).filter { Ev40Disciplines.count($0.mask) > 0 }
    }

    /// `dateKey` → the start of that day in `calendar` (nil when the key is not a date).
    nonisolated static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        AgaraCloudDays.parseDay(key, calendar: calendar)
    }

    /// "Wed, Nov 4" in the user's locale — the tracker header and the history rows.
    nonisolated static func displayDate(_ key: String, calendar: Calendar = .current) -> String {
        guard let date = date(key, calendar: calendar) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date)
    }
}
