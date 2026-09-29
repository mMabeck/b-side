import Foundation
import Testing

@testable import BSideKit

@Suite("SubagentStripRenderer")
struct SubagentStripRendererTests {
    private func makeRun(id: String, agent: String = "explorer", label: String = "Task", state: ChildRunState = .active, tools: [String] = []) -> ChildRun {
        var run = ChildRun(id: id, taskId: 1, agent: agent, taskLabel: label, startedAt: Date(timeIntervalSinceReferenceDate: 0))
        run.toolLines = tools
        run.state = state
        if state == .completed || state == .failed {
            run.endedAt = Date(timeIntervalSinceReferenceDate: 10)
        }
        return run
    }

    @Test("A single run renders the fixed row count, top-to-bottom border then label row")
    func singleRunRowCount() {
        let run = makeRun(id: "c1")
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date(timeIntervalSinceReferenceDate: 5))
        #expect(result.lines.count == SubagentStripRenderer.totalRowCount)
        #expect(result.slots.count == 1)
        #expect(result.slots[0].childId == "c1")
    }

    @Test("Cards below the minimum width are dropped and counted as '+N more' in the label row")
    func overflowCardsCountedAsMore() {
        let runs = (0..<10).map { makeRun(id: "c\($0)") }
        let result = SubagentStripRenderer.render(runs: runs, viewedChildId: nil, columns: 80, now: Date())
        #expect(result.slots.count < runs.count)
        let labelLine = result.lines[SubagentStripRenderer.cardRowCount]
        #expect(labelLine.contains("more"))
    }

    @Test("Each run state renders its own status row text", arguments: [
        (state: ChildRunState.active, now: 18.0, expectedSubstrings: ["working", "18s"]),
        (state: ChildRunState.blocked, now: 7.0, expectedSubstrings: ["waiting for you"]),
        (state: ChildRunState.completed, now: 999.0, expectedSubstrings: ["done", "10s"]),
        (state: ChildRunState.failed, now: 0.0, expectedSubstrings: ["failed"]),
    ])
    func statusRowReflectsRunState(state: ChildRunState, now: Double, expectedSubstrings: [String]) {
        let run = makeRun(id: "c1", state: state)
        let result = SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date(timeIntervalSinceReferenceDate: now))
        let statusRow = result.lines[SubagentStripRenderer.cardRowCount - 2]
        for substring in expectedSubstrings {
            #expect(statusRow.contains(substring))
        }
    }

    @Test("An active card changes at most once per elapsed second")
    func activeCardStableWithinSecond() {
        let run = makeRun(id: "c1")
        let render = { (now: Double) in
            SubagentStripRenderer.render(runs: [run], viewedChildId: nil, columns: 120, now: Date(timeIntervalSinceReferenceDate: now)).lines
        }
        #expect(render(5.05) == render(5.95))
        #expect(render(5.95) != render(6.05))
    }
}
