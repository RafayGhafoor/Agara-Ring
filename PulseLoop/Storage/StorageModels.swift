import Foundation
import SwiftData

// Phase-3 storage models (docs/ring/storage-format.md §11, docs/process/plans/store-launch/storage-compression.md §5).
// Adding entities is a lightweight SwiftData migration; nothing here retypes an existing attribute.

/// One AGB block: every point of one series for one UTC day (`block_key = v1/<metric>/<source>/<sensor>/<day>`).
/// Columns are exactly the spec's `measurement_blocks` DDL (Android's Room entity has the same fields).
/// `sealed == false` is a derived snapshot (the hot rows stay the source of truth); `sealed == true` is the
/// source of truth for that day and its rows are gone. `state` 0 ok · 1 skipped (unknown version/codec) ·
/// 2 quarantined (corrupt) — a non-zero state block is never a merge input and never deleted.
@Model
final class MeasurementBlock {
    #Index<MeasurementBlock>([\.metric, \.utcDay])
    @Attribute(.unique) var blockKey: String
    var metric: String
    var source: String
    var sensorId: String
    var utcDay: Int
    var sealed: Bool
    var state: Int
    var reason: String?
    var n: Int?
    var tFirst: Int64?
    var tLast: Int64?
    var vMin: Double?
    var vMax: Double?
    var vSum: Double?
    var fmtMajor: Int?
    var fmtMinor: Int?
    var codec: Int?
    var crc32: Int64?
    /// The container, verbatim.
    var data: Data
    var createdAt: Int64
    var updatedAt: Int64

    init(blockKey: String, metric: String, source: String, sensorId: String, utcDay: Int, sealed: Bool, data: Data, now: Int64) {
        self.blockKey = blockKey
        self.metric = metric
        self.source = source
        self.sensorId = sensorId
        self.utcDay = utcDay
        self.sealed = sealed
        self.state = 0
        self.data = data
        self.createdAt = now
        self.updatedAt = now
    }
}

/// The ledger (`block_sync`): the authority for a block's `revision` and `content_hash`, and the "unsynced data"
/// guard for the storage cap. A block is unsynced iff `syncedHash == nil || syncedHash != contentHash`. With the
/// cloud off (1.0) every block simply stays unsynced.
@Model
final class BlockSync {
    @Attribute(.unique) var blockKey: String
    var revision: Int
    /// 32 bytes.
    var contentHash: Data
    var syncedRevision: Int?
    var syncedHash: Data?
    var syncedAt: Int64?
    var updatedAt: Int64

    init(blockKey: String, revision: Int, contentHash: Data, now: Int64) {
        self.blockKey = blockKey
        self.revision = revision
        self.contentHash = contentHash
        self.updatedAt = now
    }

    var isSynced: Bool { syncedHash != nil && syncedHash == contentHash }
}

/// A raw BLE packet as bytes (replaces `RawPacketRow`'s hex text: half the size and no UUID). A diagnostic
/// window, never block-compressed. The old entity stays declared for one release so an upgraded store still
/// opens; its rows are converted into these by `StorageMaintenance` and then deleted.
@Model
final class RawPacketRecord {
    #Index<RawPacketRecord>([\.timestamp])
    var timestamp: Date
    var directionRaw: String
    var commandId: Int
    var payload: Data
    var decodedKind: String?
    var decodedJSON: String?
    var confidenceRaw: String

    init(
        timestamp: Date = AppClock.now,
        direction: PacketDirection,
        commandId: Int,
        payload: Data,
        decodedKind: String? = nil,
        decodedJSON: String? = nil,
        confidence: DecodeConfidence = .unknown
    ) {
        self.timestamp = timestamp
        self.directionRaw = direction.rawValue
        self.commandId = commandId
        self.payload = payload
        self.decodedKind = decodedKind
        self.decodedJSON = decodedJSON
        self.confidenceRaw = confidence.rawValue
    }

    /// Hex-text convenience (archives, the Debug feed and the sleep repair speak hex).
    convenience init(
        timestamp: Date = AppClock.now,
        direction: PacketDirection,
        commandId: Int,
        hexPayload: String,
        decodedKind: String? = nil,
        decodedJSON: String? = nil,
        confidence: DecodeConfidence = .unknown
    ) {
        self.init(timestamp: timestamp, direction: direction, commandId: commandId,
                  payload: (try? Data(hexString: hexPayload)) ?? Data(), decodedKind: decodedKind,
                  decodedJSON: decodedJSON, confidence: confidence)
    }

    var hexPayload: String { payload.hexString }
    var direction: PacketDirection { PacketDirection(rawValue: directionRaw) ?? .incoming }
    var confidence: DecodeConfidence { DecodeConfidence(rawValue: confidenceRaw) ?? .unknown }
}
