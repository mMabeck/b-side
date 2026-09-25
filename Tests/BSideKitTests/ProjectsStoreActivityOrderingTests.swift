import Foundation
import Testing

@testable import BSideKit

/// Exercises `ProjectsStore`'s recent-activity ordering: `setTaskBusy`, a
/// genuine `clearTaskBusy` transition, and an accepted question alert should
/// all move a task to the top of its project's list and to the front of
/// `openTerminalTaskIDs`; mere selection and a redundant `clearTaskBusy`
/// should not.
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

    @Test("movingToFront moves a tracked id to the front, leaving others' order")
    func movingToFrontMovesTrackedID() {
        #expect(ProjectsStore.movingToFront(2, in: [1, 2, 3]) == [2, 1, 3])
        #expect(ProjectsStore.movingToFront(3, in: [1, 2, 3]) == [3, 1, 2])
    }

    @Test("movingToFront is a no-op for an id that isn't present")
    func movingToFrontNoOpForUntrackedID() {
        #expect(ProjectsStore.movingToFront(9, in: [1, 2, 3]) == [1, 2, 3])
        #expect(ProjectsStore.movingToFront(9, in: []) == [])
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

        // taskA was never marked busy, so clearing it is a no-op: no bump.
        store.clearTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])

        store.setTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == [idB, idA])

        // Genuine busy -> idle transition for taskA: bumps it to the front.
        store.setTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])
        store.clearTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == [idB, idA])
        try await waitUntil {
            store.tasksByProject[project.id!]?.first?.id == idB
        }
        #expect(store.tasksByProject[project.id!]?.first?.id == idB)

        // Now idle already; clearing again is a no-op and must not re-bump.
        let orderBeforeNoOpClear = store.openTerminalTaskIDs
        store.clearTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == orderBeforeNoOpClear)
    }

    @Test("dropTaskBusy clears the busy flag but never bumps ordering, unlike clearTaskBusy")
    func dropTaskBusyDoesNotBumpOrdering() async throws {
        let (store, project, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)

        store.setTaskBusy(idB)
        #expect(store.openTerminalTaskIDs == [idB, idA])
        try await waitUntil {
            store.tasksByProject[project.id!]?.first?.id == idB
        }

        // Simulates closing a busy task's terminal (or its process exiting,
        // or it being purged/archived/deleted): the busy flag must clear
        // without reordering the project's task list or openTerminalTaskIDs.
        store.setTaskBusy(idA)
        #expect(store.openTerminalTaskIDs == [idA, idB])
        try await waitUntil {
            store.tasksByProject[project.id!]?.first?.id == idA
        }
        let orderBeforeDrop = store.openTerminalTaskIDs
        let projectOrderBeforeDrop = store.tasksByProject[project.id!]

        store.dropTaskBusy(idA)

        #expect(store.openTerminalTaskIDs == orderBeforeDrop)
        #expect(store.tasksByProject[project.id!]?.map(\.id) == projectOrderBeforeDrop?.map(\.id))
    }

    @Test("An accepted question alert bumps ordering")
    func questionAlertBumpsOrdering() async throws {
        let (store, project, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)

        store.handleTerminalDesktopNotification(taskID: idA, title: "Pi has a question", body: "Ready?")

        #expect(store.openTerminalTaskIDs == [idA, idB])
        try await waitUntil {
            store.tasksByProject[project.id!]?.first?.id == idA
        }
        #expect(store.tasksByProject[project.id!]?.first?.id == idA)
    }

    @Test("Selecting a task does not bump ordering")
    func selectingTaskDoesNotBumpOrdering() async throws {
        let (store, project, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)

        store.selectTask(taskA, project: project)

        #expect(store.openTerminalTaskIDs == [idA, idB])
    }

    @Test("A .finished alert does not bump ordering")
    func finishedAlertDoesNotBumpOrdering() async throws {
        let (store, _, taskA, taskB) = try await makeStore()
        let idA = try #require(taskA.id)
        let idB = try #require(taskB.id)
        store.noteTerminalOpened(taskID: idA)
        store.noteTerminalOpened(taskID: idB)

        store.handleTerminalDesktopNotification(taskID: idA, title: "Pi finished", body: "Ready for your next prompt.")

        #expect(store.openTerminalTaskIDs == [idA, idB])
    }
}
