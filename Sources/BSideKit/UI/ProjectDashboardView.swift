import SwiftUI

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
        .task(id: project.id) { gitInfo.refresh(project) }
    }

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
        ContentUnavailableView {
            Label("No Tasks Yet", systemImage: "checklist")
        } actions: {
            newTaskButton
        }
    }

    private var newTaskButton: some View {
        Button {
            store.pendingTaskCreationProject = project
        } label: {
            Label("New Task", systemImage: "plus")
        }
        .buttonStyle(.glassProminent)
        .tint(theme.palette.accent)
    }

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
        // `isEffectivelyMerged`, so a landed branch with new uncommitted edits doesn't read "merged"; a trailing ● marks them.
        let syncText: String? = syncStatus.flatMap { sync -> String? in
            let effectivelyMerged = BranchSyncSummary.isEffectivelyMerged(sync)
            if effectivelyMerged && status == .inactive { return nil }
            let base = BranchSyncSummary.text(ahead: sync.ahead, behind: sync.behind, merged: effectivelyMerged)
            guard !effectivelyMerged, sync.hasUncommittedChanges else { return base }
            let parts: [String?] = [base, "●"]
            return parts.compactMap { $0 }.joined(separator: " ")
        }

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
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .controlSize(.large)
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }
}
