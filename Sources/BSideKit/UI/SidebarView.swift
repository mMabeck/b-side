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
            ToolbarItem(placement: .navigation) {
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
        let isSelected = store.selectedProjectID == project.id && store.selectedTaskID == nil
        let primary = isSelected ? theme.palette.selectionForeground : theme.palette.textPrimary
        let secondary = isSelected ? theme.palette.selectionForeground.opacity(0.85) : theme.palette.textSecondary

        return Button {
            store.selectProject(project)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(primary)
                    Text(projectSecondaryLine(branch: info?.branch, isDirty: info?.isDirty ?? false, path: project.path))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(taskCount)")
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(selectionFill(isSelected: isSelected, in: theme.palette))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
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

    /// One terse secondary line combining branch and path (`main* — ~/Claude/dotfiles`)
    /// instead of the two lines a task-peer row would need, keeping the project
    /// header compact relative to the tasks nested under it.
    private func projectSecondaryLine(branch: String?, isDirty: Bool, path: String) -> String {
        guard let branch else { return path }
        return "\(branch)\(isDirty ? "*" : "") — \(path)"
    }

    /// The leading inset a task row sits at, aligned with where the project
    /// title's text begins (`projectRow`'s own horizontal padding) so the
    /// nesting reads visually, not just via `List`'s section indentation.
    private static let taskLeadingIndent: CGFloat = 16

    /// Where the vertical indent-guide line sits within that inset — drawn
    /// manually per row (not as one tall shape spanning the section) because
    /// `List` gives each row its own `NSHostingView`; stacking these
    /// borderless per-row segments with no vertical gap between them is what
    /// makes the line read as continuous down the whole task group.
    private static let taskIndentGuideX: CGFloat = 6

    /// A task row nested beneath its project. The leading status-dot column
    /// is reserved at a fixed width even when no dot is shown, so every
    /// title starts at the same x (`TaskRowLayout.statusDotColumnWidth`).
    /// The trailing edge carries the subagent child count/blocked indicator
    /// and the branch sync summary, in that order, quiet and compact. Smaller
    /// and lighter than the project title above it, and indented beneath it
    /// with a low-opacity guide line, so tasks read as the project's children
    /// rather than its peers — a project is a container, never a terminal.
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
            store.selectTask(task, project: project)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color(in: theme.palette))
                    .frame(width: TaskRowLayout.statusDotDiameter, height: TaskRowLayout.statusDotDiameter)
                    .frame(width: TaskRowLayout.dotColumnWidth(for: status), alignment: .center)

                Text(task.name)
                    .font(.system(size: 12, weight: .regular))
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
            .padding(.leading, Self.taskLeadingIndent)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(selectionFill(isSelected: isSelected, in: theme.palette))
            .overlay(alignment: .leading) {
                // The indent guide: a thin low-opacity line at a fixed x within
                // the leading inset, independent of whether this particular
                // row is selected, so the guide reads as one continuous line
                // rather than flickering per-row with selection state.
                Rectangle()
                    .fill(theme.palette.separator.opacity(0.5))
                    .frame(width: 1)
                    .padding(.leading, Self.taskIndentGuideX)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
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

    /// The selected row's fill, painted directly on the row's own content
    /// rather than via `.listRowBackground`/`List`'s built-in selection
    /// styling — under `.listStyle(.sidebar)` that styling did not reliably
    /// paint behind these custom `Button` rows, which is how a
    /// `selectionForeground` meant to sit on `selectionBackground` ended up on
    /// the bare (and, for some themes, near-black) row background instead.
    /// Painting the fill ourselves keeps the pairing intact regardless of
    /// `List`'s internal rendering.
    private func selectionFill(isSelected: Bool, in palette: BSidePalette) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? palette.selectionBackground : Color.clear)
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
