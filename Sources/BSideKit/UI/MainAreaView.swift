import AppKit
import Foundation
import SwiftUI

/// The main area: a task's terminal, a project's dashboard, or an empty
/// state, chosen by `ProjectsStore.mainSelection`. A project alone is never
/// a terminal — only a task is — so `.project` renders `ProjectDashboardView`
/// and only `.task` mounts a shell.
///
/// Task terminals are cached by task id in `hostsByTaskID` and never torn
/// down on selection change, only hidden (zero opacity, not hit-testable) —
/// the same "stays mounted, marked not-visible" approach `ContentView` and
/// `TerminalDrawerView` use for the bottom drawer (see their doc comments and
/// native-rewrite.md §6). Destroying a `TerminalSurfaceHost` kills its pty;
/// switching from task A to task B and back must not kill A's shell. Hosts
/// are only ever removed from the cache in `purgeHosts`, once their task has
/// actually been deleted or archived out of `tasksByProject`.
/// `MainAreaView`'s `.task(id:)` key: `selectedTaskID` alone would skip a
/// reselection of the already-selected task (SwiftUI's `.task(id:)` only
/// re-runs when its id's value actually changes), so `token` —
/// `ProjectsStore.focusRequestToken`, bumped on every `selectTask`/
/// `selectProject` call — rides along to force a rerun (and so a
/// `syncFocus()`) every time, not just when the selected task changes.
private struct FocusRequestKey: Equatable {
    let taskID: Int64?
    let token: Int
}

