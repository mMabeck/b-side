import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Just the id; `SidebarView` resolves source/destination indexes from `store.projects` itself.
private struct ProjectDragPayload: Codable, Transferable {
    let projectID: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bSideProjectID)
    }
}

private extension UTType {
    static var bSideProjectID: UTType { UTType(exportedAs: "dev.mabeck.bside.project-id") }
}

/// Left sidebar: projects with tasks nested beneath.
///
/// Uses a themed SwiftUI `List`, not `NSOutlineView`, over the system's
/// Liquid Glass sidebar chrome. Revisit if this grows large.
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
                List(selection: selectionBinding) {
                    if !activeTaskEntries.isEmpty {
                        Section("Active") {
                            ForEach(Array(activeTaskEntries.enumerated()), id: \.element.taskID) { index, entry in
                                activeTaskRow(entry.task, project: entry.project, shortcutIndex: index)
                                    .tag(SidebarRowID.activeTask(entry.taskID))
                            }
                        }
                    }

                    Section("Projects") {
                        ForEach(store.projects) { project in
                            let tasks = project.id.flatMap { store.tasksByProject[$0] } ?? []
                            let isExpandedBinding = Binding<Bool>(
                                get: { collapseState.isExpanded(project.id) },
                                set: { expanded in
                                    guard let id = project.id else { return }
                                    collapseState.setExpanded(expanded, for: id)
                                }
                            )
                            DisclosureGroup(isExpanded: isExpandedBinding) {
                                if tasks.isEmpty {
                                    Text("No tasks")
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.palette.textSecondary)
                                        .padding(.leading, TaskRowLayout.statusDotColumnWidth + 6)
                                        .padding(.vertical, 6)
                                } else {
                                    ForEach(tasks) { task in
                                        taskRow(task, project: project)
                                            .tag(SidebarRowID.task(task.id ?? -1))
                                    }
                                }
                            } label: {
                                projectRow(project, taskCount: tasks.count)
                            }
                            .tag(SidebarRowID.project(project.id ?? -1))
                            .draggable(ProjectDragPayload(projectID: project.id ?? -1))
                            .dropDestination(for: ProjectDragPayload.self) { items, _ in
                                guard let dragged = items.first else { return false }
                                return reorderProject(draggedID: dragged.projectID, ontoID: project.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            addProjectFooter
        }
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

    // A task shows in both Active and its project; distinct tags keep the two rows
    // from sharing a selection identity, which left the native highlight stuck.
    private enum SidebarRowID: Hashable {
        case project(Int64)
        case task(Int64)
        case activeTask(Int64)
    }

    @State private var lastSelectedRow: SidebarRowID?

    /// Round-trips `store.selectedProjectID`/`selectedTaskID` through a single tagged
    /// selection so `List` drives the same selection state the rest of the app reads.
    private var selectionBinding: Binding<SidebarRowID?> {
        Binding(
            get: {
                if let taskID = store.selectedTaskID {
                    if lastSelectedRow == .task(taskID) || lastSelectedRow == .activeTask(taskID) {
                        return lastSelectedRow
                    }
                    return store.openTerminalTaskIDs.contains(taskID) ? .activeTask(taskID) : .task(taskID)
                }
                if let projectID = store.selectedProjectID { return .project(projectID) }
                return nil
            },
            set: { newValue in
                if newValue != nil { lastSelectedRow = newValue }
                switch newValue {
                case .task(let id), .activeTask(let id):
                    if let match = store.taskAndProject(forID: id) {
                        store.selectTask(match.task, project: match.project)
                    }
                case .project(let id):
                    if let project = store.projects.first(where: { $0.id == id }) {
                        store.selectProject(project)
                    }
                case nil:
                    break
                }
            }
        )
    }

    /// Same order `NavigationShortcuts.activeTaskID(atIndex:in:)` indexes
    /// into, so a row's position always matches its ⌘-digit. An archived/deleted
    /// task's entry resolves to `nil` and is dropped, normally momentary at most.
    private var activeTaskEntries: [(taskID: Int64, task: TaskRecord, project: Project)] {
        store.openTerminalTaskIDs.compactMap { id in
            store.taskAndProject(forID: id).map { (taskID: id, task: $0.task, project: $0.project) }
        }
    }

    /// The single place combining `TaskStatus.derive`'s inputs so `taskRow` and `activeTaskRow` never disagree.
    private struct TaskStatusInfo {
        let status: TaskStatus
        let summary: TaskChildSummary
        let isVanished: Bool
        /// Merged into base ref *and* no uncommitted changes on top; hidden on a closed task, where it's just noise.
        let isMerged: Bool
        /// Mutually exclusive with `isMerged`.
        let hasPendingWork: Bool
        let pendingAhead: Int
        let hasUncommittedChanges: Bool
        /// `nil` when `isMerged`, so the two never say the same thing twice.
        let syncText: String?
    }

    private func taskStatusInfo(for task: TaskRecord) -> TaskStatusInfo {
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
        let effectivelyMerged = syncStatus.map(BranchSyncSummary.isEffectivelyMerged) ?? false
        let isMerged = effectivelyMerged && status != .inactive
        let hasPendingWork = syncStatus.map(BranchSyncSummary.hasPendingWork(for:)) ?? false
        let syncText = effectivelyMerged ? nil : syncStatus.flatMap(BranchSyncSummary.behindCaption(for:))
        return TaskStatusInfo(
            status: status,
            summary: summary,
            isVanished: isVanished,
            isMerged: isMerged,
            hasPendingWork: hasPendingWork,
            pendingAhead: syncStatus?.ahead ?? 0,
            hasUncommittedChanges: syncStatus?.hasUncommittedChanges ?? false,
            syncText: syncText
        )
    }

    /// The ⌘-digit shortcut (only the first 9 entries have one) surfaces only as a `.help` tooltip, not a visible label.
    private func activeTaskRow(_ task: TaskRecord, project: Project, shortcutIndex: Int) -> some View {
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary
        let tertiary = theme.palette.textDisabled
        let hint = shortcutIndex < NavigationShortcuts.digitCount ? "⌘\(shortcutIndex + 1)" : nil
        let info = taskStatusInfo(for: task)

        return HStack(spacing: 8) {
            StatusDot(status: info.status, palette: theme.palette)
                .frame(width: TaskRowLayout.statusDotColumnWidth, alignment: .leading)

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
                mergedBadge()
            } else if info.hasPendingWork {
                pendingPill(ahead: info.pendingAhead, hasUncommittedChanges: info.hasUncommittedChanges)
            }

            if let syncText = info.syncText {
                Text(syncText)
                    .font(.caption2)
                    .foregroundStyle(tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(hint ?? "")
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }

    /// Accepted without moving when ids match; rejected if either id can't be resolved (e.g. a stale payload).
    private func reorderProject(draggedID: Int64, ontoID: Int64?) -> Bool {
        guard let ontoID, draggedID != ontoID else { return true }
        guard let fromIndex = store.projects.firstIndex(where: { $0.id == draggedID }),
              let toIndex = store.projects.firstIndex(where: { $0.id == ontoID }) else { return false }
        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        Task { try? await store.moveProjects(fromOffsets: IndexSet(integer: fromIndex), toOffset: destination) }
        return true
    }

    /// Branch and path live on the project dashboard instead, keeping the sidebar scannable.
    private func projectRow(_ project: Project, taskCount: Int) -> some View {
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary

        return HStack(alignment: .firstTextBaseline) {
            Text(Self.folderName(of: project))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)
            Spacer()
            addTaskButton(for: project)
            Text("\(taskCount)")
                .font(.caption)
                .foregroundStyle(secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Task…") {
                store.pendingTaskCreationProject = project
            }
            Button("Move Up") {
                Task { try? await store.moveProject(project, direction: .up) }
            }
            .disabled(!canMoveProject(project, direction: .up))
            Button("Move Down") {
                Task { try? await store.moveProject(project, direction: .down) }
            }
            .disabled(!canMoveProject(project, direction: .down))
            Button("Remove Project", role: .destructive) {
                Task { try? await store.removeProject(project) }
            }
        }
        .accessibilityActions {
            Button("Move Up") {
                Task { try? await store.moveProject(project, direction: .up) }
            }
            .disabled(!canMoveProject(project, direction: .up))
            Button("Move Down") {
                Task { try? await store.moveProject(project, direction: .down) }
            }
            .disabled(!canMoveProject(project, direction: .down))
        }
    }

    /// Disables Move Up/Down at the ends of the list, matching `.onMove`'s own behaviour.
    private func canMoveProject(_ project: Project, direction: ProjectMoveDirection) -> Bool {
        guard let index = store.projects.firstIndex(where: { $0.id == project.id }) else { return false }
        return direction == .up ? index > 0 : index < store.projects.count - 1
    }

    /// Nested inside `projectRow`'s own `Button` label; SwiftUI resolves the tap to whichever hit area was touched.
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
        .buttonStyle(.borderless)
        .help("New Task in \(project.displayName)")
    }

    /// Shown instead of the stored display name, falling back to it only if the path has no usable name.
    static func folderName(of project: Project) -> String {
        let name = URL(fileURLWithPath: project.path).lastPathComponent
        return name.isEmpty || name == "/" ? project.displayName : name
    }

    /// The leading status-dot column is reserved at a fixed width even with no dot, so every title starts at the same x.
    private func taskRow(_ task: TaskRecord, project: Project) -> some View {
        let info = taskStatusInfo(for: task)
        let summary = info.summary
        let isVanished = info.isVanished
        let status = info.status
        let isMerged = info.isMerged
        let syncText = info.syncText
        let primary = theme.palette.textPrimary
        let secondary = theme.palette.textSecondary
        let tertiary = theme.palette.textDisabled

        return HStack(spacing: 6) {
            StatusDot(status: status, palette: theme.palette)
                .frame(width: TaskRowLayout.dotColumnWidth(for: status), alignment: .leading)

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
                mergedBadge()
            } else if info.hasPendingWork {
                pendingPill(ahead: info.pendingAhead, hasUncommittedChanges: info.hasUncommittedChanges)
            }

            if let syncText {
                Text(syncText)
                    .font(.caption2)
                    .foregroundStyle(tertiary)
            }
        }
        .padding(.vertical, 2)
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

    /// Tinted with `statusSuccess`, independent of native selection so it stays legible either way.
    private func mergedBadge() -> some View {
        let tint = theme.palette.statusSuccess
        return HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 11, weight: .bold))
            Text("Merged")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.15))
        )
    }

    /// Styled like `mergedBadge` but tinted `statusRunning`: the opposite state, work outstanding rather than landed.
    private func pendingPill(ahead: Int, hasUncommittedChanges: Bool) -> some View {
        let tint = theme.palette.statusRunning
        return HStack(spacing: 3) {
            if ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 11, weight: .semibold))
            }
            if hasUncommittedChanges {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.15))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BranchSyncSummary.accessibilityLabel(ahead: ahead, hasUncommittedChanges: hasUncommittedChanges) ?? "")
    }

    /// Pinned below the list, not a `List` row, so it never scrolls out of view.
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
