import Foundation
import Testing

@testable import BSideKit

/// Exercises `ProjectsStore`'s selection model against a real in-memory
/// database, per the pattern the sidebar snapshot tests use: `start()` and
/// wait briefly for `ValueObservation` to populate `projects`/`tasksByProject`
/// before asserting.
@MainActor
@Suite("ProjectsStore selection")
struct ProjectsStoreSelectionTests {
    private func makeStore() async throws -> (store: ProjectsStore, projectA: Project, projectB: Project, taskA: TaskRecord) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let (projectA, projectB, taskA): (Project, Project, TaskRecord) = try await database.dbQueue.write { db in
            var projectA = Project(path: "/tmp/project-a", displayName: "A", baseRef: "main")
            try projectA.insert(db)
            var projectB = Project(path: "/tmp/project-b", displayName: "B", baseRef: "main")
            try projectB.insert(db)
            var taskA = TaskRecord(
                projectId: projectA.id!, name: "Task A", branchName: "feature/a",
                worktreePath: "/tmp/project-a-worktree", harness: "claude", permissionLevel: "default"
            )
            try taskA.insert(db)
            return (projectA, projectB, taskA)
        }

        store.start()
        try await Task.sleep(for: .milliseconds(200))
        return (store, projectA, projectB, taskA)
    }

    @Test("Selecting a project clears any task selection")
    func selectingProjectClearsTask() async throws {
        let (store, projectA, projectB, taskA) = try await makeStore()

        store.selectTask(taskA, project: projectA)
        #expect(store.selectedTaskID == taskA.id)

        store.selectProject(projectB)
        #expect(store.selectedProjectID == projectB.id)
        #expect(store.selectedTaskID == nil)
    }

    @Test("Selecting a task also selects its project")
    func selectingTaskSelectsProject() async throws {
        let (store, projectA, _, taskA) = try await makeStore()

        store.selectProject(projectA)
        store.selectTask(taskA, project: projectA)

        #expect(store.selectedTaskID == taskA.id)
        #expect(store.selectedProjectID == projectA.id)
    }

    @Test("mainSelection is .none, then .project, then .task as selection narrows")
    func mainSelectionTracksSelection() async throws {
        let (store, projectA, _, taskA) = try await makeStore()

        #expect(store.mainSelection == .none)

        store.selectProject(projectA)
        #expect(store.mainSelection == .project(projectA))

        store.selectTask(taskA, project: projectA)
        #expect(store.mainSelection == .task(taskA, projectA))
    }

    @Test("A task selection takes priority over a stale project selection")
    func taskSelectionWinsOverProject() async throws {
        let (store, projectA, projectB, taskA) = try await makeStore()

        // Bypass the mutual-exclusion helpers to simulate disagreeing IDs
        // (e.g. something mutating them directly instead of through
        // selectProject/selectTask) and confirm mainSelection still resolves
        // sensibly rather than showing project B's dashboard for task A.
        store.selectedProjectID = projectB.id
        store.selectedTaskID = taskA.id

        #expect(store.mainSelection == .task(taskA, projectA))
    }

    // MARK: - Selection reconciliation (pure)

    @Test("A live selected task is left untouched")
    func reconcileKeepsLiveTaskSelected() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: 1,
            selectedTaskID: 10,
            projects: [Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")],
            tasksByProject: [1: [TaskRecord(id: 10, projectId: 1, name: "T", branchName: "b", worktreePath: "/tmp/a-wt", harness: "claude", permissionLevel: "default")]]
        )
        #expect(reconciled.selectedProjectID == 1)
        #expect(reconciled.selectedTaskID == 10)
    }

    @Test("A live selected task whose recorded project id is stale clears selection")
    func reconcileClearsSelectionWhenLiveTaskHasStaleProjectID() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: 999,
            selectedTaskID: 10,
            projects: [Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")],
            tasksByProject: [1: [TaskRecord(id: 10, projectId: 1, name: "T", branchName: "b", worktreePath: "/tmp/a-wt", harness: "claude", permissionLevel: "default")]]
        )
        #expect(reconciled.selectedProjectID == nil)
        #expect(reconciled.selectedTaskID == nil)
    }

    @Test("A vanished selected task falls back to its still-live parent project")
    func reconcileFallsBackToParentProjectWhenTaskVanishes() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: 1,
            selectedTaskID: 10,
            projects: [Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")],
            tasksByProject: [1: []]
        )
        #expect(reconciled.selectedProjectID == 1)
        #expect(reconciled.selectedTaskID == nil)
    }

    @Test("A vanished selected task whose project is also gone leaves no selection")
    func reconcileClearsSelectionWhenTaskAndProjectVanish() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: 1,
            selectedTaskID: 10,
            projects: [],
            tasksByProject: [:]
        )
        #expect(reconciled.selectedProjectID == nil)
        #expect(reconciled.selectedTaskID == nil)
    }

    @Test("A vanished selected project with no task selected leaves no selection")
    func reconcileClearsSelectionWhenOnlyProjectVanishes() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: 1,
            selectedTaskID: nil,
            projects: [],
            tasksByProject: [:]
        )
        #expect(reconciled.selectedProjectID == nil)
        #expect(reconciled.selectedTaskID == nil)
    }

    @Test("A live selected project with no task selected is left untouched")
    func reconcileKeepsLiveProjectSelected() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: 1,
            selectedTaskID: nil,
            projects: [Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")],
            tasksByProject: [:]
        )
        #expect(reconciled.selectedProjectID == 1)
        #expect(reconciled.selectedTaskID == nil)
    }

    @Test("No selection at all stays no selection")
    func reconcileLeavesNoSelectionAsIs() {
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: nil,
            selectedTaskID: nil,
            projects: [Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")],
            tasksByProject: [:]
        )
        #expect(reconciled.selectedProjectID == nil)
        #expect(reconciled.selectedTaskID == nil)
    }

    @Test("Archiving the selected task clears it and falls back to the parent project")
    func archivingSelectedTaskReconcilesSelection() async throws {
        let (store, projectA, _, taskA) = try await makeStore()
        store.selectTask(taskA, project: projectA)
        #expect(store.selectedTaskID == taskA.id)

        try await store.archiveTask(taskA, project: projectA, removeWorktree: false)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.selectedTaskID == nil)
        #expect(store.selectedProjectID == projectA.id)
    }

    @Test("Deleting the selected task clears it and falls back to the parent project")
    func deletingSelectedTaskReconcilesSelection() async throws {
        // Unlike `archiveTask(removeWorktree: false)`, `deleteTask` always
        // tears down the worktree, so this needs a real git repo/worktree
        // rather than the fake paths `makeStore()` uses elsewhere in this suite.
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        try await store.addProject(at: repoURL)
        store.start()
        try await Task.sleep(for: .milliseconds(200))

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Task")
        try await Task.sleep(for: .milliseconds(200))

        store.selectTask(task, project: project)
        #expect(store.selectedTaskID == task.id)

        try await store.deleteTask(task, project: project, deleteLocalBranch: true, deleteRemoteBranch: false)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.selectedTaskID == nil)
        #expect(store.selectedProjectID == project.id)
    }

    @Test("Removing the selected project clears the whole selection")
    func removingSelectedProjectReconcilesSelection() async throws {
        let (store, projectA, _, _) = try await makeStore()
        store.selectProject(projectA)

        try await store.removeProject(projectA)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.selectedProjectID == nil)
        #expect(store.selectedTaskID == nil)
    }
}
