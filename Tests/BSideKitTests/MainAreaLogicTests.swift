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
    @Test("A task with a live worktree resolves to that worktree's directory")
    func resolvesToLiveWorktree() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let project = Project(path: root.appendingPathComponent("project").path, displayName: "P", baseRef: "main")
        let task = TaskRecord(
            projectId: 1, name: "T", branchName: "feature", worktreePath: worktree.path,
            harness: "claude", permissionLevel: "default"
        )

        let resolved = MainAreaView.resolvedDirectory(forTask: task, project: project)
        #expect(resolved.path == worktree.path)
    }

    @Test("A task whose worktree has vanished falls back to the project's own path")
    func fallsBackWhenWorktreeVanished() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let missingWorktree = root.appendingPathComponent("gone-worktree", isDirectory: true)

        let project = Project(path: projectDir.path, displayName: "P", baseRef: "main")
        let task = TaskRecord(
            projectId: 1, name: "T", branchName: "feature", worktreePath: missingWorktree.path,
            harness: "claude", permissionLevel: "default"
        )

        let resolved = MainAreaView.resolvedDirectory(forTask: task, project: project)
        #expect(resolved.path == projectDir.path)
    }

    @Test("A task whose worktree path is a file, not a directory, also falls back to the project path")
    func fallsBackWhenWorktreePathIsAFile() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let notADirectory = root.appendingPathComponent("worktree-file")
        try "not a directory".write(to: notADirectory, atomically: true, encoding: .utf8)

        let project = Project(path: projectDir.path, displayName: "P", baseRef: "main")
        let task = TaskRecord(
            projectId: 1, name: "T", branchName: "feature", worktreePath: notADirectory.path,
            harness: "claude", permissionLevel: "default"
        )

        let resolved = MainAreaView.resolvedDirectory(forTask: task, project: project)
        #expect(resolved.path == projectDir.path)
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

    @Test("Cached hosts for tasks no longer live are purged; hosts for live tasks are kept")
    func purgesOnlyDeadTaskHosts() {
        let cached: Set<Int64> = [1, 2, 3]
        let live: Set<Int64> = [2, 3, 4]
        #expect(MainAreaView.idsToPurge(cachedIDs: cached, liveTaskIDs: live) == [1])
    }

    @Test("No cached hosts are purged when every cached task is still live")
    func purgesNothingWhenAllLive() {
        let cached: Set<Int64> = [1, 2]
        #expect(MainAreaView.idsToPurge(cachedIDs: cached, liveTaskIDs: cached) == [])
    }

    @Test("Every cached host is purged once no task is live")
    func purgesAllWhenNoneLive() {
        let cached: Set<Int64> = [1, 2, 3]
        #expect(MainAreaView.idsToPurge(cachedIDs: cached, liveTaskIDs: []) == cached)
    }

    // MARK: - Visible/focused task id

    @Test("A task main selection reports its task id as visible")
    func visibleTaskIDForTaskSelection() {
        let project = Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")
        let task = TaskRecord(id: 10, projectId: 1, name: "T", branchName: "b", worktreePath: "/tmp/a-wt", harness: "claude", permissionLevel: "default")
        #expect(MainAreaView.visibleTaskID(for: .task(task, project)) == 10)
    }

    @Test("A project main selection reports no visible task")
    func visibleTaskIDForProjectSelection() {
        let project = Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")
        #expect(MainAreaView.visibleTaskID(for: .project(project)) == nil)
    }

    @Test("No main selection reports no visible task")
    func visibleTaskIDForNoSelection() {
        #expect(MainAreaView.visibleTaskID(for: .none) == nil)
    }
}
