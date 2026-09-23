import Foundation
import OSLog

/// Observable store of child runs, keyed by task and then by a stable child
/// id. This is the one feed both the Subagents tab's cards and (later) native
/// splits are meant to render from — everything here is presentation-free.
@MainActor
@Observable
public final class SubagentFeedStore {
    private static let logger = Logger(subsystem: "ai.syv.bside", category: "subagent-feed")

    public private(set) var runsByTask: [Int64: [ChildRun]] = [:]

    public init() {}

    /// Runs for `taskId`, oldest first.
    public func runs(forTask taskId: Int64) -> [ChildRun] {
        runsByTask[taskId] ?? []
    }

    /// Summary for the left sidebar's task row: how many children are
    /// currently running, and whether any is blocked on the user.
    public func summary(forTask taskId: Int64) -> TaskChildSummary {
        let runs = runsByTask[taskId] ?? []
        let active = runs.filter { $0.state == .active }.count
        let blocked = runs.contains { $0.state == .blocked }
        return TaskChildSummary(activeCount: active, totalCount: runs.count, isBlocked: blocked)
    }

    /// Registers a child run, called once a child is known to have launched.
    /// Idempotent: re-registering an existing id updates its labels in place
    /// rather than duplicating the card.
    public func beginRun(
        taskId: Int64,
        childId: String,
        agent: String,
        taskLabel: String,
        openingLine: String? = nil,
        startedAt: Date = Date()
    ) {
        var runs = runsByTask[taskId] ?? []
        if let index = runs.firstIndex(where: { $0.id == childId }) {
            runs[index].agent = agent
            runs[index].taskLabel = taskLabel
            runs[index].openingLine = openingLine
        } else {
            runs.append(ChildRun(
                id: childId,
                taskId: taskId,
                agent: agent,
                taskLabel: taskLabel,
                openingLine: openingLine,
                startedAt: startedAt
            ))
        }
        runsByTask[taskId] = runs
    }

    /// Applies one decoded event to the named child, creating a placeholder
    /// run if none was registered yet (events can race registration). Tool
    /// rows are created only from a `message_end` assistant tool-call part —
    /// `tool_execution_*`/`toolResult` events for an unrecognised
    /// `toolCallId` update nothing and fabricate no row.
    public func ingest(taskId: Int64, childId: String, event: SubagentEvent) {
        mutate(taskId: taskId, childId: childId) { run in
            switch event {
            case let .messageEnd(role, stopReason, errorMessage, toolCalls, text):
                if role == "assistant" {
                    if let text, !text.isEmpty {
                        run.latestAssistantText = text
                    }
                    for call in toolCalls {
                        guard let id = call.id, let name = call.name else { continue }
                        let line = ToolCallLineFormatter.format(toolName: name, args: call.arguments)
                        if let index = run.toolCallRows.firstIndex(where: { $0.id == id }) {
                            run.toolCallRows[index].name = name
                            run.toolCallRows[index].line = line
                        } else {
                            run.toolCallRows.append(ToolCallRow(id: id, name: name, line: line))
                            run.statistics.turns += 1
                        }
                        if isQuestionTool(name) {
                            run.state = .blocked
                        } else if run.state == .blocked {
                            run.state = .active
                        }
                    }
                }
                if let stopReason, stopReason == "error" {
                    run.state = .failed
                    run.errorMessage = errorMessage
                }
            case let .toolResult(toolCallId, isError):
                guard let toolCallId, let index = run.toolCallRows.firstIndex(where: { $0.id == toolCallId }) else { return }
                run.toolCallRows[index].state = isError ? .failed : .completed
                if isError {
                    run.state = .failed
                }
            case let .toolExecutionUpdate(toolCallId, toolName), let .toolExecutionEnd(toolCallId, toolName):
                guard let toolCallId, let index = run.toolCallRows.firstIndex(where: { $0.id == toolCallId }) else { return }
                if case .toolExecutionEnd = event {
                    run.toolCallRows[index].state = .completed
                }
                let name = toolName ?? run.toolCallRows[index].name
                if isQuestionTool(name) {
                    run.state = .blocked
                } else if run.state == .blocked {
                    run.state = .active
                }
            }
        }
    }

    /// Applies the `done.json` payload: `exitCode != 0` or `stopReason ==
    /// "error"` present as `failed`; anything else present as `completed`.
    public func markDone(taskId: Int64, childId: String, payload: SubagentDonePayload, endedAt: Date = Date()) {
        mutate(taskId: taskId, childId: childId) { run in
            let failed = (payload.exitCode ?? 0) != 0 || payload.stopReason == "error"
            run.state = failed ? .failed : .completed
            run.endedAt = endedAt
            if failed { run.errorMessage = payload.errorMessage ?? run.errorMessage }
        }
    }

    /// Clears all runs for a task, called when its conversation clears.
    public func clear(taskId: Int64) {
        runsByTask.removeValue(forKey: taskId)
    }

    private func isQuestionTool(_ toolName: String?) -> Bool {
        toolName?.lowercased() == "question"
    }

    private func mutate(taskId: Int64, childId: String, _ transform: (inout ChildRun) -> Void) {
        var runs = runsByTask[taskId] ?? []
        if let index = runs.firstIndex(where: { $0.id == childId }) {
            transform(&runs[index])
        } else {
            Self.logger.notice("Event for unregistered child \(childId, privacy: .public); creating placeholder run")
            var run = ChildRun(id: childId, taskId: taskId, agent: "agent", taskLabel: "")
            transform(&run)
            runs.append(run)
        }
        runsByTask[taskId] = runs
    }
}

/// Per-task rollup consumed by the left sidebar's task row.
public struct TaskChildSummary: Sendable, Equatable {
    public var activeCount: Int
    public var totalCount: Int
    public var isBlocked: Bool

    public var hasChildren: Bool { totalCount > 0 }
}
