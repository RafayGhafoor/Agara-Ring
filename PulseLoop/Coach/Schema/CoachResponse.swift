import Foundation

/// Structured coach reply, ported from the web app's `CoachResponseBody`
/// (`backend/app/schemas/coach.py`). The model is constrained to emit exactly
/// this shape via OpenAI Structured Outputs (see `CoachResponseSchema`).
///
/// Keys are snake_case on the wire (matching the web contract); explicit
/// `CodingKeys` keep that mapping self-contained rather than relying on a global
/// decoder strategy.
struct CoachResponse: Codable, Equatable {
    var responseType: CoachResponseType
    var title: String
    var summary: String
    var bullets: [String]
    var chart: CoachChart?
    var safetyNote: String?
    var dataQualityNote: String?
    var sources: [CoachSource]
    var followUpChips: [String]
    var actionsTaken: [String]
    var confidence: CoachConfidence
    /// Forward-compatible structured cards. Not part of the v1 strict schema, so
    /// the model does not emit these yet; decoded leniently when present.
    var cards: [CoachCard]

    enum CodingKeys: String, CodingKey {
        case responseType = "response_type"
        case title
        case summary
        case bullets
        case chart
        case safetyNote = "safety_note"
        case dataQualityNote = "data_quality_note"
        case sources
        case followUpChips = "follow_up_chips"
        case actionsTaken = "actions_taken"
        case confidence
        case cards
    }

    init(
        responseType: CoachResponseType,
        title: String,
        summary: String,
        bullets: [String] = [],
        chart: CoachChart? = nil,
        safetyNote: String? = nil,
        dataQualityNote: String? = nil,
        sources: [CoachSource] = [],
        followUpChips: [String] = [],
        actionsTaken: [String] = [],
        confidence: CoachConfidence = .medium,
        cards: [CoachCard] = []
    ) {
        self.responseType = responseType
        self.title = title
        self.summary = summary
        self.bullets = bullets
        self.chart = chart
        self.safetyNote = safetyNote
        self.dataQualityNote = dataQualityNote
        self.sources = sources
        self.followUpChips = followUpChips
        self.actionsTaken = actionsTaken
        self.confidence = confidence
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        responseType = try c.decode(CoachResponseType.self, forKey: .responseType)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        bullets = try c.decodeIfPresent([String].self, forKey: .bullets) ?? []
        chart = try c.decodeIfPresent(CoachChart.self, forKey: .chart)
        safetyNote = Self.note(try c.decodeIfPresent(String.self, forKey: .safetyNote))
        dataQualityNote = Self.note(try c.decodeIfPresent(String.self, forKey: .dataQualityNote))
        sources = try c.decodeIfPresent([CoachSource].self, forKey: .sources) ?? []
        followUpChips = try c.decodeIfPresent([String].self, forKey: .followUpChips) ?? []
        actionsTaken = try c.decodeIfPresent([String].self, forKey: .actionsTaken) ?? []
        confidence = try c.decodeIfPresent(CoachConfidence.self, forKey: .confidence) ?? .medium
        cards = try c.decodeIfPresent([CoachCard].self, forKey: .cards) ?? []
    }

    /// A small local model sometimes serialises a missing optional as the STRING "null" (or "nil"), which the note row
    /// then showed as a warning reading "null" (Hayden's 2026-10-24 screenshot). Treat those as absent, like a real null.
    private static func note(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "null", "nil", "none", "n/a", "undefined":
            return nil
        default:
            return text
        }
    }

    // MARK: - Persistence helpers (CoachMessage.cardsJSON)

    /// Human-readable text stored in `CoachMessage.body` as a render-independent
    /// fallback (used if structured rendering ever fails to decode).
    var plainText: String {
        var parts = [summary]
        if !bullets.isEmpty { parts.append(bullets.map { "• \($0)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(fromJSON json: String?) -> CoachResponse? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachResponse.self, from: data)
    }
}

enum CoachResponseType: String, Codable {
    case insight
    case insightWithChart = "insight_with_chart"
    case question
    case actionConfirmation = "action_confirmation"
    case dataMissing = "data_missing"
    case safetyGuidance = "safety_guidance"
    case errorRecovery = "error_recovery"
}

enum CoachConfidence: String, Codable {
    case low, medium, high
}

struct CoachSource: Codable, Equatable, Identifiable {
    var title: String
    var url: String
    var publisher: String
    var id: String { url + title }
}

/// Forward-compatible structured card (deferred past Milestone A). Kept minimal
/// and lenient so older/newer payloads never break decoding.
struct CoachCard: Codable, Equatable, Identifiable {
    var kind: String
    var title: String?
    var body: String?
    var id: String { kind + (title ?? "") + (body ?? "") }
}
