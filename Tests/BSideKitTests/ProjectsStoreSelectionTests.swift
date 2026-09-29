import Foundation
import Testing

@testable import BSideKit


@MainActor
@Suite("ProjectsStore selection")
struct ProjectsStoreSelectionTests {
    private func makeStore() async throws -> (store: ProjectsStore, projectA: Project, projectB: Project, taskA: TaskRecord) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }

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

    @Test("Selecting a task also selects its project")
    func selectingTaskSelectsProject() async throws {
        let (store, projectA, _, taskA) = try await makeStore()

        store.selectProject(projectA)
        store.selectTask(taskA, project: projectA)

        #expect(store.selectedTaskID == taskA.id)
        #expect(store.selectedProjectID == projectA.id)
    }


    @Test(
        "reconcileSelection handles live/stale/vanished tasks and projects",
        arguments: [
            // (name, selectedProjectID, selectedTaskID, hasProjects, hasTaskInProject1, expectedProjectID, expectedTaskID)
            ("live task is left untouched", 1, 10, true, true, 1, 10),
            ("stale project id on a live task clears selection", 999, 10, true, true, nil, nil),
            ("vanished task falls back to its still-live parent project", 1, 10, true, false, 1, nil),
            ("vanished task whose project is also gone leaves no selection", 1, 10, false, false, nil, nil),
            ("vanished project with no task selected leaves no selection", 1, nil, false, false, nil, nil),
            ("live project with no task selected is left untouched", 1, nil, true, false, 1, nil),
            ("no selection at all stays no selection", nil, nil, true, false, nil, nil),
        ] as [(String, Int64?, Int64?, Bool, Bool, Int64?, Int64?)]
    )
    func reconcileSelection(
        name: String,
        selectedProjectID: Int64?,
        selectedTaskID: Int64?,
        hasProjects: Bool,
        hasTaskInProject1: Bool,
        expectedProjectID: Int64?,
        expectedTaskID: Int64?
    ) {
        let projects = hasProjects ? [Project(id: 1, path: "/tmp/a", displayName: "A", baseRef: "main")] : []
        let tasksByProject: [Int64: [TaskRecord]] = hasTaskInProject1
            ? [1: [TaskRecord(id: 10, projectId: 1, name: "T", branchName: "b", worktreePath: "/tmp/a-wt", harness: "claude", permissionLevel: "default")]]
            : [:]
        let reconciled = ProjectsStore.reconcileSelection(
            selectedProjectID: selectedProjectID,
            selectedTaskID: selectedTaskID,
            projects: projects,
            tasksByProject: tasksByProject
        )
        #expect(reconciled.selectedProjectID == expectedProjectID, "\(name): projectID")
        #expect(reconciled.selectedTaskID == expectedTaskID, "\(name): taskID")
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


    @Test("Selecting a task clears its unread flag")
    func selectingTaskClearsUnread() async throws {
        let (store, projectA, _, taskA) = try await makeStore()
        let id = try #require(taskA.id)

        store.setTaskBusy(id)
        store.clearTaskBusy(id)
        #expect(store.unreadTaskIDs.contains(id))

        store.selectTask(taskA, project: projectA)
        #expect(!store.unreadTaskIDs.contains(id))
    }

    @Test("A busy report clears a question's attention state, even for the already-selected task")
    func busyClearsAttentionOnSelectedTask() async throws {
        let (store, projectA, _, taskA) = try await makeStore()
        let id = try #require(taskA.id)
        store.selectTask(taskA, project: projectA)

        store.handleTerminalBell(taskID: id)
        #expect(store.taskIDsNeedingAttention.contains(id))

        store.setTaskBusy(id)
        #expect(!store.taskIDsNeedingAttention.contains(id))
    }

}
