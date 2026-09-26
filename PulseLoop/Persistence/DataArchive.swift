import Foundation
import SwiftData

// The full-app export archive: a versioned, Codable snapshot of every SwiftData model plus the
// UserDefaults settings blobs and coach attachment images. Exported as gzip-compressed JSON
// (`agara-export-<date>.json.gz`, streamed row by row — see `DataArchiveService`); the JSON inside
// stays plain so users can analyze their data outside the app (gunzip + jq / pandas).
//
// Cross-platform format (audit 2026-09-26, Batch B): the JSON is Android's `AgaraArchive`
// (`ArchiveCodec.kt`) — same top-level keys, same row field names, epoch-millisecond timestamps, and
// Android's enum spellings for the values both apps interpret (`kindRaw` "HEART_RATE", sleep
// `stageRaw` "LIGHT", log category/level "SYNC"/"INFO"). iOS-only fields ride along as extra keys
// (Android ignores unknown keys), and the importer still reads every older iOS archive (ISO-8601 dates,
// `activityDailies` / `activityBucketSamples` / `activitySensorPollEvents`, `attachmentsJSON`,
// `message`/`metadataJSON`, unix-second bucket keys, iOS enum spellings).
//
// Design rules (see `DataArchiveService` for the read/write side):
// - Every DTO mirrors its model's stored raw fields verbatim (`kindRaw`, `stateRaw`, `*JSON`
//   strings pass through opaquely) so unknown future enum values survive a round trip.
// - All UUIDs (ids and loose foreign keys) are preserved exactly — the models have no
//   `@Relationship` edges, so identity is the only thing holding the graphs together.
// - Import assigns every stored property directly instead of trusting model inits: several inits
//   re-derive fields from the *current* calendar/timezone (`ActivityDaily.date`,
//   `ActivityBucketSample.date`), which would corrupt cross-timezone restores.
// - When a model gains a stored property, mirror it here — the round-trip unit test only
//   guards fields that exist in the DTO.
// - Types are `nonisolated` (the project defaults to MainActor isolation) so encode/decode can run
//   off the main actor; the model-facing mappers are `@MainActor` because `@Model` classes are not.

// MARK: - Envelope

/// The decoded archive (import side). The export never builds one of these — it streams rows straight
/// to the file (`DataArchiveService.writeArchive`) — so this type only needs to *read* both the current
/// (Android-shaped) layout and every older iOS one.
nonisolated struct AgaraArchive: Decodable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    /// Per-table row counts — informational (keyed by Android table name in new files, by entity key in old ones).
    var counts: [String: Int]

    var devices: [ArchiveDevice]
    var activityDailies: [ArchiveActivityDaily]
    var measurements: [ArchiveMeasurement]
    var batterySamples: [ArchiveBatterySample]
    var sleepSessions: [ArchiveSleepSession]
    var sleepStageBlocks: [ArchiveSleepStageBlock]
    var rawPackets: [ArchiveRawPacket]
    var derivedUpdates: [ArchiveDerivedUpdate]
    var userProfiles: [ArchiveUserProfile]
    var userGoals: [ArchiveUserGoal]
    var deviceMeasurementConfigs: [ArchiveDeviceMeasurementConfig]
    var activitySessions: [ArchiveActivitySession]
    var activitySamples: [ArchiveActivitySample]
    var activityBucketSamples: [ArchiveActivityBucketSample]
    var activityGpsPoints: [ArchiveActivityGpsPoint]
    var activityEvents: [ArchiveActivityEvent]
    var activitySensorPollEvents: [ArchiveActivitySensorPollEvent]
    var coachConversations: [ArchiveCoachConversation]
    var coachMessages: [ArchiveCoachMessage]
    var coachMemories: [ArchiveCoachMemory]
    var coachToolCalls: [ArchiveCoachToolCall]
    var coachNotificationRecords: [ArchiveCoachNotificationRecord]
    var coachSummaries: [ArchiveCoachSummary]
    var wearableLogs: [ArchiveWearableLog]
    var mealEntries: [ArchiveMealEntry]
    var foodProducts: [ArchiveFoodProduct]

    /// Raw UserDefaults JSON blobs keyed by their storage key (metric prefs, workout prefs,
    /// calibration, coach settings, Apple Health prefs). Opaque pass-through — never re-encoded.
    /// Nil when the file has no `settings` key (an Android archive): the import then leaves this
    /// device's settings alone instead of resetting them.
    var settings: [String: String]?
    /// `Documents/coach_attachments/*` image files, base64-encoded. Nil for an Android archive.
    var attachments: [ArchiveAttachment]?

    /// Archive keys: Android's names first; the old iOS spelling second where they differ.
    enum Key: String, CodingKey {
        case formatVersion, exportedAt, appVersion, counts
        case devices, measurements, batterySamples, sleepSessions, sleepStageBlocks, rawPackets,
             derivedUpdates, userProfiles, userGoals, deviceMeasurementConfigs, activitySessions,
             activitySamples, activityGpsPoints, activityEvents, coachConversations, coachMessages,
             coachMemories, coachToolCalls, coachNotificationRecords, coachSummaries, wearableLogs,
             mealEntries, foodProducts, measurementDeletions, settings, attachments
        case activityDaily, activityDailies
        case activityBuckets, activityBucketSamples
        case activitySensorPolls, activitySensorPollEvents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func list<T: Decodable>(_ key: Key, or legacy: Key? = nil) throws -> [T] {
            if let rows = try c.decodeIfPresent([T].self, forKey: key) { return rows }
            if let legacy, let rows = try c.decodeIfPresent([T].self, forKey: legacy) { return rows }
            return []
        }
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        // Required, like Android's `AgaraArchive`: a file with only a version is not an archive.
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        devices = try list(.devices)
        activityDailies = try list(.activityDaily, or: .activityDailies)
        measurements = try list(.measurements)
        batterySamples = try list(.batterySamples)
        sleepSessions = try list(.sleepSessions)
        sleepStageBlocks = try list(.sleepStageBlocks)
        rawPackets = try list(.rawPackets)
        derivedUpdates = try list(.derivedUpdates)
        userProfiles = try list(.userProfiles)
        userGoals = try list(.userGoals)
        deviceMeasurementConfigs = try list(.deviceMeasurementConfigs)
        activitySessions = try list(.activitySessions)
        activitySamples = try list(.activitySamples)
        activityBucketSamples = try list(.activityBuckets, or: .activityBucketSamples)
        activityGpsPoints = try list(.activityGpsPoints)
        activityEvents = try list(.activityEvents)
        activitySensorPollEvents = try list(.activitySensorPolls, or: .activitySensorPollEvents)
        coachConversations = try list(.coachConversations)
        coachMessages = try list(.coachMessages)
        coachMemories = try list(.coachMemories)
        coachToolCalls = try list(.coachToolCalls)
        coachNotificationRecords = try list(.coachNotificationRecords)
        coachSummaries = try list(.coachSummaries)
        wearableLogs = try list(.wearableLogs)
        mealEntries = try list(.mealEntries)
        foodProducts = try list(.foodProducts)
        // `measurementDeletions` (Android's tombstones) has no iOS model yet — read past it.
        settings = try c.decodeIfPresent([String: String].self, forKey: .settings)
        attachments = try c.decodeIfPresent([ArchiveAttachment].self, forKey: .attachments)
    }
}

