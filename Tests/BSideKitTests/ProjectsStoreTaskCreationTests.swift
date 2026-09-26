import Foundation
import Testing

@testable import BSideKit

/// Exercises `ProjectsStore.createTask`'s base-ref persistence and
/// `useWorktree` override against a real git repo and in-memory database.
@MainActor
@Suite("ProjectsStore task creation")
struct ProjectsStoreTaskCreationTests {
    @Test("rememberTaskCreationChoices persists the new default and updates the in-memory project")
    func rememberTaskCreationChoicesPersists() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        #expect(project.baseRef == "main")
        #expect(project.lastUseWorktree == nil)
        #expect(project.lastTaskCreationMode == nil)

        try await store.rememberTaskCreationChoices(
            project: project,
            baseRef: "develop",
            useWorktree: false,
            mode: .existingBranch
        )

        #expect(store.projects.first?.baseRef == "develop")
        #expect(store.projects.first?.lastUseWorktree == false)
        #expect(store.projects.first?.lastTaskCreationMode == TaskCreationMode.existingBranch.rawValue)

        let persisted = try await database.dbQueue.read { db in
            try Project.fetchOne(db, key: project.id)
        }
        #expect(persisted?.baseRef == "develop")
        #expect(persisted?.lastUseWorktree == false)
        #expect(persisted?.lastTaskCreationMode == TaskCreationMode.existingBranch.rawValue)
    }

    @Test("rememberTaskCreationChoices keeps the existing base ref when no new base was used")
    func rememberTaskCreationChoicesKeepsBaseRefWhenNil() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)

        try await store.rememberTaskCreationChoices(
            project: project,
            baseRef: nil,
            useWorktree: true,
            mode: .newBranch
        )

        #expect(store.projects.first?.baseRef == "main")
        #expect(store.projects.first?.lastUseWorktree == true)
        #expect(store.projects.first?.lastTaskCreationMode == TaskCreationMode.newBranch.rawValue)
    }

    @Test("rememberTaskCreationChoices survives a concurrent displayName change")
    func rememberTaskCreationChoicesSurvivesConcurrentRename() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        // A stale copy of the project, as `rememberTaskCreationChoices`'s
        // caller would hold if a rename lands after the copy was read.
        let staleProject = try #require(store.projects.first)
        guard let id = staleProject.id else {
            Issue.record("expected an id")
            return
        }

        try await database.dbQueue.write { db in
            var renamed = try #require(try Project.fetchOne(db, key: id))
            renamed.displayName = "Renamed Concurrently"
            try renamed.update(db)
        }

        try await store.rememberTaskCreationChoices(
            project: staleProject,
            baseRef: "develop",
            useWorktree: false,
            mode: .existingBranch
        )

        let persisted = try await database.dbQueue.read { db in
            try Project.fetchOne(db, key: id)
        }
        #expect(persisted?.displayName == "Renamed Concurrently")
        #expect(persisted?.baseRef == "develop")
        #expect(persisted?.lastUseWorktree == false)
        #expect(persisted?.lastTaskCreationMode == TaskCreationMode.existingBranch.rawValue)
    }

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

    @Test("createTask selects the new task so its terminal is shown immediately")
    func createTaskSelectsNewTask() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        store.selectProject(project)
        #expect(store.mainSelection == .project(project))

        let task = try await store.createTask(project: project, name: "Follow selection", useWorktree: false)

        #expect(store.selectedTaskID == task.id)
        #expect(store.mainSelection == .task(task, project))
    }

    @Test("New tasks appear at the top of their project's list, both optimistically and after the observation refreshes")
    func newTasksAppearAtTheTop() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let first = try await store.createTask(project: project, name: "First", useWorktree: false)
        #expect(store.tasksByProject[project.id!]?.map(\.id) == [first.id])

        let second = try await store.createTask(project: project, name: "Second", useWorktree: false)
        // Optimistic insert, before the ValueObservation refresh below.
        #expect(store.tasksByProject[project.id!]?.map(\.id) == [second.id, first.id])

        try await waitUntil {
            (store.tasksByProject[project.id!]?.count ?? 0) == 2
        }
        #expect(store.tasksByProject[project.id!]?.map(\.id) == [second.id, first.id])
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

    @Test("refreshSyncStatus backfills baseCommit for a legacy task via the reflog fallback")
    func refreshSyncStatusBackfillsLegacyBaseCommit() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let created = try await store.createTask(project: project, name: "Legacy", baseRef: "main")
        let taskId = try #require(created.id)

        // Simulate a task persisted before `baseCommit` existed.
        let legacyTask: TaskRecord = {
            var task = created
            task.baseCommit = nil
            return task
        }()
        try await database.dbQueue.write { db in try legacyTask.update(db) }

        await store.refreshSyncStatus(for: legacyTask, project: project)

        let persisted = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: taskId)
        }
        #expect(persisted?.baseCommit != nil)
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

    @Test("refreshSyncStatus detects uncommitted changes in the task's worktree, and clears once committed")
    func refreshSyncStatusDetectsUncommittedChanges() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Dirty worktree task", useWorktree: true)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.hasUncommittedChanges == false)

        let worktreeURL = URL(fileURLWithPath: task.worktreePath)
        try "scratch\n".write(to: worktreeURL.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.hasUncommittedChanges == true)

        _ = try await GitCLI.run(["add", "."], in: worktreeURL)
        _ = try await GitCLI.run(["commit", "-m", "scratch"], in: worktreeURL)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.hasUncommittedChanges == false)
    }

    @Test("Sync status updates live after a new commit lands on a task's branch following an earlier merged state, without an explicit refresh")
    func syncStatusUpdatesLiveAfterNewCommitOnMergedBranch() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Land then reopen", useWorktree: true)

        let worktreeURL = URL(fileURLWithPath: task.worktreePath)
        try "work\n".write(to: worktreeURL.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: worktreeURL)
        _ = try await GitCLI.run(["commit", "-m", "work"], in: worktreeURL)
        _ = try await GitCLI.run(["merge", "--no-ff", "-m", "merge", task.branchName], in: repoURL)

        // The refs watcher fires from the merge above landing in `repoURL`'s
        // common git dir; poll for it rather than calling `refreshSyncStatus`
        // directly, since this test exercises the live path end to end.
        try await waitUntil(.seconds(3)) { store.syncStatusByTask[task.id!]?.merged == true }
        #expect(store.syncStatusByTask[task.id!]?.merged == true)

        // A further commit on the branch, made entirely outside the app (as a
        // terminal or another tool would), must flip `merged` back to false
        // live — the regression the sidebar's "Merged" badge used to miss.
        try "more work\n".write(to: worktreeURL.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: worktreeURL)
        _ = try await GitCLI.run(["commit", "-m", "more work"], in: worktreeURL)

        try await waitUntil(.seconds(3)) { store.syncStatusByTask[task.id!]?.merged == false }
        #expect(store.syncStatusByTask[task.id!]?.merged == false)
    }
}