struct MainAreaView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var hostsByTaskID: [Int64: TerminalSurfaceHost] = [:]

    /// Task ids whose parent host's Pi process has exited on its own —
    /// distinct from the task's terminal being closed or purged, which
    /// drops the id from `hostsByTaskID` entirely instead. While an id is
    /// in here, its cached host's slot in the view tree renders
    /// `PiSessionEndedView` (see `TaskTerminalAreaView`) instead of the
    /// (dead) `TerminalHostView`, whether or not that task is currently the
    /// visible one — so a hidden task whose Pi exits shows the same state
    /// once it's selected. Cleared by `relaunchHost(for:project:)`, and by
    /// `closeHost`/`purgeHosts` when the task's terminal or the task itself
    /// goes away.
    @State private var exitedTaskIDs: Set<Int64> = []

    /// Serializes `ensureHost` per task id so concurrent calls (e.g. a rapid
    /// A -> B -> A selection change re-triggering `.task(id:)`) can't both
    /// see "no host yet" and each start their own conversation — see
    /// `ConversationLaunchGate`.
    @State private var conversationGate = ConversationLaunchGate()

    /// Retains each task's auto-rename poll loop so it can actually be
    /// cancelled once its task's host is purged — an unstructured `Task`
    /// nothing holds a reference to can never be cancelled, only abandoned.
    @State private var autoRenameWatchers: [Int64: Task<Void, Never>] = [:]

    /// Which cached host, if any, should hold keyboard focus — driven
    /// explicitly by `syncFocus()` rather than left to click-to-focus, since
    /// every cached host stays mounted underneath the visible one and AppKit
    /// has no reason to move first responder on its own when the *SwiftUI*
    /// selection changes. See `syncFocus()` for what goes wrong without this.
    @FocusState private var focusedTaskID: Int64?

    private var liveTaskIDs: Set<Int64> {
        Set(store.tasksByProject.values.flatMap { $0.compactMap(\.id) })
    }

    var body: some View {
        ZStack {
            // Every cached terminal stays mounted here regardless of the
            // current selection; only its opacity/hit-testing tracks whether
            // its task is the active one. Sorted so cache iteration order is
            // deterministic (dictionary order is not) — mostly a debugging/
            // diffing convenience, since the ZStack itself doesn't care.
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
                EmptyView() // the matching cached host above is already visible
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
        // A task's surface only holds first responder while its window is
        // key; switching away to another app or window and back leaves the
        // outgoing responder wherever AppKit put it (often nowhere, or the
        // window itself) rather than the visible task's terminal — refocus
        // it deterministically the same way `syncFocus()` does for an
        // explicit selection change.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            syncFocus()
        }
    }

    /// With no projects at all, invites adding one instead of the plain
    /// "Select a project or task" prompt, which would otherwise describe a
    /// choice the user has no way to make yet — mirrors the sidebar's own
    /// `emptyProjectsState` for the same reason.
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

    /// Launches (or reattaches to) a task's agent terminal: reuses its
    /// active `Conversation` if one already exists, else starts a new one
    /// under a fresh pi session id, then spawns `pi` with
    /// `PiSessionService.launchCommand` so reopening the task or restarting
    /// the app resumes the same pi session instead of a fresh one.
    ///
    /// Guarded twice against a concurrent call for the same task id (e.g. a
    /// rapid A -> B -> A selection change): `conversationGate` claims the id
    /// up front so only one call ever resolves a conversation for it, and
    /// `hostsByTaskID` is re-checked immediately before assignment as a
    /// second line of defense, since nothing else may race to create a host.
    @MainActor
    private func ensureHost(for task: TaskRecord, project: Project) async {
        guard let id = task.id, hostsByTaskID[id] == nil else { return }
        guard let conversation = await conversationGate.ensureConversation(for: task, store: store) else { return }

        let locations = PiSessionService.Locations.standard()
        let workingDirectory = MainAreaView.resolvedDirectory(forTask: task, project: project)

        // A task renamed before this worktree directory stopped moving may
        // still have a transcript whose header `cwd` is stale, and/or the
        // bounded poll in `resolveTranscriptPath` below may never have caught
        // up with a transcript pi already wrote — `resolveTranscriptForResume`
        // handles both by scanning for the transcript by session id and
        // repairing its stored cwd before handing `pi` a command that's
        // otherwise guaranteed to exit 1. See its doc comment for why
        // `--session-id` is not a safe fallback here.
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
            // Fires when this task's `pi` process exits on its own — the
            // user quit it, or it crashed — regardless of `processAlive`
            // (an explicit teardown the app itself initiated goes through
            // `closeHost`/`relaunchHost` instead, which remove the id from
            // `hostsByTaskID` outright rather than leaving a dead surface
            // behind for this to mark exited).
            onExit: { [exitedBinding] _ in
                exitedBinding.wrappedValue = MainAreaView.exitedTaskIDs(afterExit: id, current: exitedBinding.wrappedValue)
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

    /// Polls the sessions directory for the transcript pi creates shortly
    /// after launch, then persists it once found. Bounded so a `pi` that
    /// never starts (missing binary, launch failure) doesn't poll forever.
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

    /// Runs `PiSessionService.locateTranscript` off the main actor: it
    /// enumerates the whole sessions tree and reads from every `.jsonl`
    /// file, which on a real, ~230 MB sessions directory is long enough to
    /// stall task switching if run directly on the main actor — and this is
    /// called on every poll tick from two different loops above.
    private static func locateTranscriptOffMain(
        sessionID: String,
        locations: PiSessionService.Locations
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            PiSessionService.locateTranscript(sessionID: sessionID, locations: locations)
        }.value
    }

    /// Runs `PiSessionService.resolveTranscriptForResume` off the main actor
    /// for the same reason: it can scan the whole sessions tree and reads
    /// and rewrites the whole transcript file, which real transcripts can
    /// grow to tens of megabytes.
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

    /// Reads `url` off the main actor and extracts the task's first user
    /// prompt, for the same reason as `locateTranscriptOffMain` above —
    /// used by `watchForAutoRename`, which polls every 750ms for up to 30
    /// minutes, against a transcript that can already be tens of megabytes
    /// by its first poll. Splitting into lines and parsing happen inside the
    /// detached work too, not just the read, so none of that repeated cost
    /// lands on the main actor either.
    private static func firstUserPromptTextOffMain(url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines)
        }.value
    }

    /// Watches `conversation`'s transcript for the task's first user prompt
    /// and, once found, applies the once-only automatic rename it drives
    /// (see `TaskAutoRenameService`). Only ever started for a task created
    /// with a blank name (`task.awaitingAutoRename`); stops polling as soon
    /// as the rename resolves — successfully or not — since
    /// `ProjectsStore.applyAutoRename` always clears that flag, which this
    /// loop rechecks against the freshest known task state on every poll.
    ///
    /// Also stops once `autoRenameDeadline` passes, so a task the user never
    /// prompts doesn't poll the sessions tree forever — `ensureHost` retains
    /// this in `autoRenameWatchers` and `purgeHosts` cancels it directly the
    /// moment the task itself goes away, but a task can also just sit idle
    /// indefinitely with its host still live.
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

    /// How long `watchForAutoRename` keeps polling for a task's first
    /// prompt before giving up. Generous enough for a task the user is
    /// still composing a prompt for, but finite so an unprompted, forgotten
    /// task doesn't poll forever.
    private static let autoRenameWatchDuration: TimeInterval = 30 * 60

    /// Marks the active task's *shown* host visible and every other cached
    /// host not visible, so hidden surfaces stop drawing frames nobody sees
    /// (per `TerminalSurfaceHost.isVisible`'s own doc comment) without
    /// losing their grid, scrollback, or running shell. Derived from
    /// `mainSelection`, not the raw `selectedTaskID`, so this never
    /// disagrees with which branch of the `switch` above is actually on
    /// screen — see `visibleTaskID(for:)`.
    ///
    /// "The active task" alone isn't enough for panes: swapping (per
    /// `ProjectsStore.subagentSwap`) only ever shows *one* surface for a
    /// task at a time, so a pane that isn't the currently shown child must
    /// stay not-visible even while its task is the visible one — same for
    /// the parent host when a child is shown instead.
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

    /// Explicitly moves keyboard focus to the active task's host (or off of
    /// every host, when the main selection isn't a task) rather than
    /// leaving it wherever it last was. `opacity`/`allowsHitTesting` hide a
    /// host visually and stop clicks from reaching it, but neither resigns
    /// its terminal view as first responder — without this, switching from
    /// task A to task B would leave keystrokes still landing in A's shell
    /// (invisible, but very much still running) until the user clicked into
    /// B, which can mean running a command against the wrong worktree.
    ///
    /// Sets both the `@FocusState` binding *and* calls
    /// `TerminalViewState.requestFocus()` on the newly visible host, because
    /// neither alone is reliable here. `@FocusState`/`.terminalFocused(_:equals:)`
    /// is what resigns the *outgoing* surface as first responder on AppKit,
    /// but per `TerminalViewState.requestFocus()`'s own doc comment it is
    /// only best-effort for *acquiring* focus: with several hosts competing
    /// for one `@FocusState`, SwiftUI's focus engine can reset the state to
    /// nil before the bridge acts on it, leaving the previous host's surface
    /// holding first responder. `requestFocus()` is the deterministic path a
    /// host-driven switch needs, and it self-replays if the newly created
    /// host's view isn't attached to a window yet.
    private func syncFocus() {
        let visibleID = MainAreaView.visibleTaskID(for: store.mainSelection)
        focusedTaskID = visibleID
        // An exited task has no live surface to hand focus to —
        // `PiSessionEndedView`'s Resume button reads `focusedTaskID` itself
        // (see its doc comment) via the same `.focused` binding a running
        // task's `TerminalHostView` uses, so setting `focusedTaskID` above
        // is already enough for it.
        guard let visibleID, !exitedTaskIDs.contains(visibleID) else { return }
        // A child's surface can be swapped into the main area in place of
        // the parent (`ProjectsStore.subagentSwap`) — focus must follow
        // whichever one is actually shown, or the parent keeps first
        // responder while a child's terminal is what's on screen.
        let panes = store.subagentPanes.panes(forTask: visibleID)
        let shownChildID = store.subagentSwap.shownChildID(forTask: visibleID)
        switch MainAreaView.focusTarget(shownChildID: shownChildID, livePaneIDs: Set(panes.map(\.id))) {
        case .child(let childID):
            panes.first(where: { $0.id == childID })?.host.state.requestFocus()
        case .parent:
            hostsByTaskID[visibleID]?.state.requestFocus()
        }
    }

    enum FocusTarget: Equatable {
        case parent
        case child(String)
    }

    /// Which surface `syncFocus()` should hand keyboard focus to: the shown
    /// child, if `shownChildID` names one that's actually still live, or the
    /// parent otherwise (no child shown, or a stale id left over from one
    /// that already closed). Pure so it's directly testable.
    static func focusTarget(shownChildID: String?, livePaneIDs: Set<String>) -> FocusTarget {
        if let shownChildID, livePaneIDs.contains(shownChildID) {
            return .child(shownChildID)
        }
        return .parent
    }

    /// Ends one task's terminal without waiting for its task to be deleted
    /// or archived (`purgeHosts` only evicts those): tears down its
    /// `TerminalSurfaceHost` — killing the pty/Pi process, but leaving the
    /// Pi session transcript on disk so reopening the task resumes it —
    /// cancels its auto-rename watcher, and releases both the open-terminal
    /// tracking (`ProjectsStore.pruneOpenTerminals`, mirroring `purgeHosts`)
    /// and its `conversationGate` claim. Releasing the claim specifically
    /// (rather than `release(exceptLiveTaskIDs:)`, which only drops ids no
    /// longer live) matters here: the task itself is still live, so without
    /// this reopening it would find the id still claimed and `ensureHost`
    /// would silently do nothing.
    private func closeHost(taskID: Int64) {
        guard hostsByTaskID.removeValue(forKey: taskID) != nil else { return }
        autoRenameWatchers.removeValue(forKey: taskID)?.cancel()
        store.pruneOpenTerminals(removing: [taskID])
        conversationGate.releaseClaim(for: taskID)
        store.subagentPanes.closeAll(taskId: taskID)
        store.subagentSwap.closeAll(taskId: taskID)
        store.subagentStripBatches.reset(taskId: taskID)
        exitedTaskIDs.remove(taskID)
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
        }
        store.pruneOpenTerminals(removing: purged)
        conversationGate.release(exceptLiveTaskIDs: liveTaskIDs)
    }

    /// Fired by `PiSessionEndedView`'s Resume button: looks `taskID` up as a
    /// live task (it may have been deleted or archived while its dead
    /// surface sat on screen) and, if still live, relaunches it.
    private func requestRelaunch(taskID: Int64) {
        guard let task = store.task(withId: taskID), let project = store.project(forTask: task) else { return }
        Task { await relaunchHost(for: task, project: project) }
    }

    /// Tears down `task`'s dead (or still-running) `TerminalSurfaceHost` and
    /// relaunches it via `ensureHost` — the exact same
    /// `PiSessionService.launchCommand` path a normal reopen uses — so the
    /// relaunch resumes the same pi session/transcript rather than starting
    /// fresh. Shared by `PiSessionEndedView`'s Resume button and
    /// `TerminalCommands`' "Restart Pi Session" command, via
    /// `ProjectsStore.restartRequestedTaskID`.
    ///
    /// Releases the `conversationGate` claim the same way `closeHost` does:
    /// without it, `ensureHost` would find the id still claimed and
    /// silently do nothing.
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

    /// Pure so it's directly testable: marks `taskID` exited, leaving every
    /// other id untouched.
    static func exitedTaskIDs(afterExit taskID: Int64, current: Set<Int64>) -> Set<Int64> {
        current.union([taskID])
    }

    /// Pure so it's directly testable: clears `taskID`'s exited flag ahead
    /// of relaunching it, leaving every other id untouched.
    static func exitedTaskIDs(afterRelaunch taskID: Int64, current: Set<Int64>) -> Set<Int64> {
        current.subtracting([taskID])
    }

    /// Pure so it's directly testable: cached host ids no longer present
    /// among live (non-archived, non-deleted) tasks should be evicted.
    static func idsToPurge(cachedIDs: Set<Int64>, liveTaskIDs: Set<Int64>) -> Set<Int64> {
        cachedIDs.subtracting(liveTaskIDs)
    }

    /// A pane can close without the whole task terminal closing
    /// (`SubagentPaneStore.close`), which would otherwise leave
    /// `SubagentSwapStore` pointing at a surface that no longer exists —
    /// reconciles it back to "show the parent" for every task whose shown
    /// or highlighted child is no longer among its live panes. Pure in
    /// effect (only touches `swap`, not any `MainAreaView` state), so it's
    /// directly testable against real `SubagentSwapStore`/`SubagentPaneStore`
    /// instances.
    static func reconcileSwap(_ swap: SubagentSwapStore, panesByTask: [Int64: [SubagentPaneStore.ChildPane]]) {
        for (taskID, childID) in swap.shownChildIDByTask where !(panesByTask[taskID] ?? []).contains(where: { $0.id == childID }) {
            swap.handleClosed(childId: childID, taskId: taskID)
        }
        for (taskID, childID) in swap.highlightedChildIDByTask where !(panesByTask[taskID] ?? []).contains(where: { $0.id == childID }) {
            swap.handleClosed(childId: childID, taskId: taskID)
        }
    }

    /// The task id that should read as visible/focused for a given
    /// `mainSelection` — the one place both `syncVisibility()` and
    /// `syncFocus()` (and the `ForEach` in `body`) go to decide "is this the
    /// active task's host", so opacity, hit-testing, and keyboard focus can
    /// never independently disagree about it. Pure so it's directly testable.
    static func visibleTaskID(for selection: MainSelection) -> Int64? {
        if case .task(let task, _) = selection {
            return task.id
        }
        return nil
    }

    /// The directory a task's terminal should start in: its worktree, or the
    /// project's own path if that worktree is missing or has vanished out
    /// from under the app (see `ProjectsStore.vanishedWorktreeTaskIds`), or
    /// home if the project's own path is gone too — a task terminal should
    /// never fail to open just because its worktree disappeared, and this
    /// path also ends up written into a repaired transcript's header, where
    /// a nonexistent directory would make `pi --session <path>` refuse to
    /// resume it.
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
        // Both the worktree and the project directory are gone: fall back to
        // home rather than writing a nonexistent cwd into a repaired
        // transcript's header, which would make `pi --session <path>` exit 1
        // with "Stored session working directory does not exist".
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The directory the terminal drawer's own scratch shell should start
    /// in: a selected task's worktree, else the selected project's path,
    /// else the user's home directory. Shared with `TerminalDrawerView` so
    /// the drawer and the main area never disagree about "where is this
    /// selection, on disk".
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

