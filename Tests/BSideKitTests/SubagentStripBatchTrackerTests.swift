import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("SubagentStripBatchTracker")
struct SubagentStripBatchTrackerTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func makeRun(id: String, state: ChildRunState, endedAt: Date? = nil) -> ChildRun {
        var run = ChildRun(id: id, taskId: 1, agent: "explorer", taskLabel: "T")
        run.state = state
        run.endedAt = endedAt
        return run
    }

    @Test("An empty feed shows nothing")
    func emptyFeedShowsNothing() {
        let tracker = SubagentStripBatchTracker()
        #expect(tracker.visibleRuns(forTask: 1, allRuns: []).isEmpty)
    }

    @Test("Active and blocked runs are always visible")
    func activeAndBlockedAlwaysVisible() {
        let active = makeRun(id: "a", state: .active)
        let blocked = makeRun(id: "b", state: .blocked)
        let ids = SubagentStripBatchTracker.nextBatch(allRuns: [active, blocked], now: epoch, swappedInChildID: nil)
        #expect(ids == ["a", "b"])
    }

    @Test("A finished run stays visible within the linger window")
    func finishedRunStaysVisibleWithinLinger() {
        let run = makeRun(id: "a", state: .completed, endedAt: epoch)
        let ids = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(1),
            swappedInChildID: nil
        )
        #expect(ids == ["a"])
    }

    @Test("A finished run disappears once the linger window has elapsed")
    func finishedRunDisappearsAfterLinger() {
        let run = makeRun(id: "a", state: .completed, endedAt: epoch)
        let ids = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 0.1),
            swappedInChildID: nil
        )
        #expect(ids.isEmpty)
    }

    @Test("A failed run also disappears once the linger window has elapsed")
    func failedRunDisappearsAfterLinger() {
        let run = makeRun(id: "a", state: .failed, endedAt: epoch)
        let ids = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 0.1),
            swappedInChildID: nil
        )
        #expect(ids.isEmpty)
    }

    @Test("A finished run swapped into view stays visible past the linger window")
    func finishedRunSwappedInStaysVisible() {
        let run = makeRun(id: "a", state: .completed, endedAt: epoch)
        let ids = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 100),
            swappedInChildID: "a"
        )
        #expect(ids == ["a"])
    }

    @Test("A swapped-in run disappears once the user swaps back and the linger has elapsed")
    func swappedInRunDisappearsAfterSwapBack() {
        let run = makeRun(id: "a", state: .completed, endedAt: epoch)
        let stillSwappedIn = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 100),
            swappedInChildID: "a"
        )
        #expect(stillSwappedIn == ["a"])

        let afterSwapBack = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 100),
            swappedInChildID: nil
        )
        #expect(afterSwapBack.isEmpty)
    }

    @Test("A concurrent sibling stays visible alongside a lingering finished run")
    func concurrentSiblingStaysVisible() {
        let finished = makeRun(id: "a", state: .completed, endedAt: epoch)
        let active = makeRun(id: "b", state: .active)
        let ids = SubagentStripBatchTracker.nextBatch(
            allRuns: [finished, active],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 100),
            swappedInChildID: nil
        )
        #expect(ids == ["b"])
    }

    @Test("visibleRuns preserves the feed's oldest-first order")
    func visibleRunsPreservesOrder() {
        let tracker = SubagentStripBatchTracker()
        let a = makeRun(id: "a", state: .active)
        let b = makeRun(id: "b", state: .active)
        let visible = tracker.visibleRuns(forTask: 1, allRuns: [a, b], now: epoch)
        #expect(visible.map(\.id) == ["a", "b"])
    }

    @Test("agedOutPaneIDs tears down a live pane once its card has left the strip")
    func agedOutPaneIDsClosesExpiredCard() {
        let run = makeRun(id: "a", state: .completed, endedAt: epoch)
        let agedOut = SubagentStripBatchTracker.agedOutPaneIDs(
            allRuns: [run],
            livePaneIDs: ["a"],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 0.1),
            swappedInChildID: nil
        )
        #expect(agedOut == ["a"])
    }

    @Test("agedOutPaneIDs leaves a swapped-in pane alone even past the linger window")
    func agedOutPaneIDsKeepsSwappedInPane() {
        let run = makeRun(id: "a", state: .completed, endedAt: epoch)
        let agedOut = SubagentStripBatchTracker.agedOutPaneIDs(
            allRuns: [run],
            livePaneIDs: ["a"],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 100),
            swappedInChildID: "a"
        )
        #expect(agedOut.isEmpty)
    }

    @Test("agedOutPaneIDs leaves an active run's pane alone")
    func agedOutPaneIDsKeepsActivePane() {
        let run = makeRun(id: "a", state: .active)
        let agedOut = SubagentStripBatchTracker.agedOutPaneIDs(
            allRuns: [run],
            livePaneIDs: ["a"],
            now: epoch,
            swappedInChildID: nil
        )
        #expect(agedOut.isEmpty)
    }

    @Test("reset is a harmless no-op now that visibility carries no tracked state")
    func resetIsANoOp() {
        let tracker = SubagentStripBatchTracker()
        let a = makeRun(id: "a", state: .active)
        tracker.reset(taskId: 1)
        #expect(tracker.visibleRuns(forTask: 1, allRuns: [a], now: epoch).map(\.id) == ["a"])
    }
}
