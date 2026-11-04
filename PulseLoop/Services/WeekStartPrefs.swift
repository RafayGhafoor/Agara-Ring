import Foundation

/// The user's **week start** choice (plan `asana-heart-bugs-2026-11-01`, item D / owner D3: "user-visible and
/// configurable, default from the locale"). Unset = `WeekStart.locale` (0) = follow the device region.
///
/// Same key as Android (`weekStart.day`) and the same numbers as the catalog (`1 = Sunday … 7 = Saturday`), so the two
/// apps describe the same preference. `UserDefaults` (nothing secret), so "Delete all my data" clears it too.
///
/// `install()` runs in `AgaraApp` at start **before** anything weekly, because `WeekStart` resolves from the value
/// installed here rather than reading defaults on every call.
enum WeekStartPrefs {
    static let key = "weekStart.day"

    /// For tests and for the settings row, which owns the write.
    static func install(_ value: Int, defaults: UserDefaults = .standard) {
        let v = (1...7).contains(value) ? value : WeekStart.locale
        defaults.set(v, forKey: key)
        WeekStart.install(v)
    }

    /// Read the stored choice and install it. Idempotent.
    @discardableResult
    static func installFromDefaults(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.object(forKey: key) as? Int ?? WeekStart.locale
        WeekStart.install(v)
        return v
    }

    /// The choice in force: 0 = follow the device, 1…7 = an explicit day.
    static func stored(_ defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: key) as? Int ?? WeekStart.locale
    }

    /// What the UI should show for the effective day.
    static func effectiveDay() -> Int { WeekStart.day() }
}
