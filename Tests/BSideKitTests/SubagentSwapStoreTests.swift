import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("SubagentSwapStore")
struct SubagentSwapStoreTests {
    @Test("A fresh store shows the parent (nil) for every task")
    func startsShowingParent() {
        let swap = SubagentSwapStore()
        #expect(swap.shownChildID(forTask: 1) == nil)
    }

    @Test("show swaps the main area to the given child")
    func showSwapsToChild() {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        #expect(swap.shownChildID(forTask: 1) == "c1")
    }

    @Test("showMain swaps back to the parent")
    func showMainSwapsBack() {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        swap.showMain(forTask: 1)
        #expect(swap.shownChildID(forTask: 1) == nil)
    }

    @Test("Toggling the already-shown child swaps back to the parent; toggling a different child swaps to it", arguments: [("c1", nil), ("c2", "c2")] as [(String, String?)])
    func toggleChild(childId: String, expectedShown: String?) {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        swap.toggle(childId: childId, forTask: 1)
        #expect(swap.shownChildID(forTask: 1) == expectedShown)
    }

    @Test("version bumps when the shown child changes, but not when highlighting alone")
    func versionBumpsOnlyForShownChildChanges() {
        let swap = SubagentSwapStore()
        let versionAfterCreation = swap.version

        swap.highlight(childId: "c1", forTask: 1)
        #expect(swap.version == versionAfterCreation)

        swap.show(childId: "c1", forTask: 1)
        #expect(swap.version == versionAfterCreation + 1)

        swap.show(childId: "c1", forTask: 1)
        #expect(swap.version == versionAfterCreation + 1)

        swap.showMain(forTask: 1)
        #expect(swap.version == versionAfterCreation + 2)

        swap.showMain(forTask: 1)
        #expect(swap.version == versionAfterCreation + 2)
    }

    @Test("Swap state for one task never affects another")
    func tasksAreIndependent() {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        swap.show(childId: "c2", forTask: 2)
        #expect(swap.shownChildID(forTask: 1) == "c1")
        #expect(swap.shownChildID(forTask: 2) == "c2")
    }

    @Test("Closing the currently shown child auto-returns to the parent; closing an unshown child does nothing", arguments: [("c1", nil), ("c2", "c1")] as [(String, String?)])
    func handleClosed(closedChildId: String, expectedShown: String?) {
        let swap = SubagentSwapStore()
        swap.show(childId: "c1", forTask: 1)
        swap.handleClosed(childId: closedChildId, taskId: 1)
        #expect(swap.shownChildID(forTask: 1) == expectedShown)
    }

    @Test("Highlighting a headless card doesn't change what the main area shows")
    func highlightDoesNotSwap() {
        let swap = SubagentSwapStore()
        swap.highlight(childId: "headless", forTask: 1)
        #expect(swap.highlightedChildID(forTask: 1) == "headless")
        #expect(swap.shownChildID(forTask: 1) == nil)
    }

    @Test("Showing a child clears any prior highlight for that task")
    func showClearsHighlight() {
        let swap = SubagentSwapStore()
        swap.highlight(childId: "headless", forTask: 1)
        swap.show(childId: "c1", forTask: 1)
        #expect(swap.highlightedChildID(forTask: 1) == nil)
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

    @Test("reconcileSwap leaves the shown child alone while its pane is still live")
    func reconcileSwapLeavesLiveChildAlone() {
        let swap = SubagentSwapStore()
        let panes = SubagentPaneStore()
        panes.spawn(taskId: 1, childId: "c1", label: "a", cwd: FileManager.default.temporaryDirectory, command: "/bin/sh")
        swap.show(childId: "c1", forTask: 1)

        MainAreaView.reconcileSwap(swap, panesByTask: panes.panesByTask)

        #expect(swap.shownChildID(forTask: 1) == "c1")
    }

    // MARK: - SubagentSwapNavigation

    @Test("childID(atIndex:) picks by position in strip order")
    func childIDAtIndex() {
        let strip = ["a", "b", "c"]
        #expect(SubagentSwapNavigation.childID(atIndex: 0, strip: strip) == "a")
        #expect(SubagentSwapNavigation.childID(atIndex: 2, strip: strip) == "c")
        #expect(SubagentSwapNavigation.childID(atIndex: 3, strip: strip) == nil)
    }

    @Test("next steps from the parent to the first child, then forward, then wraps to the parent")
    func nextSteps() {
        let strip = ["a", "b"]
        #expect(SubagentSwapNavigation.next(after: nil, strip: strip) == "a")
        #expect(SubagentSwapNavigation.next(after: "a", strip: strip) == "b")
        #expect(SubagentSwapNavigation.next(after: "b", strip: strip) == nil)
    }

    @Test("previous steps backward and wraps to the parent before the first child")
    func previousSteps() {
        let strip = ["a", "b"]
        #expect(SubagentSwapNavigation.previous(before: nil, strip: strip) == "b")
        #expect(SubagentSwapNavigation.previous(before: "b", strip: strip) == "a")
        #expect(SubagentSwapNavigation.previous(before: "a", strip: strip) == nil)
    }
}
