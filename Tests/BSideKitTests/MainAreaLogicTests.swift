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

    @Test("resolvedDirectory(for:) prefers the selected task's worktree, then the project, then home")
    func resolvedDirectoryForStoreFollowsSelection() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        let (project, task): (Project, TaskRecord) = try await database.dbQueue.write { db in
            var project = Project(path: projectDir.path, displayName: "P", baseRef: "main")
            try project.insert(db)
            var task = TaskRecord(
                projectId: project.id!, name: "T", branchName: "feature", worktreePath: worktree.path,
                harness: "claude", permissionLevel: "default"
            )
            try task.insert(db)
            return (project, task)
        }
        store.start()
        try await waitUntil {
            store.projects.contains { $0.id == project.id }
        }

        #expect(MainAreaView.resolvedDirectory(for: store).path == FileManager.default.homeDirectoryForCurrentUser.path)

        store.selectProject(project)
        #expect(MainAreaView.resolvedDirectory(for: store).path == projectDir.path)

        store.selectTask(task, project: project)
        #expect(MainAreaView.resolvedDirectory(for: store).path == worktree.path)
    }

    // MARK: - Host-cache purging

    @Test("idsToPurge drops cached ids that are no longer live, keeping the rest", arguments: [
        (cached: Set<Int64>([1, 2, 3]), live: Set<Int64>([2, 3, 4]), expected: Set<Int64>([1])),
        (cached: Set<Int64>([1, 2]), live: Set<Int64>([1, 2]), expected: Set<Int64>()),
        (cached: Set<Int64>([1, 2, 3]), live: Set<Int64>(), expected: Set<Int64>([1, 2, 3])),
    ])
    func idsToPurge(cached: Set<Int64>, live: Set<Int64>, expected: Set<Int64>) {
        #expect(MainAreaView.idsToPurge(cachedIDs: cached, liveTaskIDs: live) == expected)
    }

    // MARK: - Visible/focused task id

    @Test("Only a task main selection reports a visible task id; project or no selection reports none")
    func visibleTaskIDForSelection() {
        let project = Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")
        let task = TaskRecord(id: 10, projectId: 1, name: "T", branchName: "b", worktreePath: "/tmp/a-wt", harness: "claude", permissionLevel: "default")
        #expect(MainAreaView.visibleTaskID(for: .task(task, project)) == 10)
        #expect(MainAreaView.visibleTaskID(for: .project(project)) == nil)
        #expect(MainAreaView.visibleTaskID(for: .none) == nil)
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
