import Testing

@testable import BSideKit

/// Pure logic behind the drawer's per-task/per-project shell cache key.
@MainActor
@Suite("TerminalDrawerView pure logic")
struct TerminalDrawerViewTests {
    @Test("Keys by task id when a task is selected, by project id for a bare project, and nil for no selection")
    func drawerKey() {
        let project = Project(id: 7, path: "/tmp/project", displayName: "P", baseRef: "main")
        let task = TaskRecord(
            id: 3, projectId: 7, name: "T", branchName: "feature", worktreePath: "/tmp/worktree",
            harness: "claude", permissionLevel: "default"
        )

        #expect(TerminalDrawerView.key(for: .none) == nil)
        #expect(TerminalDrawerView.key(for: .project(project)) == .project(7))
        #expect(TerminalDrawerView.key(for: .task(task, project)) == .task(3))
    }
}
