import Foundation

public enum ChildRunState: Sendable, Equatable {
    case active
    case blocked
    case completed
    case failed
}

/// `line` is formatted once, on `message_end`; later events only update `state`.
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
    public var latestAssistantText: String?
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

    public var toolLines: [String] {
        get { toolCallRows.map(\.line) }
        set {
            toolCallRows = newValue.enumerated().map { offset, line in
                ToolCallRow(id: "\(offset)", name: "", line: line, state: .completed)
            }
        }
    }
}
