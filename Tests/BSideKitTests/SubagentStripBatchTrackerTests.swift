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

    @Test("Active and blocked runs are always visible")
    func activeAndBlockedAlwaysVisible() {
        let active = makeRun(id: "a", state: .active)
        let blocked = makeRun(id: "b", state: .blocked)
        let ids = SubagentStripBatchTracker.nextBatch(allRuns: [active, blocked], now: epoch, swappedInChildID: nil)
        #expect(ids == ["a", "b"])
    }

    @Test("A finished or failed run disappears once the linger window has elapsed", arguments: [ChildRunState.completed, ChildRunState.failed])
    func finishedOrFailedRunDisappearsAfterLinger(state: ChildRunState) {
        let run = makeRun(id: "a", state: state, endedAt: epoch)
        let ids = SubagentStripBatchTracker.nextBatch(
            allRuns: [run],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + 0.1),
            swappedInChildID: nil
        )
        #expect(ids.isEmpty)
    }

    @Test("agedOutPaneIDs tears down a pane once its finished card has left the strip, but leaves a swapped-in or still-active one alone", arguments: [
        (state: ChildRunState.completed, elapsedPastLinger: 0.1, swappedInChildID: nil, expectAgedOut: true),
        (state: ChildRunState.completed, elapsedPastLinger: 100, swappedInChildID: "a", expectAgedOut: false),
        (state: ChildRunState.active, elapsedPastLinger: 0.1, swappedInChildID: nil, expectAgedOut: false),
    ] as [(ChildRunState, TimeInterval, String?, Bool)])
    func agedOutPaneIDs(state: ChildRunState, elapsedPastLinger: TimeInterval, swappedInChildID: String?, expectAgedOut: Bool) {
        let run = makeRun(id: "a", state: state, endedAt: state == .active ? nil : epoch)
        let agedOut = SubagentStripBatchTracker.agedOutPaneIDs(
            allRuns: [run],
            livePaneIDs: ["a"],
            now: epoch.addingTimeInterval(SubagentStripBatchTracker.lingerInterval + elapsedPastLinger),
            swappedInChildID: swappedInChildID
        )
        #expect(agedOut == (expectAgedOut ? ["a"] : []))
    }
}
