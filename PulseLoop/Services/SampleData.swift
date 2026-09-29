import Foundation
import SwiftData
import Observation

/// "Explore without ring": a clearly labelled set of sample data (store launch, phase 1 item 3).
///
/// * **Labelled:** while `isActive`, `MainTabView` shows the `sample_data_banner` on every tab and cards carry the
///   `sample_data_chip` (`SampleChip`).
/// * **Contained:** sample data never reaches Apple Health, cloud sync, the export archive, the widgets or the
///   coach — each of those paths asks `SampleDataStore.isActive` (or `MeasurementSource.mock`, which every
///   seeded reading carries) before it writes. It holds no blood pressure, blood sugar or lipids.
/// * **Temporary:** it is wiped the moment a real ring connects (`wipeForRealRing`), and can be cleared from
///   Settings (`clear`). Only the profile the user entered during onboarding is kept.
///
/// Built on `SeedData.seedDemo(sample: true)`. The ordinary demo seed (`demo_data` flag, `-seedDemo` in debug)
/// does not switch this on.
@MainActor
@Observable
final class SampleDataStore {
    static let shared = SampleDataStore()

    /// UserDefaults key: the sample set is loaded. New key, not install-bound.
    static let activeKey = "agara.sampleDataActive"
    /// UserDefaults key: the user tapped "Explore without ring" and has not paired yet. Read once, at the end of onboarding.
    static let exploringKey = "agara.exploreWithoutRing"

    private let defaults: UserDefaults
    private(set) var isActive: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isActive = defaults.bool(forKey: Self.activeKey)
    }

    /// Non-isolated read for code that isn't on the main actor (export guards): the same defaults key.
    nonisolated static var isActiveNow: Bool { UserDefaults.standard.bool(forKey: activeKey) }

    // MARK: Onboarding intent

    /// "Explore without ring" was tapped: remember it until onboarding finishes.
    func markExploring() { defaults.set(true, forKey: Self.exploringKey) }
    /// A ring was paired instead: forget the intent.
    func clearExploring() { defaults.removeObject(forKey: Self.exploringKey) }
    var wantsSampleData: Bool { defaults.bool(forKey: Self.exploringKey) }

    // MARK: Load / clear

    /// Load the sample set once onboarding is done. No-op when a ring is already paired or it is already loaded.
    func activateIfExploring(context: ModelContext) {
        guard wantsSampleData else { return }
        clearExploring()
        guard !isActive, MetricsService.fetchDevices(context).isEmpty else { return }
        SeedData.seedDemo(context, completeOnboarding: true, sample: true)
        setActive(true)
        AgaraDataChange.shared.notify()
    }

    /// Settings › "Clear sample data".
    func clear(context: ModelContext) {
        guard isActive else { return }
        removeSampleRows(context)
        setActive(false)
        AgaraDataChange.shared.notify()
    }

    /// A real ring connected: the sample rows must be gone before its first sync writes anything.
    /// Returns true when it wiped something.
    @discardableResult
    func wipeForRealRing(context: ModelContext) -> Bool {
        clearExploring()
        guard isActive else { return false }
        removeSampleRows(context)
        setActive(false)
        return true
    }

    /// After a full wipe removed the defaults keys: drop the cached flag.
    func resetInMemory() { isActive = false }

    private func setActive(_ value: Bool) {
        isActive = value
        defaults.set(value, forKey: Self.activeKey)
    }

    /// Every data table except the profile and goals: while the sample set is active nothing else in the store is
    /// a real reading (there is no ring), so the wipe is total for data and leaves the user's profile alone.
    private func removeSampleRows(_ context: ModelContext) {
        SeedData.clearData(context, keepingProfile: true)
    }
}
