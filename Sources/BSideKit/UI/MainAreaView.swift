import AppKit
import Foundation
import SwiftUI

/// Terminals stay cached by task id and are only hidden: destroying a `TerminalSurfaceHost` kills its pty.
/// `token` in the `.task(id:)` key reruns it when the selected task is reselected.
private struct FocusRequestKey: Equatable {
    let taskID: Int64?
    let token: Int
}

struct MainAreaView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var hostsByTaskID: [Int64: TerminalSurfaceHost] = [:]

    @FocusState private var focusedTaskID: Int64?

    /// Pi exited on its own; the slot shows `PiSessionEndedView` instead of the terminal.
    @State private var exitedTaskIDs: Set<Int64> = []

    /// Serializes `ensureHost` per task so a rapid A -> B -> A switch can't start two conversations.
    @State private var conversationGate = ConversationLaunchGate()

    @State private var autoRenameWatchers: [Int64: Task<Void, Never>] = [:]

    private var liveTaskIDs: Set<Int64> {
        Set(store.tasksByProject.values.flatMap { $0.compactMap(\.id) })
    }

    var body: some View {
        ZStack {
            ForEach(hostsByTaskID.keys.sorted(), id: \.self) { taskID in
                if let host = hostsByTaskID[taskID] {
                    let isVisible = taskID == MainAreaView.visibleTaskID(for: store.mainSelection)
                    TaskTerminalAreaView(
                        store: store,
                        host: host,
                        taskID: taskID,
                        focusedTaskID: $focusedTaskID,
                        isExited: exitedTaskIDs.contains(taskID),
                        onResume: { requestRelaunch(taskID: taskID) },
                        isSelected: isVisible
                    )
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    TerminalAlertBridge(host: host, store: store, taskID: taskID)
                }
            }

            switch store.mainSelection {
            case .none:
                emptyStateView
            case .project(let project):
                ProjectDashboardView(store: store, project: project)
            case .task:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.windowBackground)
        .task(id: FocusRequestKey(taskID: store.selectedTaskID, token: store.focusRequestToken)) {
            if case .task(let task, let project) = store.mainSelection {
                await ensureHost(for: task, project: project)
            }
            syncVisibility()
            syncFocus()
        }
        .onChange(of: liveTaskIDs) { _, ids in
            purgeHosts(keeping: ids)
        }
        .onChange(of: store.subagentPanes.version) { _, _ in
            MainAreaView.reconcileSwap(store.subagentSwap, panesByTask: store.subagentPanes.panesByTask)
            syncVisibility()
        }
        .onChange(of: store.subagentSwap.version) { _, _ in
            syncVisibility()
            syncFocus()
        }
        .onChange(of: store.closedTerminalTaskID) { _, closedID in
            guard let closedID else { return }
            closeHost(taskID: closedID)
            store.acknowledgeTerminalClosed(closedID)
        }
        .onChange(of: store.restartRequestedTaskID) { _, requestedID in
            guard let requestedID else { return }
            Task {
                if let task = store.task(withId: requestedID), let project = store.project(forTask: task) {
                    await relaunchHost(for: task, project: project)
                }
                store.acknowledgeRestartRequested(requestedID)
            }
        }
        // Returning from another app leaves first responder elsewhere; refocus unless a terminal (e.g. the drawer's) holds it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, TerminalSurfaceHost.isTerminalView(window.firstResponder) {
                return
            }
            syncFocus()
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        if store.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a project to start creating tasks.")
            } actions: {
                Button("Add Project") {
                    ProjectCreation.addProject(store: store)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.palette.accent)
            }
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "arrow.left")
            } description: {
                Text("Select a project or task.")
            }
        }
    }

    @MainActor
    private func ensureHost(for task: TaskRecord, project: Project) async {
        guard let id = task.id, hostsByTaskID[id] == nil else { return }
        guard let conversation = await conversationGate.ensureConversation(for: task, store: store) else { return }

        let locations = PiSessionService.Locations.standard()
        let workingDirectory = MainAreaView.resolvedDirectory(forTask: task, project: project)

        // A stale transcript `cwd` would make `pi` exit 1; `resolveTranscriptForResume` repairs it first.
        let resolved = await Self.resolveTranscriptForResumeOffMain(
            conversation: conversation,
            currentWorkingDirectory: workingDirectory.path,
            locations: locations
        )
        if let pathToPersist = resolved.transcriptPathToPersist {
            try? await store.recordTranscriptPath(pathToPersist, for: conversation)
        }

        let command = PiSessionService.launchCommand(
            locations: locations,
            sessionID: conversation.sessionId,
            transcriptPath: resolved.transcriptPathForLaunch,
            taskName: task.name
        )
        guard hostsByTaskID[id] == nil else { return }
        let exitedBinding = $exitedTaskIDs
        hostsByTaskID[id] = TerminalSurfaceHost(
            workingDirectory: workingDirectory,
            command: command,
            envVars: PiSessionService.launchEnvironment(taskId: id, subagentEndpoint: store.subagentServer?.address),
            // Fires when `pi` exits on its own; app-initiated teardown removes the id outright.
            onExit: { [exitedBinding, store] _ in
                exitedBinding.wrappedValue = MainAreaView.exitedTaskIDs(afterExit: id, current: exitedBinding.wrappedValue)
                store.dropTaskBusy(id)
            }
        )
        store.noteTerminalOpened(taskID: id)

        if resolved.transcriptPathForLaunch == nil {
            Task { await Self.resolveTranscriptPath(for: conversation, locations: locations, store: store) }
        }
        if task.awaitingAutoRename {
            autoRenameWatchers[id] = Task {
                await Self.watchForAutoRename(taskId: id, project: project, conversation: conversation, locations: locations, store: store)
            }
        }
    }

    @MainActor
    private static func resolveTranscriptPath(
        for conversation: Conversation,
        locations: PiSessionService.Locations,
        store: ProjectsStore
    ) async {
        for _ in 0..<40 {
            if let url = await Self.locateTranscriptOffMain(sessionID: conversation.sessionId, locations: locations) {
                try? await store.recordTranscriptPath(url.path, for: conversation)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Off the main actor: walks the whole sessions tree (~230 MB), long enough to stall task switching.
    private static func locateTranscriptOffMain(
        sessionID: String,
        locations: PiSessionService.Locations
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            PiSessionService.locateTranscript(sessionID: sessionID, locations: locations)
        }.value
    }

    /// Off the main actor: can rewrite a transcript of tens of MB.
    private static func resolveTranscriptForResumeOffMain(
        conversation: Conversation,
        currentWorkingDirectory: String,
        locations: PiSessionService.Locations
    ) async -> PiSessionService.ResolvedTranscript {
        await Task.detached(priority: .utility) {
            PiSessionService.resolveTranscriptForResume(
                conversation: conversation,
                currentWorkingDirectory: currentWorkingDirectory,
                locations: locations
            )
        }.value
    }

    /// Off the main actor, like `locateTranscriptOffMain`.
    private static func firstUserPromptTextOffMain(url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines)
        }.value
    }

    @MainActor
    private static func watchForAutoRename(
        taskId: Int64,
        project: Project,
        conversation: Conversation,
        locations: PiSessionService.Locations,
        store: ProjectsStore
    ) async {
        let deadline = Date().addingTimeInterval(autoRenameWatchDuration)
        while !Task.isCancelled, Date() < deadline {
            guard let task = store.task(withId: taskId), task.awaitingAutoRename else { return }

            if let url = await Self.locateTranscriptOffMain(sessionID: conversation.sessionId, locations: locations),
                let prompt = await Self.firstUserPromptTextOffMain(url: url)
            {
                await store.applyAutoRename(task: task, project: project, prompt: prompt)
                return
            }

            try? await Task.sleep(nanoseconds: 750_000_000)
        }
    }

    private static let autoRenameWatchDuration: TimeInterval = 30 * 60

    private func syncVisibility() {
        let visibleID = MainAreaView.visibleTaskID(for: store.mainSelection)
        for (id, host) in hostsByTaskID {
            let shownChildID = store.subagentSwap.shownChildID(forTask: id)
            host.isVisible = (id == visibleID) && shownChildID == nil
        }
        for (id, panes) in store.subagentPanes.panesByTask {
            let shownChildID = store.subagentSwap.shownChildID(forTask: id)
            for pane in panes {
                pane.host.isVisible = (id == visibleID) && pane.id == shownChildID
            }
        }
    }

    /// Hiding doesn't resign first responder; without this keystrokes land in the invisible terminal.
    private func syncFocus() {
        let visibleID = MainAreaView.visibleTaskID(for: store.mainSelection)
        focusedTaskID = visibleID

        for (id, host) in hostsByTaskID where id != visibleID {
            host.resignFocus()
        }
        for panes in store.subagentPanes.panesByTask.values {
            for pane in panes {
                pane.host.resignFocus()
            }
        }

        guard let visibleID, !exitedTaskIDs.contains(visibleID) else { return }

        // Focus must follow whichever surface is shown.
        let panes = store.subagentPanes.panes(forTask: visibleID)
        let shownChildID = store.subagentSwap.shownChildID(forTask: visibleID)
        switch MainAreaView.focusTarget(shownChildID: shownChildID, livePaneIDs: Set(panes.map(\.id))) {
        case .child(let childID):
            panes.first(where: { $0.id == childID })?.host.focus()
        case .parent:
            hostsByTaskID[visibleID]?.focus()
        }
    }

    enum FocusTarget: Equatable {
        case parent
        case child(String)
    }

    static func focusTarget(shownChildID: String?, livePaneIDs: Set<String>) -> FocusTarget {
        if let shownChildID, livePaneIDs.contains(shownChildID) {
            return .child(shownChildID)
        }
        return .parent
    }

    /// Releases the `conversationGate` claim explicitly: the task is still live, so a reopen would find the id claimed.
    private func closeHost(taskID: Int64) {
        guard hostsByTaskID.removeValue(forKey: taskID) != nil else { return }
        autoRenameWatchers.removeValue(forKey: taskID)?.cancel()
        store.pruneOpenTerminals(removing: [taskID])
        conversationGate.releaseClaim(for: taskID)
        store.subagentPanes.closeAll(taskId: taskID)
        store.subagentSwap.closeAll(taskId: taskID)
        store.subagentStripBatches.reset(taskId: taskID)
        exitedTaskIDs.remove(taskID)
        store.dropTaskBusy(taskID)
    }

    private func purgeHosts(keeping liveTaskIDs: Set<Int64>) {
        let purged = MainAreaView.idsToPurge(cachedIDs: Set(hostsByTaskID.keys), liveTaskIDs: liveTaskIDs)
        for id in purged {
            hostsByTaskID.removeValue(forKey: id)
            autoRenameWatchers.removeValue(forKey: id)?.cancel()
            store.subagentPanes.closeAll(taskId: id)
            store.subagentSwap.closeAll(taskId: id)
            store.subagentStripBatches.reset(taskId: id)
            exitedTaskIDs.remove(id)
            store.dropTaskBusy(id)
        }
        store.pruneOpenTerminals(removing: purged)
        conversationGate.release(exceptLiveTaskIDs: liveTaskIDs)
    }

    private func requestRelaunch(taskID: Int64) {
        guard let task = store.task(withId: taskID), let project = store.project(forTask: task) else { return }
        Task { await relaunchHost(for: task, project: project) }
    }

    @MainActor
    private func relaunchHost(for task: TaskRecord, project: Project) async {
        guard let id = task.id else { return }
        hostsByTaskID.removeValue(forKey: id)
        exitedTaskIDs = MainAreaView.exitedTaskIDs(afterRelaunch: id, current: exitedTaskIDs)
        conversationGate.releaseClaim(for: id)
        await ensureHost(for: task, project: project)
        syncVisibility()
        syncFocus()
    }

    static func exitedTaskIDs(afterExit taskID: Int64, current: Set<Int64>) -> Set<Int64> {
        current.union([taskID])
    }

    static func exitedTaskIDs(afterRelaunch taskID: Int64, current: Set<Int64>) -> Set<Int64> {
        current.subtracting([taskID])
    }

    static func idsToPurge(cachedIDs: Set<Int64>, liveTaskIDs: Set<Int64>) -> Set<Int64> {
        cachedIDs.subtracting(liveTaskIDs)
    }

    /// Without this a closed pane leaves `SubagentSwapStore` pointing at a dead surface.
    static func reconcileSwap(_ swap: SubagentSwapStore, panesByTask: [Int64: [SubagentPaneStore.ChildPane]]) {
        for (taskID, childID) in swap.shownChildIDByTask where !(panesByTask[taskID] ?? []).contains(where: { $0.id == childID }) {
            swap.handleClosed(childId: childID, taskId: taskID)
        }
        for (taskID, childID) in swap.highlightedChildIDByTask where !(panesByTask[taskID] ?? []).contains(where: { $0.id == childID }) {
            swap.handleClosed(childId: childID, taskId: taskID)
        }
    }

    static func visibleTaskID(for selection: MainSelection) -> Int64? {
        if case .task(let task, _) = selection {
            return task.id
        }
        return nil
    }

    /// Falls back so a vanished worktree never blocks opening; a missing dir would also make `pi --session` refuse to resume.
    static func resolvedDirectory(forTask task: TaskRecord, project: Project) -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: task.worktreePath, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return URL(fileURLWithPath: task.worktreePath)
        }
        var projectIsDirectory: ObjCBool = false
        let projectExists = FileManager.default.fileExists(atPath: project.path, isDirectory: &projectIsDirectory)
        if projectExists && projectIsDirectory.boolValue {
            return URL(fileURLWithPath: project.path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func resolvedDirectory(for store: ProjectsStore) -> URL {
        switch store.mainSelection {
        case .task(let task, let project):
            return resolvedDirectory(forTask: task, project: project)
        case .project(let project):
            return URL(fileURLWithPath: project.path)
        case .none:
            return FileManager.default.homeDirectoryForCurrentUser
        }
    }
}

/// Without this a rapid A -> B -> A switch could insert two conversation rows and leak a pty.
@MainActor
final class ConversationLaunchGate {
    private var claimedTaskIDs: Set<Int64> = []

    init() {}

    func ensureConversation(for task: TaskRecord, store: ProjectsStore) async -> Conversation? {
        guard let id = task.id, claim(id) else { return nil }
        var resolved = false
        defer { if !resolved { abandon(id) } }

        let conversation: Conversation
        if let existing = await store.activeConversation(forTaskId: id) {
            conversation = existing
        } else {
            let sessionID = PiSessionService.newSessionID()
            conversation = (try? await store.startConversation(for: task, sessionID: sessionID))
                ?? Conversation(taskId: id, sessionId: sessionID, transcriptPath: "")
        }

        resolved = true
        return conversation
    }

    func release(exceptLiveTaskIDs liveTaskIDs: Set<Int64>) {
        claimedTaskIDs.formIntersection(liveTaskIDs)
    }

    private func claim(_ id: Int64) -> Bool {
        guard !claimedTaskIDs.contains(id) else { return false }
        claimedTaskIDs.insert(id)
        return true
    }

    private func abandon(_ id: Int64) {
        claimedTaskIDs.remove(id)
    }

    func releaseClaim(for id: Int64) {
        claimedTaskIDs.remove(id)
    }
}
