import Foundation
import SwiftData

/// Structured, product-invisible diagnostics for wearable connections and syncs. Records
/// connection / sync / error / battery events with optional JSON metadata — the engineering
/// backbone that lets us debug protocol issues without ever surfacing opcodes/hex in the product UI.
///
/// This is distinct from `RawPacketRow` (the raw byte trace, DEBUG-only) — `WearableLog` is the
/// higher-level human-readable timeline that ships in the diagnostics export.
@Model
final class WearableLog {
    // Audit batch B: retention prune and the diagnostics timeline read by timestamp.
    #Index<WearableLog>([\.timestamp])
    @Attribute(.unique) var id: UUID
    // The hash modifier makes an upgraded store migrate, which is what creates the new index there.
    @Attribute(hashModifier: "idx-2026-09") var timestamp: Date
    var deviceTypeRaw: String
    var categoryRaw: String
    var levelRaw: String
    var message: String
    var metadataJSON: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = AppClock.now,
        deviceType: RingDeviceType? = nil,
        category: WearableLogCategory,
        level: WearableLogLevel,
        message: String,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.deviceTypeRaw = deviceType?.rawValue ?? ""
        self.categoryRaw = category.rawValue
        self.levelRaw = level.rawValue
        self.message = message
        self.metadataJSON = metadataJSON
    }

    var category: WearableLogCategory { WearableLogCategory(rawValue: categoryRaw) ?? .connection }
    var level: WearableLogLevel { WearableLogLevel(rawValue: levelRaw) ?? .info }
}

enum WearableLogCategory: String, Codable, CaseIterable {
    case connection
    case sync
    case error
    case battery
}

enum WearableLogLevel: String, Codable, CaseIterable {
    case info
    case warn
    case error
}