/// Value spellings shared with Android's archive. Android persists enum *names* ("HEART_RATE",
/// "LIGHT", "SYNC"); iOS persists raw values ("hr", "light", "sync"). The archive carries Android's
/// spelling; import maps either spelling back to iOS's.
nonisolated enum ArchiveInterop {
    /// iOS `MeasurementKind.rawValue` → Android `MeasurementKind.name`.
    static let androidKindNames: [String: String] = [
        "hr": "HEART_RATE", "spo2": "SPO2", "stress": "STRESS", "fatigue": "FATIGUE", "hrv": "HRV",
        "temp": "TEMPERATURE", "bp_sys": "BLOOD_PRESSURE_SYSTOLIC", "bp_dia": "BLOOD_PRESSURE_DIASTOLIC",
        "glucose": "BLOOD_SUGAR", "resp_rate": "RESPIRATORY_RATE", "vo2max": "VO2MAX", "met": "MET",
        "cardiac_load": "CARDIAC_LOAD", "total_cholesterol": "TOTAL_CHOLESTEROL",
        "triglycerides": "TRIGLYCERIDES", "hdl": "HDL", "ldl": "LDL", "uric_acid": "URIC_ACID",
    ]
    static let iosKindKeys: [String: String] = Dictionary(uniqueKeysWithValues: androidKindNames.map { ($1, $0) })

    static func exportKind(_ raw: String) -> String { androidKindNames[raw] ?? raw }
    static func importKind(_ raw: String) -> String { iosKindKeys[raw] ?? raw }

    /// Enums that differ only in case (sleep stage, log category / level).
    static func exportCaseEnum(_ raw: String) -> String { raw.uppercased() }
    static func importCaseEnum(_ raw: String) -> String { raw.lowercased() }

    /// A row id as a UUID. Android's raw-packet ids are integers ("42"); any string that isn't a UUID
    /// maps to a stable name-based one, so every reference to the same id still lands on the same row.
    static func uuid(_ string: String) -> UUID {
        if let id = UUID(uuidString: string) { return id }
        var bytes = [UInt8](repeating: 0, count: 16)
        // Two FNV-1a 64 passes (different offsets) → 128 bits; stamped as an RFC 4122 v5-style UUID.
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in string.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i))) }
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Bucket keys: Android stores epoch milliseconds, iOS unix seconds. Anything past year 5138 in
    /// seconds is really milliseconds.
    static func bucketSeconds(_ value: Int64) -> Int {
        Int(value > 100_000_000_000 ? value / 1000 : value)
    }
}

/// Minimal first-pass decode used to give a clear "newer app version" error before attempting the
/// full (and stricter) archive decode.
nonisolated struct ArchiveVersionProbe: Codable, Sendable {
    var formatVersion: Int
}

nonisolated struct ArchiveAttachment: Codable, Sendable {
    /// Filename within `coach_attachments/` (e.g. `<uuid>.jpg`) — referenced by
    /// `CoachMessage.attachmentsJSON`, so it must survive unchanged.
    var file: String
    var base64: String
}

// MARK: - JSON coding

/// Shared encoder/decoder configuration for the archive. Dates are written as epoch milliseconds
/// (Android's `Long` timestamps); the decoder reads those and the ISO-8601 strings (with or without
/// a fraction) every earlier iOS archive carried.
nonisolated enum ArchiveCoding {
    // ISO8601DateFormatter is documented thread-safe, so sharing one instance across the detached
    // encode/decode tasks is sound.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(millis(date))
        }
        return encoder
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let ms = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            let string = try container.decode(String.self)
            if let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }
}

// MARK: - Entity DTOs