/// Ensures at most one caller ever resolves (looks up or starts) a
/// `Conversation` for a given task id at a time, and that a task id already
/// resolved can't be resolved again.
///
/// `ensureHost` awaits several times — the active-conversation lookup, the
/// possible insert — before it has a host in `hostsByTaskID` to check
/// against. Without this, a rapid task-switch-and-back (A -> B -> A) that
/// re-triggers `.task(id:)` twice for A while the first call is still
/// in flight would let both calls see "no conversation yet", both insert a
/// row under a different pi session id, and whichever `TerminalSurfaceHost`
/// loses the assignment race leak its pty and `pi` process. `claim` makes
/// the second call bail out immediately instead.
///
/// A separate type (rather than inline `@State` on `MainAreaView`) so the
/// dedup behavior is testable against the real `ProjectsStore` reuse path,
/// without needing a `TerminalSurfaceHost` (which requires a live AppKit/
/// libghostty surface) to exercise it.
@MainActor
final class ConversationLaunchGate {
    private var claimedTaskIDs: Set<Int64> = []

    init() {}

    /// Resolves `task`'s conversation — reusing its active one or starting a
    /// fresh one — unless another call has already claimed this task id
    /// (in flight, or already resolved to a host). Returns `nil` when the
    /// claim fails, which the caller must treat as "do nothing further for
    /// this task right now", not as an error.
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

    /// Releases task ids no longer live (deleted or archived out of
    /// `tasksByProject`), mirroring `MainAreaView.purgeHosts` — the same
    /// task id reappearing later (e.g. unarchived) must be able to start a
    /// fresh conversation lookup rather than staying claimed forever.
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

    /// Drops `id`'s claim outright, live or not — used when a task's
    /// terminal is closed explicitly (`MainAreaView.closeHost`) rather than
    /// its task going away, so reopening it later can claim and resolve a
    /// conversation for it again instead of finding it stuck claimed
    /// forever.
    func releaseClaim(for id: Int64) {
        claimedTaskIDs.remove(id)
    }
}
