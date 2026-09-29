import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("ProjectsStore activity ordering")
struct ProjectsStoreActivityOrderingTests {
    private func makeStore() async throws -> (store: ProjectsStore, project: Project, taskA: TaskRecord, taskB: TaskRecord) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)
        store.playAlertSound = { _ in }

        let (project, taskA, taskB): (Project, TaskRecord, TaskRecord) = try await database.dbQueue.write { db in
            var project = Project(path: "/tmp/activity-project", displayName: "P", baseRef: "main")
            try project.insert(db)
            var taskA = TaskRecord(
                projectId: project.id!, name: "Task A", branchName: "feature/a",
                worktreePath: "/tmp/activity-a", harness: "claude", permissionLevel: "default"
            )
            try taskA.insert(db)
            var taskB = TaskRecord(
                projectId: project.id!, name: "Task B", branchName: "feature/b",
                worktreePath: "/tmp/activity-b", harness: "claude", permissionLevel: "default"
            )
            try taskB.insert(db)
            return (project, taskA, taskB)
        }

        store.start()
        try await waitUntil {
            (store.tasksByProject[project.id!]?.contains { $0.id == taskA.id } ?? false)
                && (store.tasksByProject[project.id!]?.contains { $0.id == taskB.id } ?? false)
        }
        return (store, project, taskA, taskB)
    }

    @Test("movingToFront moves a tracked id to the front, leaving others' order, and is a no-op for an untracked id")
    func movingToFront() {
        #expect(ProjectsStore.movingToFront(2, in: [1, 2, 3]) == [2, 1, 3])
        #expect(ProjectsStore.movingToFront(3, in: [1, 2, 3]) == [3, 1, 2])
        #expect(ProjectsStore.movingToFront(9, in: [1, 2, 3]) == [1, 2, 3])
        #expect(ProjectsStore.movingToFront(9, in: []) == [])
    }

    @Test("openTerminalTaskIDs mutators never introduce duplicate ids")
    func openTerminalMutatorsNeverDuplicate() {
        var ids = ProjectsStore.addingOpenTerminal(1, to: [])
        ids = ProjectsStore.addingOpenTerminal(2, to: ids)
        ids = ProjectsStore.addingOpenTerminal(1, to: ids)
        ids = ProjectsStore.movingToFront(2, in: ids)
        ids = ProjectsStore.movingToFront(2, in: ids)
        #expect(ids.count == Set(ids).count)
        ids = ProjectsStore.removingOpenTerminals([1], from: ids)
        #expect(ids.count == Set(ids).count)
    }

    @Test("setTaskBusy moves the task to the top of its project list and open terminals")
    func setTaskBusyBumpsOrdering() async throws {
        let (store, project, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)
        #expect(store.openTerminalTaskIDs == [idA, idB])

        store.setTaskBusy(idA)

        #expect(store.openTerminalTaskIDs == [idA, idB])

        store.setTaskBusy(idB)

        #expect(store.openTerminalTaskIDs == [idB, idA])
        try await waitUntil {
            store.tasksByProject[project.id!]?.first?.id == idB
        }
        #expect(store.tasksByProject[project.id!]?.first?.id == idB)
    }

    @Test("A genuine clearTaskBusy transition bumps ordering; a no-op clear does not")
    func clearTaskBusyBumpsOnlyOnGenuineTransition() async throws {
        let (store, project, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)

        store.clearTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])

        store.setTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == [idB, idA])

        store.setTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])
        store.clearTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == [idB, idA])
        try await waitUntil {
            store.tasksByProject[project.id!]?.first?.id == idB
        }
        #expect(store.tasksByProject[project.id!]?.first?.id == idB)

        let orderBeforeNoOpClear = store.openTerminalTaskIDs
        store.clearTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == orderBeforeNoOpClear)
    }

    @Test("Repeated setTaskBusy pings for an already-busy task don't re-bump ordering")
    func setTaskBusyDoesNotRebumpWhileAlreadyBusy() async throws {
        let (store, _, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)

        store.setTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == [idB, idA])

        store.setTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])

        store.setTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])
    }

}
