import Foundation
import Testing

@testable import BSideKit

/// Pure logic behind the main area's task-terminal handling: which directory
/// a task's terminal resolves to, and which cached hosts get evicted once
/// their tasks are no longer live. View bodies themselves aren't exercised
/// here — see `SidebarSnapshotTests`/`ContentViewThemeSnapshotTests` for the
/// rendering side of the app.
@MainActor
@Suite("MainAreaView pure logic")
struct MainAreaLogicTests {
    @Test("A live worktree resolves to itself; a vanished or non-directory worktree path falls back to the project path", arguments: [
        (worktreeExists: true, worktreeIsFile: false),
        (worktreeExists: false, worktreeIsFile: false),
        (worktreeExists: true, worktreeIsFile: true),
    ])
    func resolvedDirectoryForTask(worktreeExists: Bool, worktreeIsFile: Bool) throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        if worktreeExists {
            if worktreeIsFile {
                try "not a directory".write(to: worktree, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            }
        }

        let project = Project(path: projectDir.path, displayName: "P", baseRef: "main")
        let task = TaskRecord(
            projectId: 1, name: "T", branchName: "feature", worktreePath: worktree.path,
            harness: "claude", permissionLevel: "default"
        )

        let resolved = MainAreaView.resolvedDirectory(forTask: task, project: project)
        let expectsLiveWorktree = worktreeExists && !worktreeIsFile
        #expect(resolved.path == (expectsLiveWorktree ? worktree.path : projectDir.path))
    }

    // MARK: - Focus target

    @Test("focusTarget is the parent with no or stale shown child, and the child when it has a live pane", arguments: [
        (shownChildID: nil, livePaneIDs: Set(["c1"]), expected: MainAreaView.FocusTarget.parent),
        (shownChildID: "c1", livePaneIDs: Set(["c1", "c2"]), expected: MainAreaView.FocusTarget.child("c1")),
        (shownChildID: "gone", livePaneIDs: Set(["c1"]), expected: MainAreaView.FocusTarget.parent),
    ] as [(String?, Set<String>, MainAreaView.FocusTarget)])
    func focusTarget(shownChildID: String?, livePaneIDs: Set<String>, expected: MainAreaView.FocusTarget) {
        #expect(MainAreaView.focusTarget(shownChildID: shownChildID, livePaneIDs: livePaneIDs) == expected)
    }
}
