import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("SubagentStripBatchTracker")
struct SubagentStripBatchTrackerTests {
    private func makeRun(id: String, state: ChildRunState) -> ChildRun {
        var run = ChildRun(id: id, taskId: 1, agent: "explorer", taskLabel: "T")
        run.state = state
        return run
    }

    @Test("An empty feed shows nothing")
    func emptyFeedShowsNothing() {
        let tracker = SubagentStripBatchTracker()
        #expect(tracker.visibleRuns(forTask: 1, allRuns: []).isEmpty)
    }

    @Test("The first run to appear is shown")
    func firstRunIsShown() {
        let tracker = SubagentStripBatchTracker()
        let run = makeRun(id: "a", state: .active)
        #expect(tracker.visibleRuns(forTask: 1, allRuns: [run]).map(\.id) == ["a"])
    }

    @Test("A concurrent sibling joins the still-active batch")
    func concurrentSiblingJoinsBatch() {
        let tracker = SubagentStripBatchTracker()
        let a = makeRun(id: "a", state: .active)
        _ = tracker.visibleRuns(forTask: 1, allRuns: [a])

        let b = makeRun(id: "b", state: .active)
        let visible = tracker.visibleRuns(forTask: 1, allRuns: [a, b])
        #expect(Set(visible.map(\.id)) == ["a", "b"])
    }

    @Test("Finished runs stay visible (dimmed) rather than disappearing immediately")
    func finishedRunsStayVisible() {
        let tracker = SubagentStripBatchTracker()
        var a = makeRun(id: "a", state: .active)
        _ = tracker.visibleRuns(forTask: 1, allRuns: [a])

        a.state = .completed
        let visible = tracker.visibleRuns(forTask: 1, allRuns: [a])
        #expect(visible.map(\.id) == ["a"])
    }

    @Test("A new run started after every earlier run finished clears the old batch")
    func newRunAfterAllFinishedClearsOldBatch() {
        let tracker = SubagentStripBatchTracker()
        var a = makeRun(id: "a", state: .active)
        _ = tracker.visibleRuns(forTask: 1, allRuns: [a])
        a.state = .completed
        _ = tracker.visibleRuns(forTask: 1, allRuns: [a])

        let b = makeRun(id: "b", state: .active)
        let visible = tracker.visibleRuns(forTask: 1, allRuns: [a, b])
        #expect(visible.map(\.id) == ["b"])
    }

    @Test("A new run started while another is still active joins the batch instead of replacing it")
    func newRunWhileOthersActiveJoinsBatch() {
        let tracker = SubagentStripBatchTracker()
        let a = makeRun(id: "a", state: .active)
        _ = tracker.visibleRuns(forTask: 1, allRuns: [a])

        let b = makeRun(id: "b", state: .active)
        let visible = tracker.visibleRuns(forTask: 1, allRuns: [a, b])
        #expect(Set(visible.map(\.id)) == ["a", "b"])
    }

    @Test("reset clears the tracked batch for a task, independent of other tasks")
    func resetClearsOnlyThatTask() {
        let tracker = SubagentStripBatchTracker()
        let a = makeRun(id: "a", state: .active)
        _ = tracker.visibleRuns(forTask: 1, allRuns: [a])
        let c = makeRun(id: "c", state: .active)
        _ = tracker.visibleRuns(forTask: 2, allRuns: [c])

        tracker.reset(taskId: 1)
        // After reset, task 1 starts a fresh batch from whatever the feed has now.
        let visible = tracker.visibleRuns(forTask: 1, allRuns: [a])
        #expect(visible.map(\.id) == ["a"])
        #expect(tracker.visibleRuns(forTask: 2, allRuns: [c]).map(\.id) == ["c"])
    }
}
