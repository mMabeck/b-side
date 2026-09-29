import Foundation
import SwiftUI
import Testing

@testable import BSideKit

@MainActor
@Suite("Terminal close (Cmd+W) and quit (Cmd+Q)")
struct TerminalCloseTests {

    @Test("nextActiveTaskID picks the task that took the closed slot, falls back to the new last entry, or nil", arguments: [
        (closing: Int64(20), open: [10, 20, 30], expected: Int64(30)),
        (closing: Int64(10), open: [10, 20, 30], expected: Int64(20)),
        (closing: Int64(30), open: [10, 20, 30], expected: Int64(20)),
        (closing: Int64(10), open: [10], expected: nil),
        (closing: Int64(99), open: [10, 20], expected: nil),
    ] as [(Int64, [Int64], Int64?)])
    func nextActiveTaskID(closing: Int64, open openIDs: [Int64], expected: Int64?) {
        #expect(ProjectsStore.nextActiveTaskID(afterClosing: closing, in: openIDs) == expected)
    }


    private func makeStore() async throws -> (store: ProjectsStore, project: Project, taskA: TaskRecord, taskB: TaskRecord) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let (project, taskA, taskB): (Project, TaskRecord, TaskRecord) = try await database.dbQueue.write { db in
            var project = Project(path: "/tmp/project", displayName: "Project", baseRef: "main")
            try project.insert(db)
            var taskA = TaskRecord(
                projectId: project.id!, name: "Task A", branchName: "feature/a",
                worktreePath: "/tmp/project-a", harness: "claude", permissionLevel: "default"
            )
            try taskA.insert(db)
            var taskB = TaskRecord(
                projectId: project.id!, name: "Task B", branchName: "feature/b",
                worktreePath: "/tmp/project-b", harness: "claude", permissionLevel: "default"
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

    @Test("Closing a task's terminal drops it from openTerminalTaskIDs and selects the next one")
    func closeTerminalRemovesAndSelectsNext() async throws {
        let (store, project, taskA, taskB) = try await makeStore()
        store.noteTerminalOpened(taskID: taskA.id!)
        store.noteTerminalOpened(taskID: taskB.id!)
        store.selectTask(taskA, project: project)

        store.closeTerminal(for: taskA, project: project)

        #expect(store.openTerminalTaskIDs == [taskB.id!])
        #expect(store.selectedTaskID == taskB.id)
        #expect(store.closedTerminalTaskID == taskA.id)
    }


    @Test("Cmd+Q, Cmd+W, and other standard app shortcuts Ghostty could swallow are unbound so AppKit's menu handles them")
    func standardShortcutsAreUnboundFromGhostty() {
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+q=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+w=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+n=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+shift+n=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+h=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+m=unbind"))
    }

}
