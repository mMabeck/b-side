import Foundation

/// The three states the upstream backend distinguishes, plus a distinct
/// presentation of completion when the run did not succeed.
public enum ChildRunState: Sendable, Equatable {
    case active
    case blocked
    case completed
    case failed
}

/// One tool call row, keyed by the `toolCallId` its assistant message part
/// carried. `line` is formatted once, when the call's name and arguments
/// first arrive on `message_end`; later `tool_execution_*`/`toolResult`
/// events only update `state`.
public struct ToolCallRow: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var line: String
    public var state: ToolCallRowState = .running
}

public enum ToolCallRowState: Sendable, Equatable {
    case running
    case completed
    case failed
}

/// One child's accumulated state, keyed by a stable child id and scoped to
/// the task that spawned it. Persists after the child finishes so a
/// completed run can be read afterwards.
public struct ChildRun: Identifiable, Sendable, Equatable {
    public let id: String
    public let taskId: Int64
    public var agent: String
    public var taskLabel: String
    public var openingLine: String?
    public var toolCallRows: [ToolCallRow] = []
    public var state: ChildRunState = .active
    public var statistics = RunStatistics()
    public var errorMessage: String?
    public let startedAt: Date
    public var endedAt: Date?

    public init(
        id: String,
        taskId: Int64,
        agent: String,
        taskLabel: String,
        openingLine: String? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.agent = agent
        self.taskLabel = taskLabel
        self.openingLine = openingLine
        self.startedAt = startedAt
    }

    /// Convenience view over `toolCallRows` for callers that only care about
    /// display text (the card view, and tests building fixtures directly).
    public var toolLines: [String] {
        get { toolCallRows.map(\.line) }
        set {
            toolCallRows = newValue.enumerated().map { offset, line in
                ToolCallRow(id: "\(offset)", name: "", line: line, state: .completed)
            }
        }
    }
}
