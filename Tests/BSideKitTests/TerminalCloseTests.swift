import Foundation
import SwiftUI
import Testing

@testable import BSideKit

/// `Cmd+W` closes a task's terminal: `ProjectsStore.closeTerminal` drops it
/// from `openTerminalTaskIDs` and picks the next sensible selection, the
/// `TerminalCloseShortcut` key equivalent stays what `TerminalCommands`
/// binds, and Ghostty's own keybinds no longer swallow it or Cmd+Q first.
@MainActor
@Suite("Terminal close (Cmd+W) and quit (Cmd+Q)")
struct TerminalCloseTests {
    // MARK: - ProjectsStore.nextActiveTaskID (pure)

    @Test("Next active task id is the one that took the closed task's position")
    func nextActiveTaskIDTakesClosedPosition() {
        let openIDs: [Int64] = [10, 20, 30]
        #expect(ProjectsStore.nextActiveTaskID(afterClosing: 20, in: openIDs) == 30)
        #expect(ProjectsStore.nextActiveTaskID(afterClosing: 10, in: openIDs) == 20)
    }

    @Test("Closing the last open task falls back to the new last entry")
    func nextActiveTaskIDFallsBackToNewLast() {
        let openIDs: [Int64] = [10, 20, 30]
        #expect(ProjectsStore.nextActiveTaskID(afterClosing: 30, in: openIDs) == 20)
    }

    @Test("Closing the only open task leaves no next active task")
    func nextActiveTaskIDNilWhenNoneRemain() {
        #expect(ProjectsStore.nextActiveTaskID(afterClosing: 10, in: [10]) == nil)
    }

    @Test("Closing an id not tracked as open is a no-op")
    func nextActiveTaskIDNilForUntrackedID() {
        #expect(ProjectsStore.nextActiveTaskID(afterClosing: 99, in: [10, 20]) == nil)
    }

    // MARK: - ProjectsStore.closeTerminal (integration, real store)

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

    @Test("Closing the only open terminal selects the task's project dashboard")
    func closeTerminalFallsBackToProjectDashboard() async throws {
        let (store, project, taskA, _) = try await makeStore()
        store.noteTerminalOpened(taskID: taskA.id!)
        store.selectTask(taskA, project: project)

        store.closeTerminal(for: taskA, project: project)

        #expect(store.openTerminalTaskIDs.isEmpty)
        #expect(store.mainSelection == .project(project))
    }

    @Test("Acknowledging a close request clears it, but only for the id it was raised for")
    func acknowledgeTerminalClosedIsScopedToItsOwnID() async throws {
        let (store, project, taskA, _) = try await makeStore()
        store.noteTerminalOpened(taskID: taskA.id!)
        store.closeTerminal(for: taskA, project: project)

        store.acknowledgeTerminalClosed(999)
        #expect(store.closedTerminalTaskID == taskA.id)

        store.acknowledgeTerminalClosed(taskA.id!)
        #expect(store.closedTerminalTaskID == nil)
    }

    // MARK: - ConversationLaunchGate.releaseClaim

    @Test("Releasing a claim lets a task id be resolved by ensureConversation again")
    func releaseClaimAllowsReclaim() async throws {
        let (store, _, taskA, _) = try await makeStore()
        let gate = ConversationLaunchGate()

        let first = await gate.ensureConversation(for: taskA, store: store)
        #expect(first != nil)

        // Already resolved and still claimed: a second call for the same
        // task id must not resolve another conversation for it.
        let blocked = await gate.ensureConversation(for: taskA, store: store)
        #expect(blocked == nil)

        gate.releaseClaim(for: taskA.id!)

        let second = await gate.ensureConversation(for: taskA, store: store)
        #expect(second != nil)
    }

    // MARK: - TerminalCloseShortcut

    @Test("Cmd+W is the task-terminal-close shortcut")
    func closeTaskShortcutIsCmdW() {
        #expect(TerminalCloseShortcut.closeTask.key.character == "w")
        #expect(TerminalCloseShortcut.closeTask.modifiers == [.command])
    }

    // MARK: - GhosttyBridge.appOwnedKeybinds

    @Test("Cmd+Q and Cmd+W are unbound from Ghostty so AppKit's menu handles them")
    func quitAndCloseAreUnboundFromGhostty() {
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+q=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+w=unbind"))
    }

    @Test("Other standard app shortcuts Ghostty could swallow are unbound too")
    func otherStandardShortcutsAreUnbound() {
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+n=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+shift+n=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+h=unbind"))
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+m=unbind"))
    }

    @Test("Copy/paste/select-all/find are left to the terminal, not unbound")
    func editingShortcutsStayBoundToTheTerminal() {
        for key in ["c", "v", "a", "f"] {
            #expect(!GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+\(key)=unbind"))
        }
    }
}
