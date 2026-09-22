import Foundation
import Testing

@testable import DashNativeKit

@MainActor
@Suite("SubagentFeedStore")
struct SubagentFeedStoreTests {
    private func toolCallMessageEnd(id: String, name: String, arguments: [String: JSONValue] = [:]) -> SubagentEvent {
        .messageEnd(role: "assistant", stopReason: nil, errorMessage: nil, toolCalls: [
            SubagentToolCall(id: id, name: name, arguments: arguments),
        ], text: nil)
    }

    @Test("A registered run starts active")
    func startsActive() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        #expect(store.runs(forTask: 1).first?.state == .active)
    }

    @Test("A question tool call marks the run blocked, not active")
    func questionToolBlocks() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "question"))
        #expect(store.runs(forTask: 1).first?.state == .blocked)
    }

    @Test("Question detection is case-insensitive and falls back to a tool field")
    func questionDetectionCaseInsensitive() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "Question"))
        #expect(store.runs(forTask: 1).first?.state == .blocked)
    }

    @Test("A non-question tool call after a question unblocks the run")
    func nonQuestionToolUnblocks() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "question"))
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "2", name: "bash", arguments: ["command": .string("ls")]))
        #expect(store.runs(forTask: 1).first?.state == .active)
    }

    @Test("done with exitCode 0 marks the run completed")
    func doneCompletesSuccessfully() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.markDone(taskId: 1, childId: "c1", payload: SubagentDonePayload(exitCode: 0, stopReason: "stop", errorMessage: nil))
        #expect(store.runs(forTask: 1).first?.state == .completed)
    }

    @Test("done with a non-zero exitCode marks the run failed")
    func doneWithNonZeroExitCodeFails() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.markDone(taskId: 1, childId: "c1", payload: SubagentDonePayload(exitCode: 1, stopReason: "stop", errorMessage: "boom"))
        let run = store.runs(forTask: 1).first
        #expect(run?.state == .failed)
        #expect(run?.errorMessage == "boom")
    }

    @Test("done with stopReason error marks the run failed even with exitCode 0")
    func doneWithErrorStopReasonFails() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.markDone(taskId: 1, childId: "c1", payload: SubagentDonePayload(exitCode: 0, stopReason: "error", errorMessage: nil))
        #expect(store.runs(forTask: 1).first?.state == .failed)
    }

    @Test("A completed run persists in the store for later reading")
    func completedRunPersists() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.markDone(taskId: 1, childId: "c1", payload: SubagentDonePayload(exitCode: 0, stopReason: "stop", errorMessage: nil))
        #expect(store.runs(forTask: 1).count == 1)
        #expect(store.runs(forTask: 1).first?.state == .completed)
    }

    @Test("An assistant tool-call part appends a formatted line from its arguments")
    func toolCallPartAppendsLine() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "bash", arguments: ["command": .string("ls")]))
        #expect(store.runs(forTask: 1).first?.toolLines == ["$ ls"])
    }

    @Test("A tool_execution_end for a toolCallId with no prior message_end does not fabricate a row")
    func executionEventAloneDoesNotFabricateRow() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: .toolExecutionEnd(toolCallId: "1", toolName: "bash"))
        #expect(store.runs(forTask: 1).first?.toolLines == [])
    }

    @Test("A tool_execution_end for a known toolCallId marks its row completed without duplicating it")
    func executionEndCompletesKnownRow() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "bash", arguments: ["command": .string("ls")]))
        store.ingest(taskId: 1, childId: "c1", event: .toolExecutionEnd(toolCallId: "1", toolName: "bash"))
        let run = store.runs(forTask: 1).first
        #expect(run?.toolLines == ["$ ls"])
        #expect(run?.toolCallRows.first?.state == .completed)
    }

    @Test("A toolResult with isError marks the matching row and the run failed")
    func toolResultErrorMarksRowAndRunFailed() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "bash", arguments: ["command": .string("ls")]))
        store.ingest(taskId: 1, childId: "c1", event: .toolResult(toolCallId: "1", isError: true))
        let run = store.runs(forTask: 1).first
        #expect(run?.toolCallRows.first?.state == .failed)
        #expect(run?.state == .failed)
    }

    @Test("clear removes all runs for a task")
    func clearRemovesRuns() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.clear(taskId: 1)
        #expect(store.runs(forTask: 1).isEmpty)
    }

    @Test("summary reports active count and whether any child is blocked")
    func summaryReportsActiveAndBlocked() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "A")
        store.beginRun(taskId: 1, childId: "c2", agent: "builder", taskLabel: "B")
        store.ingest(taskId: 1, childId: "c2", event: toolCallMessageEnd(id: "1", name: "question"))

        let summary = store.summary(forTask: 1)
        #expect(summary.totalCount == 2)
        #expect(summary.activeCount == 1)
        #expect(summary.isBlocked == true)
    }
}
