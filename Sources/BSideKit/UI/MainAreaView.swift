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

    private var liveTaskIDs: Set<Int64> {
        Set(store.tasksByProject.values.flatMap { $0.compactMap(\.id) })
    }

    var body: some View {
        ZStack {
            // Every cached terminal stays mounted here regardless of the
            // current selection; only its opacity/hit-testing tracks whether
            // its task is the active one.
            ForEach(Array(hostsByTaskID.keys), id: \.self) { taskID in
                if let host = hostsByTaskID[taskID] {
                    TerminalHostView(host: host)
                        .opacity(taskID == store.selectedTaskID ? 1 : 0)
                        .allowsHitTesting(taskID == store.selectedTaskID)
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
    /// their grid, scrollback, or running shell.
    private func syncVisibility() {
        for (id, host) in hostsByTaskID {
            host.isVisible = (id == store.selectedTaskID)
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
