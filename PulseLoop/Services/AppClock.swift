import Foundation
import os

/// The app's one wall clock: every place that answers "what time is it?" for a *display or derivation* decision reads
/// it here — the Today greeting, "Updated x ago" / "Synced x ago", the sleep "last night" reference, day boundaries
/// (`isToday`, `Calendar` lookups seeded with `AppClock.now`), the seeded sample data, timestamps stamped on live
/// ring samples.
///
/// In production it is the system clock, exactly (offset 0). A **debug** build can shift it with the `-fixedNow
/// <ISO-8601>` launch argument (store screenshots, `docs/process/plans/store-launch/store-assets.md`, decision D7):
/// the clock then reads `system time + (fixedNow - system time at configure)`, so it starts at the ring emulator's
/// `--now` and keeps ticking. Offsetting instead of freezing keeps every elapsed-time computation (timeouts, stall
/// detectors, "measuring… 12 s") correct, because the difference of two readings is unchanged by a constant shift.
/// This is the same semantics as Android's `AppClock` (`fixedNow` launch extra).
///
/// **Not routed here on purpose:** anything the OS or a peer timestamps in real time — the BLE link-liveness marks
/// (`RingBLEClient`), the firmware installer's deadlines (`timeIntervalSinceNow`), the animation clocks
/// (`AnimatedRingArt`), the Strava / cloud token expiry, the notification schedulers, the widget and Live Activity
/// extensions (separate processes), and the SwiftData `@Model` bookkeeping defaults (`createdAt = Date()`).
///
/// Release builds cannot shift it: `configure` does nothing unless it is a debug build (proved by `AppClockTests`),
/// and the launch-argument read is itself inside `#if DEBUG`, so the `fixedNow` key does not exist in a Release
/// binary (proved by `PulseLoopiOS/scripts/release_hooks_check.sh`).
nonisolated enum AppClock {
    private static let shift = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// True in a debug build; a compile-time constant, so the shifting code is dead in Release.
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Seconds the clock is shifted from the system clock (0 = none).
    static var offset: TimeInterval { shift.withLock { $0 } }

    /// True while a `fixedNow` shift is in force (debug builds only).
    static var isShifted: Bool { offset != 0 }

    /// The current time, as `Date()` would say it if the phone's clock were set to `fixedNow`.
    static var now: Date { Date().addingTimeInterval(offset) }

    /// Convert a date the *system* produced just now (a `TimelineView` tick, a `Date()` from an OS callback) to the
    /// app clock, so it can be compared with values read from `now`.
    static func adjust(_ systemDate: Date) -> Date { systemDate.addingTimeInterval(offset) }

    /// `Calendar.isDateInToday` against the app clock.
    static func isToday(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }

    /// `Calendar.isDateInYesterday` against the app clock.
    static func isYesterday(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }

    /// Local midnight of the app clock's today.
    static func startOfToday(calendar: Calendar = .current) -> Date { calendar.startOfDay(for: now) }

    /// Apply the `fixedNow` value. `fixedNowISO` is ISO-8601: a local date-time without a zone (`2026-09-24T19:30:00`,
    /// read in the device zone, which is how the emulator's `--now` is written) or one with an offset / `Z`. `nil`,
    /// blank or unparsable input, and **any release build**, leave the system clock untouched (and reset an earlier
    /// shift, so a relaunch without the argument is back to real time).
    ///
    /// - Returns: the shift in seconds now in force (0 = none).
    @discardableResult
    static func configure(_ fixedNowISO: String?,
                          debugBuild: Bool = AppClock.isDebugBuild,
                          systemNow: Date = Date(),
                          timeZone: TimeZone = .current) -> TimeInterval {
        var value: TimeInterval = 0
        if debugBuild, let target = parse(fixedNowISO, timeZone: timeZone) {
            value = target.timeIntervalSince(systemNow)
        }
        shift.withLock { $0 = value }
        return value
    }

    /// Read `-fixedNow <ISO>` from the launch arguments. Debug builds only: in Release this is empty, so the key
    /// name is not even in the binary.
    static func applyLaunchArguments() {
        #if DEBUG
        configure(UserDefaults.standard.string(forKey: "fixedNow"))
        #endif
    }

    /// ISO-8601 → date, or nil. Accepts `…T19:30`, `…T19:30:00`, `…T19:30:00.5`, `…T19:30:00+02:00`, `…T17:30:00Z`.
    static func parse(_ iso: String?, timeZone: TimeZone = .current) -> Date? {
        guard let text = iso?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Test seam: back to the system clock.
    static func reset() { shift.withLock { $0 = 0 } }
}
