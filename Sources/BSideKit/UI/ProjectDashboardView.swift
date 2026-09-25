import SwiftUI

/// The main area's content when a project, but no task, is selected — a
/// project is a container of tasks, never a terminal itself, so this is a
/// lightweight read-only overview instead of a shell surface: header, "New
/// Task" affordance, and the project's own tasks as compact rows. Clicking a
/// task row hands selection to `ProjectsStore.selectTask(_:project:)`, which
/// is what switches the main area over to that task's terminal (see
/// `MainAreaView`).
struct ProjectDashboardView: View {
    var store: ProjectsStore
    var project: Project

    @ObservedObject var theme: GhosttyResolvedTheme = .shared
    @State private var gitInfo = SidebarGitInfoCache()

    private var tasks: [TaskRecord] {
        project.id.flatMap { store.tasksByProject[$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(theme.palette.separator)
                .frame(height: 1)

            if tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tasks) { task in
                            taskCard(task)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.windowBackground)
        .task(id: project.id) { gitInfo.refresh(project) }
    }

    /// Same branch/dirty/path facts as the sidebar's project row, from the
    /// same cache — the dashboard is a second view onto that git state, not
    /// a second source of truth for it.
    private var header: some View {
        let info = gitInfo.info(forProject: project.id)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                if let branch = info?.branch {
                    Text(branch + (info?.isDirty == true ? "*" : ""))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Text(project.path)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textDisabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            newTaskButton
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No tasks yet")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
            newTaskButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A filled, themed "New Task" action, styled like `SidebarView`'s rows
    /// (`.plain` with an explicit palette fill) rather than system
    /// `.borderedProminent`/`.bordered` chrome, so it restyles with the
    /// user's Ghostty theme instead of showing macOS's own accent colour.
    private var newTaskButton: some View {
        Button {
            store.pendingTaskCreationProject = project
        } label: {
            Label("New Task", systemImage: "plus")
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

    /// A compact task summary card: name, status dot, branch sync summary,
    /// and subagent child count/blocked indicator — the same signals and
    /// derivations the sidebar's task row uses (`TaskStatus.derive`,
    /// `BranchSyncSummary.text(for:)`, `SubagentFeedStore.summary(forTask:)`),
    /// so the dashboard never disagrees with the sidebar about a task's state.
    private func taskCard(_ task: TaskRecord) -> some View {
        let summary = task.id.map(store.subagentFeed.summary(forTask:)) ?? TaskChildSummary(activeCount: 0, totalCount: 0, isBlocked: false)
        let isVanished = store.vanishedWorktreeTaskIds.contains(task.id ?? -1)
        let syncStatus = task.id.flatMap { store.syncStatusByTask[$0] }
        let status = TaskStatus.derive(
            isBlocked: summary.isBlocked,
            isVanished: isVanished,
            activeChildCount: summary.activeCount,
            isOpen: task.id.map(store.openTerminalTaskIDs.contains) ?? false,
            isUnread: task.id.map(store.unreadTaskIDs.contains) ?? false,
            needsAttention: task.id.map(store.taskIDsNeedingAttention.contains) ?? false,
            busy: task.id.map(store.busyTaskIDs.contains) ?? false
        )
        let syncText = syncStatus.flatMap(BranchSyncSummary.text(for:))

        return Button {
            store.selectTask(task, project: project)
        } label: {
            HStack(spacing: 8) {
                StatusDot(status: status, palette: theme.palette)

                Text(task.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)

                if isVanished {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.palette.statusNeedsAttention)
                }

                Spacer()

                if summary.hasChildren {
                    if summary.isBlocked {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .foregroundStyle(theme.palette.statusNeedsAttention)
                    }
                    Text("\(summary.totalCount)")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                }

                if let syncText {
                    Text(syncText)
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textDisabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.palette.elevatedSurfaceBackground)
            )
        }
        .buttonStyle(.plain)
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }
}
