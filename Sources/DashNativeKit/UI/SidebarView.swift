import AppKit
import SwiftUI

/// Left sidebar: projects with tasks nested beneath, arranged like Dash's
/// Electron task tree but styled after cmux's project list.
///
/// Uses a themed SwiftUI `List`, not `NSOutlineView`. The doc's stated reason
/// for preferring `NSOutlineView` (native-rewrite.md §8) is large,
/// frequently-updating, per-row-status lists with drag reordering; this list
/// is neither large nor drag-reorderable yet, and `Section(isExpanded:)`
/// gives collapsible project sections with a native disclosure chevron and
/// free keyboard navigation. The blocker that actually mattered — the
/// sidebar column rendering translucent, macOS-controlled "Liquid Glass"
/// chrome instead of this app's own opaque themed colour — turned out to be
/// fixable at the window level (see `ThemedWindow.neutralizeVibrancy`)
/// regardless of which list technology sits inside it. Revisit `NSOutlineView`
/// if/when this list needs drag-to-reorder or grows large enough that
/// `List`'s diffing becomes a real cost.
struct SidebarView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared
    @State private var gitInfo = SidebarGitInfoCache()
    @AppStorage("sidebarCollapsedProjectIDs") private var collapseState = SidebarCollapseState()

    @State private var taskCreationProject: Project?
    @State private var pendingDeleteTask: (task: TaskRecord, project: Project)?

    var body: some View {
        List {
            ForEach(store.projects) { project in
                let tasks = project.id.flatMap { store.tasksByProject[$0] } ?? []
                let isExpandedBinding = Binding<Bool>(
                    get: { collapseState.isExpanded(project.id) },
                    set: { expanded in
                        guard let id = project.id else { return }
                        collapseState.setExpanded(expanded, for: id)
                    }
                )
                Section(isExpanded: isExpandedBinding) {
                    if tasks.isEmpty {
                        Text("No tasks")
                            .foregroundStyle(theme.palette.textSecondary)
                            .listRowBackground(theme.palette.surfaceBackground)
                    } else {
                        ForEach(tasks) { task in
                            taskRow(task, project: project)
                        }
                    }
                } header: {
                    projectRow(project, taskCount: tasks.count)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.palette.surfaceBackground)
        .toolbar {
            ToolbarItem {
                Button(action: addProject) {
                    Label("Add Project", systemImage: "plus")
                }
            }
        }
        .sheet(item: $taskCreationProject) { project in
            TaskCreationView(project: project, store: store) {
                taskCreationProject = nil
            }
        }
        .alert(
            "Delete Task?",
            isPresented: Binding(
                get: { pendingDeleteTask != nil },
                set: { if !$0 { pendingDeleteTask = nil } }
            ),
            presenting: pendingDeleteTask
        ) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await store.deleteTask(
                        pending.task,
                        project: pending.project,
                        deleteLocalBranch: pending.task.branchCreatedByApp,
                        deleteRemoteBranch: false
                    )
                }
            }
        } message: { pending in
            Text("This removes the worktree at \(pending.task.worktreePath) and, since it was created by the app, its branch \(pending.task.branchName).")
        }
    }

    /// A project row: name, branch (with a `*` if dirty), and path in
    /// progressively dimmer text, styled after cmux's project list (e.g.
    /// `dotfiles` / `main*` / `~/Claude/dotfiles`). Selection reads as a
    /// filled themed row using the palette's selection colours.
    private func projectRow(_ project: Project, taskCount: Int) -> some View {
        let info = gitInfo.info(forProject: project.id)
        let isSelected = store.selectedProjectID == project.id
        let primary = isSelected ? theme.palette.selectionForeground : theme.palette.textPrimary
        let secondary = isSelected ? theme.palette.selectionForeground.opacity(0.85) : theme.palette.textSecondary
        let tertiary = isSelected ? theme.palette.selectionForeground.opacity(0.7) : theme.palette.textDisabled

        return Button {
            store.selectedProjectID = project.id
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primary)
                    if let branch = info?.branch {
                        Text(branch + (info?.isDirty == true ? "*" : ""))
                            .font(.system(size: 11))
                            .foregroundStyle(secondary)
                    }
                    Text(project.path)
                        .font(.system(size: 11))
                        .foregroundStyle(tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(taskCount)")
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? theme.palette.selectionBackground : Color.clear)
        .contextMenu {
            Button("New Task…") {
                taskCreationProject = project
            }
            Button("Remove Project", role: .destructive) {
                Task { try? await store.removeProject(project) }
            }
        }
        .task(id: project.id) { gitInfo.refresh(project) }
    }

    /// A task row nested beneath its project. The leading status-dot column
    /// is reserved at a fixed width even when no dot is shown, so every
    /// title starts at the same x (`TaskRowLayout.statusDotColumnWidth`).
    /// The trailing edge carries the subagent child count/blocked indicator
    /// and the branch sync summary, in that order, quiet and compact.
    private func taskRow(_ task: TaskRecord, project: Project) -> some View {
        let summary = task.id.map(store.subagentFeed.summary(forTask:)) ?? TaskChildSummary(activeCount: 0, totalCount: 0, isBlocked: false)
        let isVanished = store.vanishedWorktreeTaskIds.contains(task.id ?? -1)
        let syncStatus = task.id.flatMap { store.syncStatusByTask[$0] }
        let status = TaskStatus.derive(
            merged: syncStatus?.merged ?? false,
            isBlocked: summary.isBlocked,
            isVanished: isVanished,
            activeChildCount: summary.activeCount
        )
        let syncText = syncStatus.flatMap(BranchSyncSummary.text(for:))
        let isSelected = store.selectedTaskID == task.id
        let primary = isSelected ? theme.palette.selectionForeground : theme.palette.textPrimary
        let secondary = isSelected ? theme.palette.selectionForeground.opacity(0.85) : theme.palette.textSecondary
        let tertiary = isSelected ? theme.palette.selectionForeground.opacity(0.7) : theme.palette.textDisabled

        return Button {
            store.selectedTaskID = task.id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color(in: theme.palette))
                    .frame(width: TaskRowLayout.statusDotDiameter, height: TaskRowLayout.statusDotDiameter)
                    .frame(width: TaskRowLayout.dotColumnWidth(for: status), alignment: .center)

                Text(task.name)
                    .foregroundStyle(primary)

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
                        .foregroundStyle(secondary)
                }

                if let syncText {
                    Text(syncText)
                        .font(.caption2)
                        .foregroundStyle(tertiary)
                }
            }
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? theme.palette.selectionBackground : Color.clear)
        .contextMenu {
            Button("Archive") {
                Task { try? await store.archiveTask(task, project: project, removeWorktree: true) }
            }
            Button("Delete…", role: .destructive) {
                pendingDeleteTask = (task, project)
            }
        }
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await !GitCLI.isGitRepository(at: url) {
                guard offerToInitRepository(at: url) else { return }
            }
            try? await store.addProject(at: url)
        }
    }

    /// Shows a confirmation alert asking whether to `git init` a non-repo directory.
    /// Returns whether the user agreed.
    private func offerToInitRepository(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Not a Git Repository"
        alert.informativeText = "\(url.lastPathComponent) isn't a git repository yet. Run \"git init\" in it?"
        alert.addButton(withTitle: "Initialize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
