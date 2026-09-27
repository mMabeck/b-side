import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("SubagentSwapStore")
struct SubagentSwapStoreTests {
    @Test("show swaps the main area to the given child")
    func showSwapsToChild() {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        #expect(swap.shownChildID(forTask: 1) == "c1")
    }

    @Test("Closing the currently shown child auto-returns to the parent; closing an unshown child does nothing", arguments: [("c1", nil), ("c2", "c1")] as [(String, String?)])
    func handleClosed(closedChildId: String, expectedShown: String?) {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        swap.handleClosed(childId: closedChildId, taskId: 1)
        #expect(swap.shownChildID(forTask: 1) == expectedShown)
    }

    // MARK: - MainAreaView.reconcileSwap (pane-close auto-return)

    @Test("reconcileSwap returns to the parent once the shown child's pane is gone")
    func reconcileSwapReturnsToParentAfterPaneCloses() {
        let swap = SubagentSwapStore()
        let panes = SubagentPaneStore()
        panes.spawn(taskId: 1, childId: "c1", label: "a", cwd: FileManager.default.temporaryDirectory, command: "/bin/sh")
        swap.show(childId: "c1", forTask: 1)

        panes.close(taskId: 1, childId: "c1")
        MainAreaView.reconcileSwap(swap, panesByTask: panes.panesByTask)

        #expect(swap.shownChildID(forTask: 1) == nil)
    }
}
