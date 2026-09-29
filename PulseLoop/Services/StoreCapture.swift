import Foundation
import os

/// The store-screenshot hook (`-storeCapture YES`), debug builds only. It makes the app present itself the way the
/// store listing should show it (plan `docs/process/plans/store-launch/store-assets.md` §2, decision D7). It has
/// the same semantics as Android's `StoreCapture` (`storeCapture` launch extra):
///
///  * the profile is **Maya**, not "Sample" / "Emulator";
///  * the Developer row and every debug-only row or label are hidden (the screens look like the release build);
///  * "Updated …" / "Synced …" always read "just now", so a capture never depends on how long a sync took;
///  * no informational banner (low storage, over-limit …) — the only banner left is the intended "Sample data" one,
///    which belongs to sample mode itself and is not touched here;
///  * a seeded workout with a GPS route for the emulator run (sample mode already seeds one) — `SampleWorkout`.
///
/// Like `fixedNow` (`AppClock`) it is refused in Release twice: the launch-argument read is inside `#if DEBUG`, and
/// `configure` refuses by build type — `StoreCaptureTests` and `PulseLoopiOS/scripts/release_hooks_check.sh` prove it.
/// Pair it with `-fixedNow` so the clock in the app equals the ring emulator's `--now`.
nonisolated enum StoreCapture {
    /// The fictional profile the store shots use.
    static let profileName = "Maya"

    /// What every "Updated …" / "Synced …" label reads under capture.
    static let justNow = "just now"

    private static let flag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// True while the hook is on (debug builds only).
    static var isActive: Bool { flag.withLock { $0 } }

    /// Apply the value (`on`/`true`/`1`/`yes`). Release builds always end up inactive.
    @discardableResult
    static func configure(_ value: String?, debugBuild: Bool = AppClock.isDebugBuild) -> Bool {
        let on = debugBuild && parse(value)
        flag.withLock { $0 = on }
        return on
    }

    static func parse(_ value: String?) -> Bool {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["on", "true", "1", "yes"].contains(text)
    }

    /// Read `-storeCapture YES` from the launch arguments. Debug builds only (the key is not in a Release binary).
    static func applyLaunchArguments() {
        #if DEBUG
        configure(UserDefaults.standard.string(forKey: "storeCapture"))
        #endif
    }

    /// The profile name the seeders write: `profileName` under capture, `fallback` otherwise.
    static func profile(_ fallback: String) -> String { isActive ? profileName : fallback }

    /// Debug-only rows and labels show only when this is true: a debug build that is not capturing for the store.
    static var showsDebugChrome: Bool { AppClock.isDebugBuild && !isActive }

    /// Relative-time text under capture: always "just now" (the caller supplies the normal text otherwise).
    static func relative(_ normal: @autoclosure () -> String) -> String { isActive ? justNow : normal() }

    /// Test seam.
    static func reset() { flag.withLock { $0 = false } }
}
