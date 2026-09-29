import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("ProjectsStore task creation")
struct ProjectsStoreTaskCreationTests {
    @Test("createTask(useWorktree: false) runs the task in the project directory with no worktree created")
    func createTaskWithoutWorktreeStaysInPlace() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "In place", useWorktree: false)

        #expect(task.worktreePath == project.path)
        #expect(task.branchCreatedByApp == false)
        #expect(task.branchName == "main")

        let worktrees = try await GitCLI.worktrees(at: repoURL)
        #expect(worktrees.count == 1)
        #expect(worktrees.first?.path.hasSuffix("/repo") == true)
    }

    @Test("createTask persists baseCommit, and refreshSyncStatus reads a fresh task as not merged until it gains and lands commits of its own")
    func refreshSyncStatusReflectsBaseCommit() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Sync status task")
        #expect(task.baseCommit != nil)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.merged == false)

        let worktreeURL = URL(fileURLWithPath: task.worktreePath)
        try "work\n".write(to: worktreeURL.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: worktreeURL)
        _ = try await GitCLI.run(["commit", "-m", "work"], in: worktreeURL)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.merged == false)

        _ = try await GitCLI.run(["merge", "--no-ff", "-m", "merge", task.branchName], in: repoURL)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.merged == true)
    }

    @Test("setTaskBusy/clearTaskBusy are idempotent, and archiving or deleting a task clears its busy flag")
    func busyTaskIDsClearOnArchiveAndDelete() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }
        let project = try #require(store.projects.first)

        let archived = try await store.createTask(project: project, name: "Archived", useWorktree: false)
        store.setTaskBusy(archived.id!)
        store.setTaskBusy(archived.id!)
        #expect(store.busyTaskIDs == [archived.id!])

        try await store.archiveTask(archived, project: project, removeWorktree: false)
        #expect(!store.busyTaskIDs.contains(archived.id!))

        let deleted = try await store.createTask(project: project, name: "Deleted", useWorktree: false)
        store.setTaskBusy(deleted.id!)
        #expect(store.busyTaskIDs.contains(deleted.id!))

        try await store.deleteTask(deleted, project: project, deleteLocalBranch: false, deleteRemoteBranch: false)
        #expect(!store.busyTaskIDs.contains(deleted.id!))

        store.clearTaskBusy(999)
        #expect(store.busyTaskIDs.isEmpty)
    }
}
