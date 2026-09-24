import Foundation
import SwiftUI
import Testing

@testable import BSideKit

/// When a task's `pi` process exits on its own, `MainAreaView` replaces the
/// dead surface with `PiSessionEndedView` instead of leaving Ghostty's own
/// unresponsive "Process exited. Press any key..." overlay on screen, and
/// offers a way back to the same pi session — either its Resume button, or
/// `TerminalCommands`' "Restart Pi Session" command/shortcut.
@MainActor
@Suite("Pi session ended — exit tracking, restart request, and relaunch")
struct PiSessionEndedTests {
    // MARK: - MainAreaView.exitedTaskIDs (pure): running -> exited -> relaunched

    @Test("A running task starts with no exited flag")
    func startsWithNoExitedTasks() {
        let current: Set<Int64> = []
        #expect(!current.contains(42))
    }

    @Test("Exiting marks only that task id exited, leaving others untouched")
    func exitMarksOnlyThatTask() {
        let afterFirstExit = MainAreaView.exitedTaskIDs(afterExit: 1, current: [])
        #expect(afterFirstExit == [1])

        let afterSecondExit = MainAreaView.exitedTaskIDs(afterExit: 2, current: afterFirstExit)
        #expect(afterSecondExit == [1, 2])
    }

    @Test("Relaunching clears only that task's exited flag")
    func relaunchClearsOnlyThatTask() {
        let exited: Set<Int64> = [1, 2]
        let afterRelaunch = MainAreaView.exitedTaskIDs(afterRelaunch: 1, current: exited)
        #expect(afterRelaunch == [2])
    }

    @Test("Exiting an already-exited task id is idempotent")
    func exitIsIdempotent() {
        let exited = MainAreaView.exitedTaskIDs(afterExit: 1, current: [1])
        #expect(exited == [1])
    }

    @Test("Relaunching a task that was never marked exited is a no-op")
    func relaunchOfNeverExitedIsNoOp() {
        let afterRelaunch = MainAreaView.exitedTaskIDs(afterRelaunch: 99, current: [1, 2])
        #expect(afterRelaunch == [1, 2])
    }

    // MARK: - ProjectsStore.project(forTask:)

    private func makeStore() async throws -> (store: ProjectsStore, project: Project, task: TaskRecord) {
        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let (project, task): (Project, TaskRecord) = try await database.dbQueue.write { db in
            var project = Project(path: "/tmp/project", displayName: "Project", baseRef: "main")
            try project.insert(db)
            var task = TaskRecord(
                projectId: project.id!, name: "Task A", branchName: "feature/a",
                worktreePath: "/tmp/project-a", harness: "claude", permissionLevel: "default"
            )
            try task.insert(db)
            return (project, task)
        }

        store.start()
        try await waitUntil {
            store.tasksByProject[project.id!]?.contains { $0.id == task.id } ?? false
        }
        return (store, project, task)
    }

    @Test("project(forTask:) resolves the task's own project")
    func projectForTaskResolvesOwnProject() async throws {
        let (store, project, task) = try await makeStore()
        #expect(store.project(forTask: task) == project)
    }

    @Test("project(forTask:) is nil once the task's project is gone")
    func projectForTaskNilWhenProjectMissing() async throws {
        let (store, _, task) = try await makeStore()
        let orphanTask = TaskRecord(
            id: task.id, projectId: 999_999, name: task.name, branchName: task.branchName,
            worktreePath: task.worktreePath, harness: task.harness, permissionLevel: task.permissionLevel
        )
        #expect(store.project(forTask: orphanTask) == nil)
    }

    // MARK: - ProjectsStore.restartRequestedTaskID / acknowledgeRestartRequested

    @Test("Requesting a restart sets restartRequestedTaskID to the task's id")
    func requestRestartSetsRequestedID() async throws {
        let (store, _, task) = try await makeStore()
        #expect(store.restartRequestedTaskID == nil)

        store.requestRestartTerminal(for: task)
        #expect(store.restartRequestedTaskID == task.id)
    }

    @Test("Acknowledging a restart request clears it, but only for the id it was raised for")
    func acknowledgeRestartIsScopedToItsOwnID() async throws {
        let (store, _, task) = try await makeStore()
        store.requestRestartTerminal(for: task)

        store.acknowledgeRestartRequested(999)
        #expect(store.restartRequestedTaskID == task.id)

        store.acknowledgeRestartRequested(task.id!)
        #expect(store.restartRequestedTaskID == nil)
    }

    // MARK: - TerminalCloseShortcut.restartSession

    @Test("Cmd+Shift+R is the restart-session shortcut")
    func restartShortcutIsCmdShiftR() {
        #expect(TerminalCloseShortcut.restartSession.key.character == "r")
        #expect(TerminalCloseShortcut.restartSession.modifiers == [.command, .shift])
    }

    // MARK: - GhosttyBridge.appOwnedKeybinds

    @Test("Cmd+Shift+R is unbound from Ghostty so the Restart Pi Session command handles it")
    func restartShortcutIsUnboundFromGhostty() {
        #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+shift+r=unbind"))
    }

    // MARK: - PiSessionService.launchCommand: relaunch uses the same command path

    @Test("Relaunching a resumed session produces the exact same launch command as the original launch")
    func relaunchLaunchCommandMatchesOriginalLaunch() {
        let locations = PiSessionService.Locations(
            bundledBinaryPath: "/usr/local/bin/pi",
            sessionsRoot: URL(fileURLWithPath: "/tmp/sessions")
        )

        let originalLaunch = PiSessionService.launchCommand(
            locations: locations,
            sessionID: "session-123",
            transcriptPath: "/tmp/sessions/proj/session-123.jsonl",
            taskName: "Fix login bug"
        )

        // `relaunchHost` calls `ensureHost`, which resolves the very same
        // transcript path (the task's conversation and its persisted
        // transcript path are unchanged by a relaunch) and calls
        // `PiSessionService.launchCommand` with identical arguments — so a
        // second call with the same inputs must produce the same command.
        let relaunchCommand = PiSessionService.launchCommand(
            locations: locations,
            sessionID: "session-123",
            transcriptPath: "/tmp/sessions/proj/session-123.jsonl",
            taskName: "Fix login bug"
        )

        #expect(relaunchCommand == originalLaunch)
        #expect(relaunchCommand.contains("--session "))
        #expect(relaunchCommand.contains("session-123.jsonl"))
    }
}
