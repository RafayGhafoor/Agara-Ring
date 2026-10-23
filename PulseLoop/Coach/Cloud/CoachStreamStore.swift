import Foundation
import Observation

/// The answer the Agara Cloud coach is writing right now (2026-10-23): its title and summary as the server streams them
/// (contract §7, `event: delta`). The Coach tab shows this preview while the turn runs; the validated answer replaces it
/// when the turn finishes, so the preview never has to be right — only early.
@MainActor
@Observable
final class CoachStreamStore {
    static let shared = CoachStreamStore()

    private(set) var title = ""
    private(set) var summary = ""

    /// Something is worth showing.
    var hasPreview: Bool { !title.isEmpty || !summary.isEmpty }

    /// One `delta` event's payload: `{"field": "title" | "summary", "text": "<appended text>"}`.
    func apply(delta data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let field = json["field"] as? String, let text = json["text"] as? String else { return }
        switch field {
        case "title": title += text
        case "summary": summary += text
        default: break
        }
    }

    /// A new question, or the turn ended: the preview is gone.
    func reset() {
        title = ""
        summary = ""
    }
}
