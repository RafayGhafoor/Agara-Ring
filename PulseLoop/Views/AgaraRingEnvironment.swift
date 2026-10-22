import SwiftUI

/// The app-owned holder of the four observable ring objects that views read with `@Environment(X.self)`:
/// `RingBLEClient`, `RingSyncCoordinator`, `GpsRouteRecorder`, `LiveWorkoutManager`.
///
/// Why one holder plus one modifier (building block, AGENTS Rule 10): `@Environment(SomeObservable.self)` traps with
/// "No Observable object of type X found" when a view is rebuilt in an environment that lacks the object. SwiftUI does
/// not always carry `.environment(_:)` values set on the WindowGroup into a presentation's hosting controller — the Mac
/// "Measure → Heart rate" crash (2026-09-25, `VitalsView`) and the TestFlight 1.0.0 (1) crashes (iOS 26.7.1,
/// `EnvironmentValues.subscript.getter` ← `EnvironmentBox.update` during `-[UIScene _performSystemSnapshotWithActions:]`,
/// i.e. the background snapshot) are that trap. So every presentation root re-injects all four objects with
/// `.agaraRingEnvironment()`, from this one holder, instead of ad-hoc `.environment(ble).environment(coordinator)` pairs
/// that each name a different subset.
@MainActor
final class AgaraRingEnvironment {
    /// Set once by `AgaraApp.init` before the first view is built.
    static var current: AgaraRingEnvironment?

    let ble: RingBLEClient
    let coordinator: RingSyncCoordinator
    let gps: GpsRouteRecorder
    let liveWorkout: LiveWorkoutManager

    init(ble: RingBLEClient, coordinator: RingSyncCoordinator, gps: GpsRouteRecorder, liveWorkout: LiveWorkoutManager) {
        self.ble = ble
        self.coordinator = coordinator
        self.gps = gps
        self.liveWorkout = liveWorkout
    }
}

/// Injects all four ring objects from `AgaraRingEnvironment.current`. A no-op only when no holder exists (SwiftUI
/// previews); in the app the holder is always set before the WindowGroup body runs.
struct AgaraRingEnvironmentModifier: ViewModifier {
    func body(content: Content) -> some View {
        if let env = AgaraRingEnvironment.current {
            content
                .environment(env.ble)
                .environment(env.coordinator)
                .environment(env.gps)
                .environment(env.liveWorkout)
        } else {
            content
        }
    }
}

extension View {
    /// Re-injects the four ring objects (`RingBLEClient`, `RingSyncCoordinator`, `GpsRouteRecorder`,
    /// `LiveWorkoutManager`). Apply at the WindowGroup root and at the root of every `.sheet`, `.fullScreenCover`,
    /// `.popover` and `navigationDestination` — see `AgaraRingEnvironment` for why.
    func agaraRingEnvironment() -> some View {
        modifier(AgaraRingEnvironmentModifier())
    }
}
