#if DEBUG
import Foundation
import SwiftData

/// UI-test tooling (`-fakeCloud YES -fakeCloudSeedBlocks N`): give the app N sealed days of ring heart-rate readings so a
/// sync against the fake backend has real (non-sample) blocks to upload. DEBUG builds only.
enum FakeCloudSeed {
    @MainActor private static var done = false
    @MainActor
    static func apply(container: ModelContainer, now: Date = AppClock.now) {
        let days = DebugLaunch.integer("fakeCloudSeedBlocks")
        guard DebugLaunch.bool("fakeCloud"), days > 0, !done else { return }
        done = true
        let context = container.mainContext
        let today = BlockStore.today(now: now)
        for i in 0..<days {
            let day = today - 12 - Int64(i)
            for j in 0..<40 {
                context.insert(Measurement(kind: .heartRate, value: Double(58 + j % 30), unit: "bpm",
                                           timestamp: BlockStore.date(ms: day * AGB.dayMs + 3_600_000 + Int64(j) * 60_000),
                                           source: .live, sensorId: "a3a04cab4846d63c"))
            }
        }
        try? context.save()
        _ = StorageMaintenance.compactAll(now: now, context: context)
    }
}
#endif
