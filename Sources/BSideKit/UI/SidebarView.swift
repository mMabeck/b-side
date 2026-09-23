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

    @State private var pendingDeleteTask: (task: TaskRecord, project: Project)?

    var body: some View {
        VStack(spacing: 0) {
            if store.projects.isEmpty {
                emptyProjectsState
            } else {
                List {
                    if !activeTaskEntries.isEmpty {
                        Section {
                            ForEach(Array(activeTaskEntries.enumerated()), id: \.element.taskID) { index, entry in
                                activeTaskRow(entry.task, project: entry.project, shortcutIndex: index)
                            }
                        } header: {
                            Text("Active")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.palette.textSecondary)
                                .textCase(.uppercase)
                        }
                    }

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
            }

            // A persistent footer, not another `List` row: it must stay put
            // while the list above it scrolls, and be reachable even when
            // `store.projects` is empty (the empty state above already offers
            // its own "Add Project" button, but keeping this one too means the
            // affordance is always in the same place).
            Rectangle().fill(theme.palette.separator).frame(height: 1)
            addProjectFooter
        }
        .background(theme.palette.surfaceBackground)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    ProjectCreation.addProject(store: store)
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
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

    /// Open task terminals in the order they were opened, paired with the
    /// task and owning project each id resolves to — the same order
    /// `NavigationShortcuts.activeTaskID(atIndex:in:)` indexes into, so a
    /// row's position here always matches the ⌘-digit that selects it.
    /// Entries whose task has since been archived/deleted resolve to `nil`
    /// and are dropped rather than shown as a dead row; `MainAreaView`
    /// prunes `openTerminalTaskIDs` on the same event, so that's normally
    /// momentary at most.
    private var activeTaskEntries: [(taskID: Int64, task: TaskRecord, project: Project)] {
        store.openTerminalTaskIDs.compactMap { id in
            store.taskAndProject(forID: id).map { (taskID: id, task: $0.task, project: $0.project) }
        }
    }

    /// A row in the "Active" section: the task's ⌘-digit hint (only the
    /// first 9 entries have one — `NavigationShortcuts` can't address past
    /// index 8), its name, and its project's name, since "Active" spans
    /// every project rather than nesting under one. Selecting it behaves
    /// exactly like the matching row under its project below.
    private func activeTaskRow(_ task: TaskRecord, project: Project, shortcutIndex: Int) -> some View {
        let isSelected = store.selectedTaskID == task.id
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary
        let hint = shortcutIndex < NavigationShortcuts.digitCount ? "⌘\(shortcutIndex + 1)" : nil

        return Button {
            store.selectTask(task, project: project)
        } label: {
            HStack(spacing: 8) {
                Text(hint ?? "")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(secondary)
                    .frame(width: 22, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Text(project.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(selectionFill(isSelected: isSelected, in: theme.palette))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    /// A project row: name, branch (with a `*` if dirty), and path in
    /// progressively dimmer text, styled after cmux's project list (e.g.
    /// `dotfiles` / `main*` / `~/Claude/dotfiles`). Selection reads as a
    /// filled themed row using the palette's selection colours.
    private func projectRow(_ project: Project, taskCount: Int) -> some View {
        let info = gitInfo.info(forProject: project.id)
        let isSelected = store.selectedProjectID == project.id && store.selectedTaskID == nil
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary

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
                addTaskButton(for: project)
                Text("\(taskCount)")
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(selectionFill(isSelected: isSelected, in: theme.palette))
        }
        .padding(.top, 6)
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button("New Task…") {
                store.pendingTaskCreationProject = project
            }
            Button("Remove Project", role: .destructive) {
                Task { try? await store.removeProject(project) }
            }
        }
        .task(id: project.id) { gitInfo.refresh(project) }
    }

    /// A quiet, low-contrast "+" beside each project header for starting a
    /// task in that project without opening its context menu. Sized to a
    /// fixed small frame and drawn with `.plain` so it neither disturbs the
    /// header row's existing height/padding nor the task-count indicator
    /// beside it, and a nested `Button` inside `projectRow`'s own `Button`
    /// label works fine here because SwiftUI resolves the tap to whichever
    /// control's own hit area was actually touched.
    private func addTaskButton(for project: Project) -> some View {
        Button {
            store.pendingTaskCreationProject = project
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textDisabled)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Task in \(project.displayName)")
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
        let isMerged = syncStatus?.merged ?? false
        // The "merged" pill below already covers the merged case; the
        // caption text is reserved for ahead/behind counts so the two never
        // say the same thing twice.
        let syncText = isMerged ? nil : syncStatus.flatMap(BranchSyncSummary.text(for:))
        let isSelected = store.selectedTaskID == task.id
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary
        let tertiary = theme.palette.textDisabled

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

                if isMerged {
                    mergedBadge(isSelected: isSelected)
                }

                if let syncText {
                    Text(syncText)
                        .font(.caption2)
                        .foregroundStyle(tertiary)
                }
            }
            .padding(.leading, Self.taskLeadingIndent)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
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

    /// A small "Merged" pill for a task whose branch is already merged —
    /// the status dot alone (a green dot, same colour family as "running"'s
    /// blue) and the tiny caption2 "merged" text it used to share the
    /// trailing edge with were both too quiet to read at a glance. Uses
    /// `statusSuccess` (the same colour `TaskStatus.finished` already maps
    /// to) tinted into its own background rather than the selection fill,
    /// so it stays legible in both the selected and unselected row states.
    private func mergedBadge(isSelected: Bool) -> some View {
        let tint = theme.palette.statusSuccess
        return HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text("Merged")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(isSelected ? 0.22 : 0.15))
        )
    }

    /// The selected row's fill, painted directly on the row's own content
    /// rather than via `.listRowBackground`/`List`'s built-in selection
    /// styling — under `.listStyle(.sidebar)` that styling did not reliably
    /// paint behind these custom `Button` rows, which is how a
    /// `selectionForeground` meant to sit on `selectionBackground` ended up on
    /// the bare (and, for some themes, near-black) row background instead.
    /// Painting the fill ourselves keeps it independent of `List`'s internal
    /// rendering. The fill is a faint wash of the theme's own text colour
    /// (white-ish on dark themes, dark on light ones) rather than the theme's
    /// often saturated `selectionBackground`, so selected rows keep their
    /// normal text colours.
    private func selectionFill(isSelected: Bool, in palette: BSidePalette) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? palette.textPrimary.opacity(0.12) : Color.clear)
    }

    /// The persistent "Add Project" row pinned below the list — not a `List`
    /// row itself, so it never scrolls out of view. Same `.plain`,
    /// palette-only styling as the rest of the sidebar; routes through
    /// `ProjectCreation` like every other add-project entry point.
    private var addProjectFooter: some View {
        Button {
            ProjectCreation.addProject(store: store)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add Project")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shown instead of the (otherwise empty) list when there are no
    /// projects yet, so a brand-new install invites the first "Add Project"
    /// rather than presenting a blank column.
    private var emptyProjectsState: some View {
        VStack(spacing: 8) {
            Text("No projects yet")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
            Button {
                ProjectCreation.addProject(store: store)
            } label: {
                Label("Add Project", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
