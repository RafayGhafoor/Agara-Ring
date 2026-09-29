import Foundation
import SwiftData

/// Which page card a summary backs. `sleepRange` carries the selected range.
enum CoachSummaryKind: Equatable {
    case today
    case sleepDay
    case sleepRange(SleepRangeKey)

    var rawValue: String {
        switch self {
        case .today: return "today"
        case .sleepDay: return "sleep_day"
        case .sleepRange(let range): return "sleep_range_\(range.rawValue)"
        }
    }

    /// Human title for the seeded conversation.
    var conversationTitle: String {
        switch self {
        case .today: return "Today recap"
        case .sleepDay: return "Sleep recap"
        case .sleepRange: return "Sleep trend"
        }
    }
}

/// A persisted, LLM-generated coach card shown on Today/Sleep. One row per
/// (kind, scopeKey), upserted as data changes. `dataSignature` detects new data;
/// `conversationId` links the chat thread seeded on first tap.
@Model
final class CoachSummary {
    @Attribute(.unique) var id: UUID
    var kind: String
    var scopeKey: String
    var title: String
    var body: String
    var chipsJSON: String?
    var conversationId: UUID?
    var dataSignature: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: String,
        scopeKey: String,
        title: String,
        body: String,
        chips: [String] = [],
        dataSignature: String
    ) {
        self.id = id
        self.kind = kind
        self.scopeKey = scopeKey
        self.title = title
        self.body = body
        self.chipsJSON = Self.encodeChips(chips)
        self.conversationId = nil
        self.dataSignature = dataSignature
        self.createdAt = AppClock.now
        self.updatedAt = AppClock.now
    }

    var chips: [String] {
        guard let chipsJSON, let data = chipsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    func apply(_ content: CoachSummaryContent, signature: String, now: Date = AppClock.now) {
        title = content.title
        body = content.body
        chipsJSON = Self.encodeChips(content.chips)
        dataSignature = signature
        updatedAt = now
    }

    static func encodeChips(_ chips: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(chips) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
