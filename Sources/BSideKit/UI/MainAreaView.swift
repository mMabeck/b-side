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
struct MainAreaView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var hostsByTaskID: [Int64: TerminalSurfaceHost] = [:]

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
                    TerminalHostView(host: host, focusedTaskID: $focusedTaskID, taskID: taskID)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
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
        .task(id: store.selectedTaskID) {
            if case .task(let task, let project) = store.mainSelection {
                ensureHost(for: task, project: project)
            }
            syncVisibility()
            syncFocus()
        }
        .onChange(of: liveTaskIDs) { _, ids in
            purgeHosts(keeping: ids)
        }
    }

    private var emptyStateView: some View {
        Text("Select a project or task")
            .font(.system(size: 13))
            .foregroundStyle(theme.palette.textSecondary)
    }

    private func ensureHost(for task: TaskRecord, project: Project) {
        guard let id = task.id, hostsByTaskID[id] == nil else { return }
        hostsByTaskID[id] = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(forTask: task, project: project))
    }

    /// Marks the active task's host visible and every other cached host not
    /// visible, so hidden surfaces stop drawing frames nobody sees (per
    /// `TerminalSurfaceHost.isVisible`'s own doc comment) without losing
    /// their grid, scrollback, or running shell. Derived from `mainSelection`,
    /// not the raw `selectedTaskID`, so this never disagrees with which
    /// branch of the `switch` above is actually on screen — see
    /// `visibleTaskID(for:)`.
    private func syncVisibility() {
        let visibleID = MainAreaView.visibleTaskID(for: store.mainSelection)
        for (id, host) in hostsByTaskID {
            host.isVisible = (id == visibleID)
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
        if let visibleID, let host = hostsByTaskID[visibleID] {
            host.state.requestFocus()
        }
    }

    private func purgeHosts(keeping liveTaskIDs: Set<Int64>) {
        for id in MainAreaView.idsToPurge(cachedIDs: Set(hostsByTaskID.keys), liveTaskIDs: liveTaskIDs) {
            hostsByTaskID.removeValue(forKey: id)
        }
    }

    /// Pure so it's directly testable: cached host ids no longer present
    /// among live (non-archived, non-deleted) tasks should be evicted.
    static func idsToPurge(cachedIDs: Set<Int64>, liveTaskIDs: Set<Int64>) -> Set<Int64> {
        cachedIDs.subtracting(liveTaskIDs)
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
    /// from under the app (see `ProjectsStore.vanishedWorktreeTaskIds`) — a
    /// task terminal should never fail to open just because its worktree
    /// disappeared.
    static func resolvedDirectory(forTask task: TaskRecord, project: Project) -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: task.worktreePath, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return URL(fileURLWithPath: task.worktreePath)
        }
        return URL(fileURLWithPath: project.path)
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
