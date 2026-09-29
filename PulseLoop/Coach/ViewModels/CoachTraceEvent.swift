import Foundation

/// In-process progress event emitted by the orchestrator (the iOS replacement
/// for the web app's WebSocket `coach_trace` stream). The view model collects
/// these to show "Reading today's data…" style status while a turn runs.
struct CoachTraceEvent: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case thinking
        case runningTool
        case completedTool
        case failedTool
        case writingAnswer
        case done
    }

    let id: UUID
    let timestamp: Date
    let label: String
    let toolName: String?
    let status: Status

    init(label: String, status: Status, toolName: String? = nil) {
        self.id = UUID()
        self.timestamp = AppClock.now
        self.label = label
        self.toolName = toolName
        self.status = status
    }
}

/// A persisted record of one executed tool call (transparency trace).
struct CoachToolCallTrace: Sendable {
    let toolName: String
    let label: String
    let status: String          // "success" | "error"
    let argsRedacted: String
    let resultSummary: String
    let startedAt: Date
    let finishedAt: Date
}
