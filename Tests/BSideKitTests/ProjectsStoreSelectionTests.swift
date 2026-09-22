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
}
