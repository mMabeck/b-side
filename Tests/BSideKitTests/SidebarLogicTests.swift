import Foundation
import SwiftUI
import Testing

@testable import BSideKit

@MainActor
@Suite("Sidebar pure logic")
struct SidebarLogicTests {
    // MARK: - Collapse-state persistence

    @Test("Collapse state round-trips through its RawRepresentable string, empty or not")
    func collapseStateRoundTrips() {
        let empty = SidebarCollapseState()
        #expect(empty.rawValue == "")
        #expect(SidebarCollapseState(rawValue: "") == empty)

        var state = SidebarCollapseState()
        state.setExpanded(false, for: 1)
        state.setExpanded(false, for: 42)
        state.setExpanded(true, for: 7) // never collapsed, shouldn't appear

        let roundTripped = SidebarCollapseState(rawValue: state.rawValue)
        #expect(roundTripped == state)
        #expect(roundTripped?.collapsedProjectIDs == [1, 42])
    }

    // MARK: - Status derivation priority

    @Test("Status derivation prioritises attention, then activity, then open/unread/read, then inactive")
    func statusDerivationPriority() {
        #expect(TaskStatus.derive(isBlocked: true, isVanished: false, activeChildCount: 3, isOpen: true, isUnread: false) == .question)
        #expect(TaskStatus.derive(isBlocked: false, isVanished: true, activeChildCount: 0, isOpen: true, isUnread: false) == .question)
        #expect(TaskStatus.derive(isBlocked: false, isVanished: false, activeChildCount: 1, isOpen: true, isUnread: false) == .running)
        #expect(TaskStatus.derive(isBlocked: false, isVanished: false, activeChildCount: 0, isOpen: false, isUnread: false) == .inactive)
        #expect(TaskStatus.derive(isBlocked: false, isVanished: false, activeChildCount: 0, isOpen: true, isUnread: true) == .unread)
        #expect(TaskStatus.derive(isBlocked: false, isVanished: false, activeChildCount: 0, isOpen: true, isUnread: false) == .read)
    }

    // MARK: - Per-project task overflow

    private func task(_ id: Int64) -> TaskRecord {
        TaskRecord(
            id: id, projectId: 1, name: "Task \(id)", branchName: "b\(id)",
            worktreePath: "/tmp/\(id)", harness: "claude", permissionLevel: "default"
        )
    }

    @Test("visibleTasks shows all tasks under the limit, and only the first `limit` over it")
    func visibleTasksRespectsLimit() {
        let tasks = (1...5).map(task)
        #expect(SidebarView.visibleTasks(tasks, limit: 5, expanded: false, selectedTaskID: nil) == tasks)

        let overflowing = (1...7).map(task)
        let visible = SidebarView.visibleTasks(overflowing, limit: 5, expanded: false, selectedTaskID: nil)
        #expect(visible.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test("visibleTasks keeps the selected task visible even past the limit, and shows everything when expanded")
    func visibleTasksKeepsSelectionAndExpands() {
        let tasks = (1...7).map(task)
        let visible = SidebarView.visibleTasks(tasks, limit: 5, expanded: false, selectedTaskID: 7)
        #expect(visible.map(\.id) == [1, 2, 3, 4, 5, 7])

        let expanded = SidebarView.visibleTasks(tasks, limit: 5, expanded: true, selectedTaskID: nil)
        #expect(expanded == tasks)
    }

    // MARK: - Selection reconciliation

    @Test(
        "reconciledRow leaves a current row untouched when it already represents the store selection, and only re-derives it otherwise",
        arguments: [
            (current: SidebarView.SidebarRowID.task(1) as SidebarView.SidebarRowID?, selectedTaskID: Int64?.some(1), selectedProjectID: Int64?.some(9), openTaskIDs: [Int64](), expected: SidebarView.SidebarRowID.task(1) as SidebarView.SidebarRowID?),
            (current: SidebarView.SidebarRowID.task(1), selectedTaskID: 1, selectedProjectID: 9, openTaskIDs: [1], expected: SidebarView.SidebarRowID.task(1)),
            (current: SidebarView.SidebarRowID.activeTask(1), selectedTaskID: 1, selectedProjectID: 9, openTaskIDs: [], expected: SidebarView.SidebarRowID.activeTask(1)),
            (current: SidebarView.SidebarRowID.project(9), selectedTaskID: nil, selectedProjectID: 9, openTaskIDs: [], expected: SidebarView.SidebarRowID.project(9)),
            (current: nil, selectedTaskID: 1, selectedProjectID: 9, openTaskIDs: [1], expected: SidebarView.SidebarRowID.activeTask(1)),
            (current: nil, selectedTaskID: 1, selectedProjectID: 9, openTaskIDs: [], expected: SidebarView.SidebarRowID.task(1)),
            (current: SidebarView.SidebarRowID.activeTask(1), selectedTaskID: nil, selectedProjectID: 9, openTaskIDs: [1], expected: SidebarView.SidebarRowID.project(9)),
            (current: SidebarView.SidebarRowID.task(2), selectedTaskID: 1, selectedProjectID: 9, openTaskIDs: [1], expected: SidebarView.SidebarRowID.activeTask(1)),
            (current: SidebarView.SidebarRowID.project(9), selectedTaskID: nil, selectedProjectID: nil, openTaskIDs: [], expected: nil),
        ] as [(current: SidebarView.SidebarRowID?, selectedTaskID: Int64?, selectedProjectID: Int64?, openTaskIDs: [Int64], expected: SidebarView.SidebarRowID?)]
    )
    func reconciledRowCases(current: SidebarView.SidebarRowID?, selectedTaskID: Int64?, selectedProjectID: Int64?, openTaskIDs: [Int64], expected: SidebarView.SidebarRowID?) {
        let result = SidebarView.reconciledRow(current: current, selectedTaskID: selectedTaskID, selectedProjectID: selectedProjectID, openTaskIDs: openTaskIDs)
        #expect(result == expected)
    }

    // MARK: - Branch-sync summary formatting

    @Test("Branch sync summary formatting")
    func branchSyncSummaryFormatting() {
        #expect(BranchSyncSummary.text(ahead: 0, behind: 0, merged: false) == nil)
        #expect(BranchSyncSummary.text(ahead: 3, behind: 0, merged: false) == "↑3")
        #expect(BranchSyncSummary.text(ahead: 0, behind: 2, merged: false) == "↓2")
        #expect(BranchSyncSummary.text(ahead: 1, behind: 4, merged: false) == "↑1 ↓4")
        #expect(BranchSyncSummary.text(ahead: 9, behind: 9, merged: true) == "merged")
    }
}
