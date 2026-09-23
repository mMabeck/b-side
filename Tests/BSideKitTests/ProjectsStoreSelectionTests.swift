import Foundation
import Testing

@testable import BSideKit

/// Exercises `ProjectsStore`'s selection model against a real in-memory
/// database, per the pattern the sidebar snapshot tests use: `start()` and
/// wait for `ValueObservation` to populate `projects`/`tasksByProject`
/// before asserting.

/// Polls until `condition` holds or `timeout` elapses. This suite (and
/// `MainAreaLogicTests`) run alongside heavy offscreen snapshot suites that
/// render real windows through WindowServer, which can load the machine
/// enough to delay GRDB's `ValueObservation` past any fixed sleep duration a
/// test could pick. Polling for the specific state the following assertions
/// depend on avoids that without masking a genuine failure: if `condition`
/// never becomes true, this simply returns at `timeout` and the assertions
/// below fail on their own with their real messages.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

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
        try await waitUntil {
            store.projects.contains { $0.id == projectA.id }
                && store.projects.contains { $0.id == projectB.id }
                && (store.tasksByProject[projectA.id!]?.contains { $0.id == taskA.id } ?? false)
        }
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
        try await waitUntil {
            !(store.tasksByProject[projectA.id!]?.contains { $0.id == taskA.id } ?? false)
        }

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
        try await waitUntil { !store.projects.isEmpty }

        let project = try #require(store.projects.first)
        let task = try await store.createTask(project: project, name: "Task")
        try await waitUntil {
            store.tasksByProject[project.id!]?.contains { $0.id == task.id } ?? false
        }

        store.selectTask(task, project: project)
        #expect(store.selectedTaskID == task.id)

        try await store.deleteTask(task, project: project, deleteLocalBranch: true, deleteRemoteBranch: false)
        try await waitUntil {
            !(store.tasksByProject[project.id!]?.contains { $0.id == task.id } ?? false)
        }

        #expect(store.selectedTaskID == nil)
        #expect(store.selectedProjectID == project.id)
    }

    @Test("Removing the selected project clears the whole selection")
    func removingSelectedProjectReconcilesSelection() async throws {
        let (store, projectA, _, _) = try await makeStore()
        store.selectProject(projectA)

        try await store.removeProject(projectA)
        try await waitUntil {
            !store.projects.contains { $0.id == projectA.id }
        }

        #expect(store.selectedProjectID == nil)
        #expect(store.selectedTaskID == nil)
    }

    @Test("A terminal question alert marks its task needing attention until it's next selected")
    func terminalQuestionMarksNeedsAttentionUntilSelected() async throws {
        let (store, projectA, _, taskA) = try await makeStore()
        let id = try #require(taskA.id)

        store.handleTerminalDesktopNotification(taskID: id, title: "Pi has a question", body: "Ready?")
        #expect(store.taskIDsNeedingAttention.contains(id))

        store.selectTask(taskA, project: projectA)
        #expect(!store.taskIDsNeedingAttention.contains(id))
    }

    @Test("A terminal bell always marks its task needing attention")
    func terminalBellMarksNeedsAttention() async throws {
        let (store, _, _, taskA) = try await makeStore()
        let id = try #require(taskA.id)

        store.handleTerminalBell(taskID: id)
        #expect(store.taskIDsNeedingAttention.contains(id))
    }

    @Test("A plain finished notification does not mark needs-attention")
    func terminalFinishedNotificationDoesNotMarkNeedsAttention() async throws {
        let (store, _, _, taskA) = try await makeStore()
        let id = try #require(taskA.id)

        store.handleTerminalDesktopNotification(taskID: id, title: "Pi finished", body: "Ready for your next prompt.")
        #expect(!store.taskIDsNeedingAttention.contains(id))
    }
}
