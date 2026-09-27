import AppKit
import Foundation
import SwiftUI

/// The main area: a task's terminal, a project's dashboard, or an empty
/// state, chosen by `ProjectsStore.mainSelection`.
///
/// Task terminals are cached by task id in `hostsByTaskID` and never torn
/// down on selection change, only hidden (per native-rewrite.md §6):
/// destroying a `TerminalSurfaceHost` kills its pty. Hosts are only ever
/// removed from the cache in `purgeHosts`, once their task is actually gone.
///
/// `token` rides along `selectedTaskID` in this key so a reselection of the
/// already-selected task still reruns `.task(id:)` (and `syncFocus()`) —
/// SwiftUI's `.task(id:)` only reruns when the id's value actually changes.
private struct FocusRequestKey: Equatable {
    let taskID: Int64?
    let token: Int
}

struct MainAreaView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var hostsByTaskID: [Int64: TerminalSurfaceHost] = [:]

    /// Terminal surfaces don't bridge through `@FocusState` (see `TerminalHostView`),
    /// but an exited task's Resume button is a real SwiftUI control, driven by `syncFocus()`.
    @FocusState private var focusedTaskID: Int64?

    /// Task ids whose parent host's Pi process exited on its own — distinct
    /// from the terminal being closed/purged, which drops the id from
    /// `hostsByTaskID` entirely. While present, that task's slot renders
    /// `PiSessionEndedView` instead of `TerminalHostView`, even while hidden.
    @State private var exitedTaskIDs: Set<Int64> = []

    /// Serializes `ensureHost` per task id so a rapid A -> B -> A selection
    /// change can't have two calls both see "no host yet" and each start their own conversation.
    @State private var conversationGate = ConversationLaunchGate()

    /// Retains each task's auto-rename poll loop so it can be cancelled once
    /// purged — an unstructured `Task` nothing references can't be cancelled, only abandoned.
    @State private var autoRenameWatchers: [Int64: Task<Void, Never>] = [:]

    private var liveTaskIDs: Set<Int64> {
        Set(store.tasksByProject.values.flatMap { $0.compactMap(\.id) })
    }

    var body: some View {
        ZStack {
            // Every cached terminal stays mounted regardless of selection; only
            // opacity/hit-testing tracks the active one. Sorted for deterministic iteration (dictionary order isn't).
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
                EmptyView() // matching cached host above is already visible
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
        // Switching away to another app/window and back leaves first responder
        // wherever AppKit put it, not the visible task's terminal; refocus it,
        // unless a terminal (e.g. the drawer's shell) already holds focus.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow, TerminalSurfaceHost.isTerminalView(window.firstResponder) {
                return
            }
            syncFocus()
        }
    }

    /// With no projects at all, invites adding one instead of a prompt describing a choice the user can't make yet.
    @ViewBuilder
    private var emptyStateView: some View {
        if store.projects.isEmpty {
            VStack(spacing: 10) {
                Text("No projects yet")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textSecondary)
                Button {
                    ProjectCreation.addProject(store: store)
                } label: {
                    Label("Add Project", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.selectionForeground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.palette.accent)
                        )
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("Select a project or task")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
        }
    }

    /// Reuses the task's active `Conversation` if one exists, else starts a
    /// fresh pi session, so reopening the task resumes the same session.
    /// Guarded twice against a concurrent call for the same task id:
    /// `conversationGate` claims it up front, and `hostsByTaskID` is re-checked before assignment.
    @MainActor
    private func ensureHost(for task: TaskRecord, project: Project) async {
        guard let id = task.id, hostsByTaskID[id] == nil else { return }
        guard let conversation = await conversationGate.ensureConversation(for: task, store: store) else { return }

        let locations = PiSessionService.Locations.standard()
        let workingDirectory = MainAreaView.resolvedDirectory(forTask: task, project: project)

        // A stale transcript header `cwd`, or one `resolveTranscriptPath`'s poll
        // hasn't caught up with yet, would otherwise make `pi` exit 1;
        // `resolveTranscriptForResume` scans by session id and repairs the cwd first.
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
            // Fires when the `pi` process exits on its own; an app-initiated
            // teardown goes through `closeHost`/`relaunchHost` instead, which remove the id outright.
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

    /// Bounded so a `pi` that never starts doesn't poll forever.
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

    /// Off the main actor: enumerates the whole sessions tree and reads every `.jsonl`, long enough on a ~230 MB tree to stall task switching.
    private static func locateTranscriptOffMain(
        sessionID: String,
        locations: PiSessionService.Locations
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            PiSessionService.locateTranscript(sessionID: sessionID, locations: locations)
        }.value
    }

    /// Off the main actor: can rewrite the whole transcript file, which can grow to tens of megabytes.
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

    /// Off the main actor, same reason as `locateTranscriptOffMain`; splitting and parsing happen in the detached work too.
    private static func firstUserPromptTextOffMain(url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines)
        }.value
    }

    /// Only started for a task with a blank name. Rechecks `task.awaitingAutoRename`
    /// against fresh state each poll, and stops once the deadline passes, so an unprompted task doesn't poll forever.
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

    /// Marks the active task's shown host visible, every other cached host
    /// not visible (per `TerminalSurfaceHost.isVisible`). Swapping only ever
    /// shows one surface per task, so a pane that isn't the shown child
    /// (or the parent, if a child is shown) stays not-visible even on the active task.
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

    /// `opacity`/`allowsHitTesting` hide a host and block clicks, but don't
    /// resign first responder — without this, switching tasks would leave
    /// keystrokes landing in the invisible one until clicked into.
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

        // An exited task has no live surface; setting `focusedTaskID` above already suffices for its Resume button.
        guard let visibleID, !exitedTaskIDs.contains(visibleID) else { return }

        // Focus must follow whichever surface (parent or swapped-in child) is actually shown.
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

    /// The shown child if still live, else the parent.
    static func focusTarget(shownChildID: String?, livePaneIDs: Set<String>) -> FocusTarget {
        if let shownChildID, livePaneIDs.contains(shownChildID) {
            return .child(shownChildID)
        }
        return .parent
    }

    /// Kills the pty/Pi process but leaves the transcript on disk. Releases
    /// the `conversationGate` claim explicitly, not via `release(exceptLiveTaskIDs:)`:
    /// the task is still live, so without this a reopen would find the id still claimed.
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

    /// `taskID` may have been deleted/archived while its dead surface sat on screen.
    private func requestRelaunch(taskID: Int64) {
        guard let task = store.task(withId: taskID), let project = store.project(forTask: task) else { return }
        Task { await relaunchHost(for: task, project: project) }
    }

    /// Relaunches via `ensureHost`'s normal path so the same pi session/transcript resumes.
    /// Releases the `conversationGate` claim the same way `closeHost` does.
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

    /// A pane closing independently would otherwise leave `SubagentSwapStore`
    /// pointing at a surface that no longer exists; reconciles back to "show the parent".
    static func reconcileSwap(_ swap: SubagentSwapStore, panesByTask: [Int64: [SubagentPaneStore.ChildPane]]) {
        for (taskID, childID) in swap.shownChildIDByTask where !(panesByTask[taskID] ?? []).contains(where: { $0.id == childID }) {
            swap.handleClosed(childId: childID, taskId: taskID)
        }
        for (taskID, childID) in swap.highlightedChildIDByTask where !(panesByTask[taskID] ?? []).contains(where: { $0.id == childID }) {
            swap.handleClosed(childId: childID, taskId: taskID)
        }
    }

    /// The single place `syncVisibility()`, `syncFocus()`, and `body`'s `ForEach`
    /// all decide "is this the active task's host", so they can't disagree.
    static func visibleTaskID(for selection: MainSelection) -> Int64? {
        if case .task(let task, _) = selection {
            return task.id
        }
        return nil
    }

    /// Worktree, else the project path, else home — a terminal must never
    /// fail to open over a vanished worktree, and this path is also written
    /// into a repaired transcript header, where a nonexistent dir would make `pi --session` refuse to resume.
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
        // Both gone: home, rather than a nonexistent cwd making `pi --session` exit 1.
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Shared with `TerminalDrawerView` so it never disagrees with the main area about "where is this selection, on disk".
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

/// Ensures at most one caller resolves a `Conversation` for a given task id
/// at a time. `ensureHost` awaits several times before a host exists to
/// check against; without this, a rapid A -> B -> A switch could let both
/// calls insert a row under a different pi session id and leak a pty.
///
/// A separate type (not inline `@State`) so the dedup is testable without a
/// live AppKit/libghostty `TerminalSurfaceHost`.
@MainActor
final class ConversationLaunchGate {
    private var claimedTaskIDs: Set<Int64> = []

    init() {}

    /// `nil` means the claim failed; the caller must do nothing further for this task right now, not treat it as an error.
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

    /// Mirrors `MainAreaView.purgeHosts` so an id reappearing later (e.g. unarchived) isn't stuck claimed forever.
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

    /// Used when the terminal is closed explicitly rather than the task going away.
    func releaseClaim(for id: Int64) {
        claimedTaskIDs.remove(id)
    }
}