nonisolated struct ArchiveDevice: Codable, Sendable {
    var id: UUID
    var name: String
    var advertisedName: String?
    var peripheralIdentifier: String?
    var bleAddressHint: String?
    var batteryPercent: Int?
    var stateRaw: String
    var lastConnectedAt: Date?
    var lastDisconnectedAt: Date?
    var lastSyncAt: Date?
    var lastFullSyncAt: Date?
    var firmwareVersion: String?
    var wearableModelID: String?
    /// Optional so archives written before ring naming still decode.
    var nickname: String?
    var deviceTypeRaw: String
    var capabilitiesRaw: String
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: Device) {
        id = m.id
        name = m.name
        advertisedName = m.advertisedName
        peripheralIdentifier = m.peripheralIdentifier
        bleAddressHint = m.bleAddressHint
        batteryPercent = m.batteryPercent
        stateRaw = m.stateRaw
        lastConnectedAt = m.lastConnectedAt
        lastDisconnectedAt = m.lastDisconnectedAt
        lastSyncAt = m.lastSyncAt
        lastFullSyncAt = m.lastFullSyncAt
        firmwareVersion = m.firmwareVersion
        wearableModelID = m.wearableModelID
        nickname = m.nickname
        deviceTypeRaw = m.deviceTypeRaw
        capabilitiesRaw = m.capabilitiesRaw
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = Device()
        m.id = id
        m.name = name
        m.advertisedName = advertisedName
        m.peripheralIdentifier = peripheralIdentifier
        m.bleAddressHint = bleAddressHint
        m.batteryPercent = batteryPercent
        m.stateRaw = stateRaw
        m.lastConnectedAt = lastConnectedAt
        m.lastDisconnectedAt = lastDisconnectedAt
        m.lastSyncAt = lastSyncAt
        m.lastFullSyncAt = lastFullSyncAt
        m.firmwareVersion = firmwareVersion
        m.wearableModelID = wearableModelID
        m.nickname = nickname
        m.deviceTypeRaw = deviceTypeRaw
        m.capabilitiesRaw = capabilitiesRaw
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityDaily: Codable, Sendable {
    var id: UUID
    var date: Date
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var activeMinutes: Int
    var source: String
    var syncedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Optional: absent from older iOS archives.
    var estimatedActiveCalories: Double?

    @MainActor init(_ m: ActivityDaily) {
        id = m.id
        date = m.date
        steps = m.steps
        calories = m.calories
        distanceMeters = m.distanceMeters
        activeMinutes = m.activeMinutes
        source = m.source
        syncedAt = m.syncedAt
        createdAt = m.createdAt
        updatedAt = m.updatedAt
        estimatedActiveCalories = m.estimatedActiveCalories
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityDaily(date: date)
        m.id = id
        m.date = date   // init re-derives startOfDay in the local timezone; restore the exact value
        m.steps = steps
        m.calories = calories
        m.distanceMeters = distanceMeters
        m.activeMinutes = activeMinutes
        m.source = source
        m.syncedAt = syncedAt
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        m.estimatedActiveCalories = estimatedActiveCalories
        context.insert(m)
    }
}

nonisolated struct ArchiveMeasurement: Codable, Sendable {
    var id: UUID
    var kindRaw: String
    var value: Double
    var unit: String
    var timestamp: Date
    var sourceRaw: String
    var confidenceRaw: String
    var activitySessionId: UUID?
    /// A string, not a UUID: Android's raw-packet ids are integers. Mapped with `ArchiveInterop.uuid`.
    var rawPacketId: String?
    var createdAt: Date

    @MainActor init(_ m: PulseLoop.Measurement) {
        id = m.id
        kindRaw = ArchiveInterop.exportKind(m.kindRaw)
        value = m.value
        unit = m.unit
        timestamp = m.timestamp
        sourceRaw = m.sourceRaw
        confidenceRaw = m.confidenceRaw
        activitySessionId = m.activitySessionId
        rawPacketId = m.rawPacketId?.uuidString
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = PulseLoop.Measurement(kind: .heartRate, value: value, unit: unit, timestamp: timestamp)
        m.id = id
        m.kindRaw = ArchiveInterop.importKind(kindRaw)
        m.sourceRaw = sourceRaw
        m.confidenceRaw = confidenceRaw
        m.activitySessionId = activitySessionId
        m.rawPacketId = rawPacketId.map(ArchiveInterop.uuid)
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveBatterySample: Codable, Sendable {
    var id: UUID
    var percent: Int
    var timestamp: Date
    var createdAt: Date

    @MainActor init(_ m: BatterySample) {
        id = m.id
        percent = m.percent
        timestamp = m.timestamp
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = BatterySample(percent: percent, timestamp: timestamp)
        m.id = id
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveSleepSession: Codable, Sendable {
    var id: UUID
    var date: Date
    var startAt: Date
    var endAt: Date
    var totalMinutes: Int
    var score: Int?
    var syncedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Optional, so archives written before sleep was source-stamped still decode (as unsourced).
    var sourceAddress: String?
    /// Android's session origin ("ring"). iOS has no such column: written as "ring", ignored on import.
    var sourceRaw: String?

    @MainActor init(_ m: SleepSession) {
        id = m.id
        date = m.date
        startAt = m.startAt
        endAt = m.endAt
        totalMinutes = m.totalMinutes
        score = m.score
        syncedAt = m.syncedAt
        createdAt = m.createdAt
        updatedAt = m.updatedAt
        sourceAddress = m.sourceAddress
        sourceRaw = "ring"
    }

    @MainActor func insert(into context: ModelContext) {
        let m = SleepSession(date: date, startAt: startAt, endAt: endAt, totalMinutes: totalMinutes, score: score,
                             syncedAt: syncedAt, sourceAddress: sourceAddress)
        m.id = id
        m.date = date   // init re-derives startOfDay in the local timezone; restore the exact value
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveSleepStageBlock: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var startAt: Date
    var startMinute: Int
    var durationMinutes: Int
    var stageRaw: String
    /// Optional, so archives written before sleep was source-stamped still decode (as unsourced).
    var recordStartAt: Date?
    var sourceAddress: String?

    @MainActor init(_ m: SleepStageBlock) {
        id = m.id
        sessionId = m.sessionId
        startAt = m.startAt
        startMinute = m.startMinute
        durationMinutes = m.durationMinutes
        stageRaw = ArchiveInterop.exportCaseEnum(m.stageRaw)
        recordStartAt = m.recordStartAt
        sourceAddress = m.sourceAddress
    }

    @MainActor func insert(into context: ModelContext) {
        // Android writes 0 for "unknown record start" (its column is non-null); iOS models that as nil.
        let recordStart = recordStartAt.flatMap { $0.timeIntervalSince1970 == 0 ? nil : $0 }
        let m = SleepStageBlock(sessionId: sessionId, startAt: startAt, startMinute: startMinute, durationMinutes: durationMinutes,
                                stage: .unknown, recordStartAt: recordStart, sourceAddress: sourceAddress)
        m.id = id
        m.stageRaw = ArchiveInterop.importCaseEnum(stageRaw)
        context.insert(m)
    }
}

nonisolated struct ArchiveRawPacket: Codable, Sendable {
    /// A string: Android's raw-packet ids are integers. Mapped with `ArchiveInterop.uuid` on import.
    var id: String
    var timestamp: Date
    var directionRaw: String
    var commandId: Int
    var hexPayload: String
    var decodedKind: String?
    var decodedJSON: String?
    var confidenceRaw: String
    var createdAt: Date

    @MainActor init(_ m: RawPacketRow) {
        id = m.id.uuidString
        timestamp = m.timestamp
        directionRaw = m.directionRaw
        commandId = m.commandId
        hexPayload = m.hexPayload
        decodedKind = m.decodedKind
        decodedJSON = m.decodedJSON
        confidenceRaw = m.confidenceRaw
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = RawPacketRow(timestamp: timestamp, direction: .incoming, commandId: commandId, hexPayload: hexPayload, decodedKind: decodedKind, decodedJSON: decodedJSON)
        m.id = ArchiveInterop.uuid(id)
        m.directionRaw = directionRaw
        m.confidenceRaw = confidenceRaw
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveDerivedUpdate: Codable, Sendable {
    var id: UUID
    var timestamp: Date
    var kind: String
    var entityType: String
    var entityId: String
    var payloadJSON: String?

    @MainActor init(_ m: DerivedUpdateRow) {
        id = m.id
        timestamp = m.timestamp
        kind = m.kind
        entityType = m.entityType
        entityId = m.entityId
        payloadJSON = m.payloadJSON
    }

    @MainActor func insert(into context: ModelContext) {
        let m = DerivedUpdateRow(timestamp: timestamp, kind: kind, entityType: entityType, entityId: entityId, payloadJSON: payloadJSON)
        m.id = id
        context.insert(m)
    }
}

nonisolated struct ArchiveUserProfile: Codable, Sendable {
    var id: UUID
    var name: String?
    var age: Int?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
    // iOS-only fields are optional so an Android archive (which lacks them) still decodes; nil keeps
    // the model's default.
    var unitsRaw: String?
    var onboardingCompleted: Bool
    var baselineCompleted: Bool
    var athleteMode: Bool?
    var altitudeMeters: Double?
    var usesBetaBlockers: Bool?
    var hasKnownLungCondition: Bool?
    var preferredGlucoseUnitRaw: String?
    var hrZoneModeRaw: String
    var hrRestingBaseline: Double?
    var hrRestingBaselineUpdatedAt: Date?
    var hrCustomLowUpper: Double?
    var hrCustomAthleticUpper: Double?
    var hrCustomElevatedStart: Double?
    var hrCustomHighStart: Double?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: UserProfile) {
        id = m.id
        name = m.name
        age = m.age
        sex = m.sex
        heightCm = m.heightCm
        weightKg = m.weightKg
        unitsRaw = m.unitsRaw
        onboardingCompleted = m.onboardingCompleted
        baselineCompleted = m.baselineCompleted
        athleteMode = m.athleteMode
        altitudeMeters = m.altitudeMeters
        usesBetaBlockers = m.usesBetaBlockers
        hasKnownLungCondition = m.hasKnownLungCondition
        preferredGlucoseUnitRaw = m.preferredGlucoseUnitRaw
        hrZoneModeRaw = m.hrZoneModeRaw
        hrRestingBaseline = m.hrRestingBaseline
        hrRestingBaselineUpdatedAt = m.hrRestingBaselineUpdatedAt
        hrCustomLowUpper = m.hrCustomLowUpper
        hrCustomAthleticUpper = m.hrCustomAthleticUpper
        hrCustomElevatedStart = m.hrCustomElevatedStart
        hrCustomHighStart = m.hrCustomHighStart
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = UserProfile()
        m.id = id
        m.name = name
        m.age = age
        m.sex = sex
        m.heightCm = heightCm
        m.weightKg = weightKg
        if let unitsRaw { m.unitsRaw = unitsRaw }
        m.onboardingCompleted = onboardingCompleted
        m.baselineCompleted = baselineCompleted
        if let athleteMode { m.athleteMode = athleteMode }
        m.altitudeMeters = altitudeMeters
        m.usesBetaBlockers = usesBetaBlockers
        m.hasKnownLungCondition = hasKnownLungCondition
        if let preferredGlucoseUnitRaw { m.preferredGlucoseUnitRaw = preferredGlucoseUnitRaw }
        m.hrZoneModeRaw = hrZoneModeRaw
        m.hrRestingBaseline = hrRestingBaseline
        m.hrRestingBaselineUpdatedAt = hrRestingBaselineUpdatedAt
        m.hrCustomLowUpper = hrCustomLowUpper
        m.hrCustomAthleticUpper = hrCustomAthleticUpper
        m.hrCustomElevatedStart = hrCustomElevatedStart
        m.hrCustomHighStart = hrCustomHighStart
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveUserGoal: Codable, Sendable {
    var id: UUID
    var steps: Int
    var sleepMinutes: Int
    var activeMinutes: Int
    var workoutsPerWeek: Int
    var distanceMeters: Double
    var calories: Int
    var updatedAt: Date
    // Intake goals (Android: Double?; iOS stores whole numbers). Optional for older archives.
    var intakeCalories: Double?
    var intakeProteinG: Double?
    var intakeCarbsG: Double?
    var intakeFatG: Double?

    @MainActor init(_ m: UserGoal) {
        id = m.id
        steps = m.steps
        sleepMinutes = m.sleepMinutes
        activeMinutes = m.activeMinutes
        workoutsPerWeek = m.workoutsPerWeek
        distanceMeters = m.distanceMeters
        calories = m.calories
        updatedAt = m.updatedAt
        intakeCalories = m.intakeCalories.map(Double.init)
        intakeProteinG = m.intakeProteinG.map(Double.init)
        intakeCarbsG = m.intakeCarbsG.map(Double.init)
        intakeFatG = m.intakeFatG.map(Double.init)
    }

    @MainActor func insert(into context: ModelContext) {
        let m = UserGoal(id: id, steps: steps, sleepMinutes: sleepMinutes, activeMinutes: activeMinutes, workoutsPerWeek: workoutsPerWeek, distanceMeters: distanceMeters, calories: calories)
        m.intakeCalories = intakeCalories.map { Int($0.rounded()) }
        m.intakeProteinG = intakeProteinG.map { Int($0.rounded()) }
        m.intakeCarbsG = intakeCarbsG.map { Int($0.rounded()) }
        m.intakeFatG = intakeFatG.map { Int($0.rounded()) }
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveDeviceMeasurementConfig: Codable, Sendable {
    var deviceId: UUID
    var hrIntervalMinutes: Int
    var hrEnabled: Bool
    var spo2Enabled: Bool
    var stressEnabled: Bool
    var hrvEnabled: Bool
    var temperatureEnabled: Bool
    var updatedAt: Date

    @MainActor init(_ m: DeviceMeasurementConfig) {
        deviceId = m.deviceId
        hrIntervalMinutes = m.hrIntervalMinutes
        hrEnabled = m.hrEnabled
        spo2Enabled = m.spo2Enabled
        stressEnabled = m.stressEnabled
        hrvEnabled = m.hrvEnabled
        temperatureEnabled = m.temperatureEnabled
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = DeviceMeasurementConfig(deviceId: deviceId)
        m.hrIntervalMinutes = hrIntervalMinutes
        m.hrEnabled = hrEnabled
        m.spo2Enabled = spo2Enabled
        m.stressEnabled = stressEnabled
        m.hrvEnabled = hrvEnabled
        m.temperatureEnabled = temperatureEnabled
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivitySession: Codable, Sendable {
    var id: UUID
    var type: String
    var statusRaw: String
    var startedAt: Date
    var endedAt: Date?
    var totalPauseSeconds: Double
    var calories: Double?
    var distanceMeters: Double?
    var avgHeartRate: Double?
    var minHeartRate: Double?
    var maxHeartRate: Double?
    var avgSpO2: Double?
    var latestSpO2: Double?
    var notes: String?
    var useGps: Bool
    var perceivedEffort: String?
    var gpsPointCount: Int
    var rejectedGpsPointCount: Int
    var hrPollCount: Int
    var hrPollFailureCount: Int
    var spo2PollCount: Int
    var spo2PollFailureCount: Int
    var liveActivityID: String?
    var lastSensorPollAt: Date?
    var lastGpsPointAt: Date?
    /// iOS-only; optional so an Android archive decodes.
    var vitalsModeRaw: String?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: ActivitySession) {
        id = m.id
        type = m.type
        statusRaw = m.statusRaw
        startedAt = m.startedAt
        endedAt = m.endedAt
        totalPauseSeconds = m.totalPauseSeconds
        calories = m.calories
        distanceMeters = m.distanceMeters
        avgHeartRate = m.avgHeartRate
        minHeartRate = m.minHeartRate
        maxHeartRate = m.maxHeartRate
        avgSpO2 = m.avgSpO2
        latestSpO2 = m.latestSpO2
        notes = m.notes
        useGps = m.useGps
        perceivedEffort = m.perceivedEffort
        gpsPointCount = m.gpsPointCount
        rejectedGpsPointCount = m.rejectedGpsPointCount
        hrPollCount = m.hrPollCount
        hrPollFailureCount = m.hrPollFailureCount
        spo2PollCount = m.spo2PollCount
        spo2PollFailureCount = m.spo2PollFailureCount
        liveActivityID = m.liveActivityID
        lastSensorPollAt = m.lastSensorPollAt
        lastGpsPointAt = m.lastGpsPointAt
        vitalsModeRaw = m.vitalsModeRaw
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivitySession(
            type: type, startedAt: startedAt, endedAt: endedAt, totalPauseSeconds: totalPauseSeconds,
            calories: calories, distanceMeters: distanceMeters, notes: notes, useGps: useGps
        )
        m.id = id
        m.statusRaw = statusRaw
        m.avgHeartRate = avgHeartRate
        m.minHeartRate = minHeartRate
        m.maxHeartRate = maxHeartRate
        m.avgSpO2 = avgSpO2
        m.latestSpO2 = latestSpO2
        m.perceivedEffort = perceivedEffort
        m.gpsPointCount = gpsPointCount
        m.rejectedGpsPointCount = rejectedGpsPointCount
        m.hrPollCount = hrPollCount
        m.hrPollFailureCount = hrPollFailureCount
        m.spo2PollCount = spo2PollCount
        m.spo2PollFailureCount = spo2PollFailureCount
        m.liveActivityID = liveActivityID
        m.lastSensorPollAt = lastSensorPollAt
        m.lastGpsPointAt = lastGpsPointAt
        if let vitalsModeRaw { m.vitalsModeRaw = vitalsModeRaw }
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivitySample: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var measurementId: UUID?
    var kind: String
    var value: Double
    var unit: String
    var timestamp: Date
    var source: String
    var confidenceRaw: String

    @MainActor init(_ m: ActivitySample) {
        id = m.id
        sessionId = m.sessionId
        measurementId = m.measurementId
        kind = m.kind
        value = m.value
        unit = m.unit
        timestamp = m.timestamp
        source = m.source
        confidenceRaw = m.confidenceRaw
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivitySample(sessionId: sessionId, measurementId: measurementId, kind: kind, value: value, unit: unit, timestamp: timestamp, source: source)
        m.id = id
        m.confidenceRaw = confidenceRaw
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityBucketSample: Codable, Sendable {
    /// Epoch **milliseconds** in the file (Android's key); older iOS archives hold unix seconds —
    /// `ArchiveInterop.bucketSeconds` reads either.
    var startEpoch: Int64
    var date: Date
    /// iOS-only; an Android archive derives it from `startEpoch`.
    var timestamp: Date?
    var steps: Int
    var distanceMeters: Double
    var source: String
    var updatedAt: Date

    /// The stored unique key (unix seconds), whichever unit the file used.
    var startSeconds: Int { ArchiveInterop.bucketSeconds(startEpoch) }

    @MainActor init(_ m: ActivityBucketSample) {
        startEpoch = Int64(m.startEpoch) * 1000
        date = m.date
        timestamp = m.timestamp
        steps = m.steps
        distanceMeters = m.distanceMeters
        source = m.source
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let instant = timestamp ?? Date(timeIntervalSince1970: TimeInterval(startSeconds))
        let m = ActivityBucketSample(timestamp: instant, steps: steps, distanceMeters: distanceMeters, source: source)
        // The init re-derives startEpoch/date from the local timezone; restore the exact stored
        // values — startEpoch is the unique upsert key.
        m.startEpoch = startSeconds
        m.date = date
        m.timestamp = instant
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityGpsPoint: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var horizontalAccuracy: Double?
    var speed: Double?
    var course: Double?
    var timestamp: Date
    var accepted: Bool
    var rejectionReason: String?

    @MainActor init(_ m: ActivityGpsPoint) {
        id = m.id
        sessionId = m.sessionId
        latitude = m.latitude
        longitude = m.longitude
        altitude = m.altitude
        horizontalAccuracy = m.horizontalAccuracy
        speed = m.speed
        course = m.course
        timestamp = m.timestamp
        accepted = m.accepted
        rejectionReason = m.rejectionReason
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityGpsPoint(
            id: id, sessionId: sessionId, latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, speed: speed, course: course, timestamp: timestamp,
            accepted: accepted, rejectionReason: rejectionReason
        )
        context.insert(m)
    }
}

nonisolated struct ArchiveActivityEvent: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var kind: String
    var timestamp: Date
    var payloadJSON: String?

    @MainActor init(_ m: ActivityEvent) {
        id = m.id
        sessionId = m.sessionId
        kind = m.kind
        timestamp = m.timestamp
        payloadJSON = m.payloadJSON
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivityEvent(id: id, sessionId: sessionId, kind: kind, timestamp: timestamp, payloadJSON: payloadJSON)
        context.insert(m)
    }
}

nonisolated struct ArchiveActivitySensorPollEvent: Codable, Sendable {
    var id: UUID
    var sessionId: UUID
    var timestamp: Date
    var kind: String
    var status: String
    var value: Double?
    var errorMessage: String?

    @MainActor init(_ m: ActivitySensorPollEvent) {
        id = m.id
        sessionId = m.sessionId
        timestamp = m.timestamp
        kind = m.kind
        status = m.status
        value = m.value
        errorMessage = m.errorMessage
    }

    @MainActor func insert(into context: ModelContext) {
        let m = ActivitySensorPollEvent(id: id, sessionId: sessionId, timestamp: timestamp, kind: kind, status: status, value: value, errorMessage: errorMessage)
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachConversation: Codable, Sendable {
    var id: UUID
    var title: String
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCostUSD: Double
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: CoachConversation) {
        id = m.id
        title = m.title
        totalInputTokens = m.totalInputTokens
        totalOutputTokens = m.totalOutputTokens
        totalCostUSD = m.totalCostUSD
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachConversation(id: id, title: title)
        m.totalInputTokens = totalInputTokens
        m.totalOutputTokens = totalOutputTokens
        m.totalCostUSD = totalCostUSD
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachMessage: Codable, Sendable {
    var id: UUID
    var conversationId: UUID
    var role: String
    var body: String
    var cardsJSON: String?
    var pendingActionJSON: String?
    /// Written as Android's `attachmentsJson`; `legacyAttachmentsJSON` reads older iOS archives.
    var attachmentsJSON: String?
    var legacyAttachmentsJSON: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var modelUsed: String?
    var providerUsed: String?
    var loggedActivityIdsJSON: String?
    /// iOS-only; absent from older archives.
    var loggedMealIdsJSON: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, conversationId, role, body, cardsJSON, pendingActionJSON, inputTokens, outputTokens,
             costUSD, modelUsed, providerUsed, loggedActivityIdsJSON, loggedMealIdsJSON, createdAt
        case attachmentsJSON = "attachmentsJson"
        case legacyAttachmentsJSON = "attachmentsJSON"
    }

    @MainActor init(_ m: CoachMessage) {
        id = m.id
        conversationId = m.conversationId
        role = m.role
        body = m.body
        cardsJSON = m.cardsJSON
        pendingActionJSON = m.pendingActionJSON
        attachmentsJSON = m.attachmentsJSON
        inputTokens = m.inputTokens
        outputTokens = m.outputTokens
        costUSD = m.costUSD
        modelUsed = m.modelUsed
        providerUsed = m.providerUsed
        loggedActivityIdsJSON = m.loggedActivityIdsJSON
        loggedMealIdsJSON = m.loggedMealIdsJSON
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachMessage(
            id: id, conversationId: conversationId, role: role, body: body, cardsJSON: cardsJSON,
            pendingActionJSON: pendingActionJSON, attachmentsJSON: attachmentsJSON ?? legacyAttachmentsJSON,
            inputTokens: inputTokens, outputTokens: outputTokens, costUSD: costUSD,
            modelUsed: modelUsed, providerUsed: providerUsed,
            loggedActivityIdsJSON: loggedActivityIdsJSON, loggedMealIdsJSON: loggedMealIdsJSON, createdAt: createdAt
        )
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachMemory: Codable, Sendable {
    var id: UUID
    var key: String
    var value: String
    var memoryType: String
    var importance: Int
    var expiresAt: Date?
    var sourceMessageId: UUID?
    var isUserEditable: Bool
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: CoachMemory) {
        id = m.id
        key = m.key
        value = m.value
        memoryType = m.memoryType
        importance = m.importance
        expiresAt = m.expiresAt
        sourceMessageId = m.sourceMessageId
        isUserEditable = m.isUserEditable
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachMemory(id: id, key: key, value: value, memoryType: memoryType, importance: importance, expiresAt: expiresAt, sourceMessageId: sourceMessageId, isUserEditable: isUserEditable)
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachToolCall: Codable, Sendable {
    var id: UUID
    var conversationId: UUID
    var messageId: UUID?
    var toolName: String
    var inputJSON: String?
    var outputJSON: String?
    var label: String
    var statusRaw: String
    var sequence: Int
    var createdAt: Date

    @MainActor init(_ m: CoachToolCall) {
        id = m.id
        conversationId = m.conversationId
        messageId = m.messageId
        toolName = m.toolName
        inputJSON = m.inputJSON
        outputJSON = m.outputJSON
        label = m.label
        statusRaw = m.statusRaw
        sequence = m.sequence
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachToolCall(
            id: id, conversationId: conversationId, messageId: messageId, toolName: toolName,
            inputJSON: inputJSON, outputJSON: outputJSON, label: label, statusRaw: statusRaw, sequence: sequence
        )
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachNotificationRecord: Codable, Sendable {
    var id: UUID
    // iOS-only; optional so an Android archive decodes (slot → morning, day → the local creation day).
    var slotRaw: String?
    var dateKey: String?
    var title: String
    var body: String
    var createdAt: Date

    @MainActor init(_ m: CoachNotificationRecord) {
        id = m.id
        slotRaw = m.slotRaw
        dateKey = m.dateKey
        title = m.title
        body = m.body
        createdAt = m.createdAt
    }

    @MainActor func insert(into context: ModelContext) {
        let day: String = dateKey ?? {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: createdAt)
        }()
        let m = CoachNotificationRecord(id: id, slotRaw: slotRaw ?? "morning", dateKey: day, title: title, body: body)
        m.createdAt = createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveCoachSummary: Codable, Sendable {
    var id: UUID
    var kind: String
    var scopeKey: String
    var title: String
    var body: String
    var chipsJSON: String?
    var conversationId: UUID?
    var dataSignature: String
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ m: CoachSummary) {
        id = m.id
        kind = m.kind
        scopeKey = m.scopeKey
        title = m.title
        body = m.body
        chipsJSON = m.chipsJSON
        conversationId = m.conversationId
        dataSignature = m.dataSignature
        createdAt = m.createdAt
        updatedAt = m.updatedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CoachSummary(id: id, kind: kind, scopeKey: scopeKey, title: title, body: body, dataSignature: dataSignature)
        m.chipsJSON = chipsJSON
        m.conversationId = conversationId
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        context.insert(m)
    }
}

/// Android's field names: `event` (the message), `detail` (metadata JSON), `deviceId` (device type),
/// upper-case category/level. The `legacy*` fields read the names older iOS archives used.
nonisolated struct ArchiveWearableLog: Codable, Sendable {
    var id: UUID
    var timestamp: Date
    var event: String?
    var detail: String?
    var deviceId: String?
    var categoryRaw: String?
    var levelRaw: String?
    var legacyMessage: String?
    var legacyMetadataJSON: String?
    var legacyDeviceTypeRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, event, detail, deviceId, categoryRaw, levelRaw
        case legacyMessage = "message"
        case legacyMetadataJSON = "metadataJSON"
        case legacyDeviceTypeRaw = "deviceTypeRaw"
    }

    @MainActor init(_ m: WearableLog) {
        id = m.id
        timestamp = m.timestamp
        event = m.message
        detail = m.metadataJSON
        deviceId = m.deviceTypeRaw
        categoryRaw = ArchiveInterop.exportCaseEnum(m.categoryRaw)
        levelRaw = ArchiveInterop.exportCaseEnum(m.levelRaw)
    }

    @MainActor func insert(into context: ModelContext) {
        let m = WearableLog(id: id, timestamp: timestamp, category: .connection, level: .info,
                            message: event ?? legacyMessage ?? "", metadataJSON: detail ?? legacyMetadataJSON)
        m.deviceTypeRaw = deviceId ?? legacyDeviceTypeRaw ?? ""
        m.categoryRaw = ArchiveInterop.importCaseEnum(categoryRaw ?? WearableLogCategory.connection.rawValue)
        m.levelRaw = ArchiveInterop.importCaseEnum(levelRaw ?? WearableLogLevel.info.rawValue)
        context.insert(m)
    }
}

// MARK: - Nutrition (Android's `mealEntries` / `foodProducts`)

nonisolated struct ArchiveMealEntry: Codable, Sendable {
    var id: UUID
    var date: Date
    var timestamp: Date
    var name: String
    var mealTypeRaw: String
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double?
    var sugarG: Double?
    var sodiumMg: Double?
    var sourceRaw: String
    var offProductCode: String?
    var servingDescription: String?
    var servingGrams: Double?
    var quantity: Double
    var confidenceRaw: String
    var userEdited: Bool
    var notes: String?
    var loggedByCoach: Bool
    var createdAt: Date
    /// Optional: Android archives before its phase 6 lack it (then `createdAt`).
    var updatedAt: Date?
    /// iOS-only: the photo reference the meal was logged from.
    var photoRefJSON: String?

    @MainActor init(_ m: MealEntry) {
        id = m.id
        date = m.date
        timestamp = m.timestamp
        name = m.name
        mealTypeRaw = m.mealTypeRaw
        calories = m.calories
        proteinG = m.proteinG
        carbsG = m.carbsG
        fatG = m.fatG
        fiberG = m.fiberG
        sugarG = m.sugarG
        sodiumMg = m.sodiumMg
        sourceRaw = m.sourceRaw
        offProductCode = m.offProductCode
        servingDescription = m.servingDescription
        servingGrams = m.servingGrams
        quantity = m.quantity
        confidenceRaw = m.confidenceRaw
        userEdited = m.userEdited
        notes = m.notes
        loggedByCoach = m.loggedByCoach
        createdAt = m.createdAt
        updatedAt = m.updatedAt
        photoRefJSON = m.photoRefJSON
    }

    @MainActor func insert(into context: ModelContext) {
        let m = MealEntry(id: id, timestamp: timestamp, name: name, mealType: .snack, calories: calories)
        m.date = date   // init re-derives startOfDay in the local timezone; restore the exact value
        m.mealTypeRaw = mealTypeRaw
        m.proteinG = proteinG
        m.carbsG = carbsG
        m.fatG = fatG
        m.fiberG = fiberG
        m.sugarG = sugarG
        m.sodiumMg = sodiumMg
        m.sourceRaw = sourceRaw
        m.offProductCode = offProductCode
        m.servingDescription = servingDescription
        m.servingGrams = servingGrams
        m.quantity = quantity
        m.confidenceRaw = confidenceRaw
        m.userEdited = userEdited
        m.notes = notes
        m.loggedByCoach = loggedByCoach
        m.photoRefJSON = photoRefJSON
        m.createdAt = createdAt
        m.updatedAt = (updatedAt?.timeIntervalSince1970 ?? 0) > 0 ? updatedAt! : createdAt
        context.insert(m)
    }
}

nonisolated struct ArchiveFoodProduct: Codable, Sendable {
    var code: String
    var name: String
    var brand: String?
    var energyKcal100g: Double
    var protein100g: Double
    var carbs100g: Double
    var fat100g: Double
    var fiber100g: Double?
    var sugars100g: Double?
    var saturatedFat100g: Double?
    var sodiumMg100g: Double?
    var servingSizeText: String?
    var servingQuantityG: Double?
    var lastUsedAt: Date
    var useCount: Int
    /// iOS-only.
    var fetchedAt: Date?

    @MainActor init(_ m: CachedFoodProduct) {
        code = m.code
        name = m.name
        brand = m.brand
        energyKcal100g = m.energyKcal100g
        protein100g = m.protein100g
        carbs100g = m.carbs100g
        fat100g = m.fat100g
        fiber100g = m.fiber100g
        sugars100g = m.sugars100g
        saturatedFat100g = m.saturatedFat100g
        sodiumMg100g = m.sodiumMg100g
        servingSizeText = m.servingSizeText
        servingQuantityG = m.servingQuantityG
        lastUsedAt = m.lastUsedAt
        useCount = m.useCount
        fetchedAt = m.fetchedAt
    }

    @MainActor func insert(into context: ModelContext) {
        let m = CachedFoodProduct(
            code: code, name: name, brand: brand, energyKcal100g: energyKcal100g, protein100g: protein100g,
            carbs100g: carbs100g, fat100g: fat100g, fiber100g: fiber100g, sugars100g: sugars100g,
            saturatedFat100g: saturatedFat100g, sodiumMg100g: sodiumMg100g, servingSizeText: servingSizeText,
            servingQuantityG: servingQuantityG
        )
        m.lastUsedAt = lastUsedAt
        m.useCount = useCount
        m.fetchedAt = fetchedAt ?? lastUsedAt
        context.insert(m)
    }
}
