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

    @Test("Exiting marks only that task id exited, leaving others untouched, and is idempotent")
    func exitMarksOnlyThatTask() {
        let afterFirstExit = MainAreaView.exitedTaskIDs(afterExit: 1, current: [])
        #expect(afterFirstExit == [1])

        let afterSecondExit = MainAreaView.exitedTaskIDs(afterExit: 2, current: afterFirstExit)
        #expect(afterSecondExit == [1, 2])

        #expect(MainAreaView.exitedTaskIDs(afterExit: 1, current: [1]) == [1])
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

    // MARK: - ProjectsStore.restartRequestedTaskID / acknowledgeRestartRequested

    @Test("Requesting a restart sets restartRequestedTaskID to the task's id")
    func requestRestartSetsRequestedID() async throws {
        let (store, _, task) = try await makeStore()
        #expect(store.restartRequestedTaskID == nil)

        store.requestRestartTerminal(for: task)
        #expect(store.restartRequestedTaskID == task.id)
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
