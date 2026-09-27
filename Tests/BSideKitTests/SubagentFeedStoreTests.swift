import Foundation
import Testing

@testable import BSideKit

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

    @Test("done's exitCode and stopReason determine the run's final state, surviving in the store afterward", arguments: [
        (exitCode: 0, stopReason: "stop", priorToolError: false, expectedState: ChildRunState.completed),
        (exitCode: 1, stopReason: "stop", priorToolError: false, expectedState: ChildRunState.failed),
        (exitCode: 0, stopReason: "error", priorToolError: false, expectedState: ChildRunState.failed),
        (exitCode: 0, stopReason: "stop", priorToolError: true, expectedState: ChildRunState.completed),
    ])
    func doneDeterminesFinalState(exitCode: Int, stopReason: String, priorToolError: Bool, expectedState: ChildRunState) {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        if priorToolError {
            store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "bash", arguments: ["command": .string("find / -path foo")]))
            store.ingest(taskId: 1, childId: "c1", event: .toolResult(toolCallId: "1", isError: true))
        }
        store.markDone(taskId: 1, childId: "c1", payload: SubagentDonePayload(exitCode: exitCode, stopReason: stopReason, errorMessage: expectedState == .failed && exitCode != 0 ? "boom" : nil))
        let run = store.runs(forTask: 1).first
        #expect(run?.state == expectedState)
        #expect(store.runs(forTask: 1).count == 1)
        if expectedState == .failed, exitCode != 0 {
            #expect(run?.errorMessage == "boom")
        }
    }

    @Test("An assistant tool-call part appends a formatted line from its arguments")
    func toolCallPartAppendsLine() {
        let store = SubagentFeedStore()
        store.beginRun(taskId: 1, childId: "c1", agent: "explorer", taskLabel: "Map cache callers")
        store.ingest(taskId: 1, childId: "c1", event: toolCallMessageEnd(id: "1", name: "bash", arguments: ["command": .string("ls")]))
        #expect(store.runs(forTask: 1).first?.toolLines == ["$ ls"])
    }
}
