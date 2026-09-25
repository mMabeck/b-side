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

    @Test("createTask records the branch's start commit, and refreshSyncStatus reports not merged for the fresh branch")
    func createTaskRecordsStartCommit() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Start commit", baseRef: "main")

        #expect(task.startCommit != nil)

        await store.refreshSyncStatus(for: task, project: project)
        #expect(store.syncStatusByTask[task.id!]?.merged == false)
    }

    @Test("refreshSyncStatus backfills startCommit for a legacy task via the reflog fallback")
    func refreshSyncStatusBackfillsLegacyStartCommit() async throws {
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

        // Simulate a task persisted before `startCommit` existed.
        let legacyTask: TaskRecord = {
            var task = created
            task.startCommit = nil
            return task
        }()
        try await database.dbQueue.write { db in try legacyTask.update(db) }

        await store.refreshSyncStatus(for: legacyTask, project: project)

        let persisted = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: taskId)
        }
        #expect(persisted?.startCommit != nil)
    }
}
