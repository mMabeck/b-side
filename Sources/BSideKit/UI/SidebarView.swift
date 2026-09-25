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
                                    .listRowInsets(Self.rowInsets)
                            }
                        } header: {
                            Text("Active")
                                .font(.system(size: 12, weight: .semibold))
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
                                // Aligned with where task titles start, so the
                                // placeholder reads as the project's (empty) child.
                                Text("No tasks")
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.palette.textSecondary)
                                    .padding(.leading, Self.taskLeadingIndent + TaskRowLayout.statusDotColumnWidth + 6)
                                    .padding(.vertical, 6)
                                    .listRowInsets(Self.rowInsets)
                                    .listRowBackground(theme.palette.surfaceBackground)
                            } else {
                                ForEach(tasks) { task in
                                    taskRow(task, project: project)
                                        .listRowInsets(Self.rowInsets)
                                }
                            }
                        } header: {
                            projectRow(project, taskCount: tasks.count)
                                .listRowInsets(Self.rowInsets)
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
        .background(SidebarFocusGuard(store: store))
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

    /// A task's derived status and the trailing-edge bits `taskRow` and
    /// `activeTaskRow` both show alongside it — the single place that combines
    /// `TaskStatus.derive`'s inputs (subagent summary, vanished-worktree,
    /// branch sync, needs-attention) so the two rows can never derive a
    /// task's status differently from one another.
    private struct TaskStatusInfo {
        let status: TaskStatus
        let summary: TaskChildSummary
        let isVanished: Bool
        let isMerged: Bool
        /// `nil` when `isMerged` — the merged pill already covers that case,
        /// and this is reserved for ahead/behind counts so the two never say
        /// the same thing twice.
        let syncText: String?
    }

    private func taskStatusInfo(for task: TaskRecord) -> TaskStatusInfo {
        let summary = task.id.map(store.subagentFeed.summary(forTask:)) ?? TaskChildSummary(activeCount: 0, totalCount: 0, isBlocked: false)
        let isVanished = store.vanishedWorktreeTaskIds.contains(task.id ?? -1)
        let syncStatus = task.id.flatMap { store.syncStatusByTask[$0] }
        let status = TaskStatus.derive(
            merged: syncStatus?.merged ?? false,
            isBlocked: summary.isBlocked,
            isVanished: isVanished,
            activeChildCount: summary.activeCount,
            needsAttention: task.id.map(store.taskIDsNeedingAttention.contains) ?? false
        )
        let isMerged = syncStatus?.merged ?? false
        let syncText = isMerged ? nil : syncStatus.flatMap(BranchSyncSummary.text(for:))
        return TaskStatusInfo(status: status, summary: summary, isVanished: isVanished, isMerged: isMerged, syncText: syncText)
    }

    /// A row in the "Active" section: the same status dot `taskRow` shows,
    /// its name, and its project's name, since "Active" spans every project
    /// rather than nesting under one. Selecting it behaves exactly like the
    /// matching row under its project below. The ⌘-digit shortcut (only the
    /// first 9 entries have one — `NavigationShortcuts` can't address past
    /// index 8) is still discoverable, just not via a visible label: it stays
    /// live in the "Go" menu (`NavigationCommands`) and surfaces here only as
    /// a `.help` tooltip, so this row's leading column can show status
    /// instead of a shortcut hint.
    private func activeTaskRow(_ task: TaskRecord, project: Project, shortcutIndex: Int) -> some View {
        let isSelected = store.selectedTaskID == task.id
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary
        let tertiary = theme.palette.textDisabled
        let hint = shortcutIndex < NavigationShortcuts.digitCount ? "⌘\(shortcutIndex + 1)" : nil
        let info = taskStatusInfo(for: task)

        return Button {
            store.selectTask(task, project: project)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(info.status.color(in: theme.palette))
                    .frame(width: TaskRowLayout.statusDotDiameter, height: TaskRowLayout.statusDotDiameter)
                    .frame(width: TaskRowLayout.statusDotColumnWidth, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Text(Self.folderName(of: project))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }

                Spacer()

                if info.isMerged {
                    mergedBadge(isSelected: isSelected)
                } else if let syncText = info.syncText {
                    Text(syncText)
                        .font(.caption2)
                        .foregroundStyle(tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(selectionFill(isSelected: isSelected, in: theme.palette))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .help(hint ?? "")
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }

    /// A project row: just the project's folder name, bold, with the
    /// add-task button and task count trailing. Branch and path live on the
    /// project dashboard instead, keeping the sidebar scannable.
    private func projectRow(_ project: Project, taskCount: Int) -> some View {
        let isSelected = store.selectedProjectID == project.id && store.selectedTaskID == nil
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary

        return Button {
            store.selectProject(project)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.folderName(of: project))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                addTaskButton(for: project)
                Text("\(taskCount)")
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Task in \(project.displayName)")
    }

    /// The last path component of the project's directory (`dotfiles` for
    /// `~/Claude/dotfiles`) — what the sidebar shows instead of the stored
    /// display name, falling back to it only if the path has no usable name.
    static func folderName(of project: Project) -> String {
        let name = URL(fileURLWithPath: project.path).lastPathComponent
        return name.isEmpty || name == "/" ? project.displayName : name
    }

    /// Tight `List` row insets so the selection fill spans nearly the full
    /// sidebar width instead of sitting inside `.sidebar`'s default margins.
    private static let rowInsets = EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)

    /// How far the selection fill extends past each side of its row.
    private static let selectionBleed: CGFloat = 17

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
        let info = taskStatusInfo(for: task)
        let summary = info.summary
        let isVanished = info.isVanished
        let status = info.status
        let isMerged = info.isMerged
        let syncText = info.syncText
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
                    .font(.system(size: 13, weight: .regular))
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
                // the leading inset, hidden on the selected row, where it
                // would otherwise cut a dark line through the selection fill.
                Rectangle()
                    .fill(theme.palette.separator.opacity(0.5))
                    .frame(width: 1)
                    .padding(.leading, Self.taskIndentGuideX)
                    .opacity(isSelected ? 0 : 1)
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
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? palette.textPrimary.opacity(0.32) : Color.clear)
            // `.sidebar` keeps its own ~20pt horizontal margins even with
            // tight `listRowInsets`; bleeding the fill past the row lets it
            // span nearly the whole sidebar width.
            .padding(.horizontal, -Self.selectionBleed)
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
