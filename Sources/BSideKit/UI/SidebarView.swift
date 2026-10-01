import AppKit
import SwiftUI

/// Themed SwiftUI `List`, not `NSOutlineView`, over the system's Liquid Glass sidebar chrome.
struct SidebarView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared
    @AppStorage("sidebarCollapsedProjectIDs") private var collapseState = SidebarCollapseState()

    @State private var expandedTaskListProjectIDs: Set<Int64> = []

    @State private var pendingDeleteTask: (task: TaskRecord, project: Project)?

    private static let collapsedTaskLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            if store.projects.isEmpty {
                emptyProjectsState
            } else {
                List(selection: $selection) {
                    if !activeTaskRows.isEmpty {
                        Section("Active") {
                            // A second reorder before NSTableView's row-move animation settles composites one row's content under another's.
                            ForEach(activeTaskRows) { entry in
                                activeTaskRow(entry.task, project: entry.project, shortcutIndex: entry.shortcutIndex)
                                    .sidebarRowHover(isSelected: selection.contains(.activeTask(entry.taskID)), palette: theme.palette)
                                    .tag(SidebarRowID.activeTask(entry.taskID))
                            }
                            .transaction { $0.animation = nil }
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
                                ForEach(childRows(for: project, tasks: tasks)) { row in
                                    switch row {
                                    case .empty:
                                        Text("No tasks")
                                            .font(.system(size: 13))
                                            .foregroundStyle(theme.palette.textSecondary)
                                            .padding(.leading, TaskRowLayout.statusDotColumnWidth + 6)
                                            .padding(.vertical, 6)
                                    case .task(let task):
                                        taskRow(task, project: project)
                                            .sidebarRowHover(isSelected: selection.contains(.task(task.id ?? -1)), palette: theme.palette)
                                            .tag(SidebarRowID.task(task.id ?? -1))
                                    case .showMore(let hiddenCount, let projectID):
                                        showMoreRow(hiddenCount: hiddenCount, projectID: projectID)
                                    case .showLess(let projectID):
                                        showLessRow(projectID: projectID)
                                    }
                                }
                            } label: {
                                projectRow(project, taskCount: tasks.count)
                                    .sidebarRowHover(isSelected: selection.contains(.project(project.id ?? -1)), palette: theme.palette)
                            }
                            .tag(SidebarRowID.project(project.id ?? -1))
                        }
                        .onMove { source, destination in
                            Task { try? await store.moveProjects(fromOffsets: source, toOffset: destination) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlayScrollers()
                .onAppear { syncSelectionFromStore() }
                .onChange(of: selection) { oldValue, newValue in
                    // Deselecting, Cmd-clicking the selection, or clicking a task's mirror row adds nothing new; treat that as a revert.
                    guard let clicked = Self.clickedRow(from: oldValue, to: newValue) else {
                        syncSelectionFromStore()
                        return
                    }
                    guard !Self.matches(clicked, selectedTaskID: store.selectedTaskID, selectedProjectID: store.selectedProjectID) else {
                        syncSelectionFromStore()
                        return
                    }
                    switch clicked {
                    case .task(let id), .activeTask(let id):
                        if let match = store.taskAndProject(forID: id) {
                            store.selectTask(match.task, project: match.project)
                        }
                    case .project(let id):
                        if let project = store.projects.first(where: { $0.id == id }) {
                            store.selectProject(project)
                        }
                    }
                }
                .onChange(of: store.openTerminalTaskIDs) { syncSelectionFromStore() }
                .onChange(of: store.selectedTaskID) { syncSelectionFromStore() }
                .onChange(of: store.selectedProjectID) { syncSelectionFromStore() }
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

    // Distinct tags for a task shown in both Active and its project; a shared identity left the native highlight stuck.
    enum SidebarRowID: Hashable {
        case project(Int64)
        case task(Int64)
        case activeTask(Int64)
    }

    @State private var selection: Set<SidebarRowID> = []

    static func matches(_ row: SidebarRowID, selectedTaskID: Int64?, selectedProjectID: Int64?) -> Bool {
        switch row {
        case .task(let id), .activeTask(let id):
            return id == selectedTaskID
        case .project(let id):
            return selectedTaskID == nil && id == selectedProjectID
        }
    }

    /// A selected task with an open terminal is highlighted both in Active and under its project.
    static func selectedRows(selectedTaskID: Int64?, selectedProjectID: Int64?, openTaskIDs: [Int64]) -> Set<SidebarRowID> {
        if let selectedTaskID {
            return openTaskIDs.contains(selectedTaskID) ? [.task(selectedTaskID), .activeTask(selectedTaskID)] : [.task(selectedTaskID)]
        }
        return selectedProjectID.map { [.project($0)] } ?? []
    }

    /// Ambiguous changes such as Shift-click ranges yield nil rather than guessing which row was meant.
    static func clickedRow(from oldRows: Set<SidebarRowID>, to newRows: Set<SidebarRowID>) -> SidebarRowID? {
        let added = newRows.subtracting(oldRows)
        return added.count == 1 ? added.first : nil
    }

    private func syncSelectionFromStore() {
        let rows = Self.selectedRows(
            selectedTaskID: store.selectedTaskID,
            selectedProjectID: store.selectedProjectID,
            openTaskIDs: store.openTerminalTaskIDs
        )
        if selection != rows {
            selection = rows
        }
    }

    // Row ids must be unique across the whole List, not just per ForEach.
    /// One `ForEach` for all of a project's rows, so a project drop lands below the last one.
    private enum ProjectChildRow: Identifiable {
        case empty
        case task(TaskRecord)
        case showMore(hiddenCount: Int, projectID: Int64)
        case showLess(projectID: Int64)

        var id: String {
            switch self {
            case .empty: "empty"
            case .task(let task): "task-\(task.id ?? -1)"
            case .showMore: "show-more"
            case .showLess: "show-less"
            }
        }
    }

    private func childRows(for project: Project, tasks: [TaskRecord]) -> [ProjectChildRow] {
        guard !tasks.isEmpty else { return [.empty] }
        let isExpanded = project.id.map { expandedTaskListProjectIDs.contains($0) } ?? false
        let visible = Self.visibleTasks(
            tasks,
            limit: Self.collapsedTaskLimit,
            expanded: isExpanded,
            selectedTaskID: store.selectedTaskID
        )
        var rows = visible.map(ProjectChildRow.task)
        if tasks.count > Self.collapsedTaskLimit, let projectID = project.id {
            rows.append(isExpanded ? .showLess(projectID: projectID) : .showMore(hiddenCount: tasks.count - visible.count, projectID: projectID))
        }
        return rows
    }

    private struct ActiveTaskEntry: Identifiable {
        let taskID: Int64
        let task: TaskRecord
        let project: Project
        let shortcutIndex: Int
        var id: SidebarRowID { .activeTask(taskID) }
    }

    /// Same order as `NavigationShortcuts.activeTaskID`, so a row's position matches its Cmd-digit.
    private var activeTaskRows: [ActiveTaskEntry] {
        store.openTerminalTaskIDs.enumerated().compactMap { index, id in
            store.taskAndProject(forID: id).map { ActiveTaskEntry(taskID: id, task: $0.task, project: $0.project, shortcutIndex: index) }
        }
    }

    private struct TaskStatusInfo {
        let status: TaskStatus
        let summary: TaskChildSummary
        let isVanished: Bool
        let isMerged: Bool
        let hasPendingWork: Bool
        let pendingAhead: Int
        let hasUncommittedChanges: Bool
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
        .contextMenu { taskContextMenu(task, project: project) }
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }

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

    private func canMoveProject(_ project: Project, direction: ProjectMoveDirection) -> Bool {
        guard let index = store.projects.firstIndex(where: { $0.id == project.id }) else { return false }
        return direction == .up ? index > 0 : index < store.projects.count - 1
    }

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

    static func folderName(of project: Project) -> String {
        let name = URL(fileURLWithPath: project.path).lastPathComponent
        return name.isEmpty || name == "/" ? project.displayName : name
    }

    static func visibleTasks(_ tasks: [TaskRecord], limit: Int, expanded: Bool, selectedTaskID: Int64?) -> [TaskRecord] {
        guard !expanded, tasks.count > limit else { return tasks }
        var visible = Array(tasks.prefix(limit))
        if let selectedTaskID, !visible.contains(where: { $0.id == selectedTaskID }),
            let selectedTask = tasks.first(where: { $0.id == selectedTaskID }) {
            visible.append(selectedTask)
        }
        return visible
    }

    private func showMoreRow(hiddenCount: Int, projectID: Int64) -> some View {
        Button {
            expandedTaskListProjectIDs.insert(projectID)
        } label: {
            Text("Show \(hiddenCount) More")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.leading, TaskRowLayout.statusDotColumnWidth + 6)
        }
        .buttonStyle(.plain)
    }

    private func showLessRow(projectID: Int64) -> some View {
        Button {
            expandedTaskListProjectIDs.remove(projectID)
        } label: {
            Text("Show Less")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.leading, TaskRowLayout.statusDotColumnWidth + 6)
        }
        .buttonStyle(.plain)
    }

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
        .contextMenu { taskContextMenu(task, project: project) }
        .task(id: task.id) {
            await store.refreshSyncStatus(for: task, project: project)
        }
    }

    @ViewBuilder
    private func taskContextMenu(_ task: TaskRecord, project: Project) -> some View {
        if let id = task.id {
            Button(store.unreadTaskIDs.contains(id) ? "Mark as Read" : "Mark as Unread") {
                store.toggleTaskUnread(id)
            }
            Divider()
        }
        Button("Archive") {
            Task { try? await store.archiveTask(task, project: project, removeWorktree: true) }
        }
        Button("Delete…", role: .destructive) {
            pendingDeleteTask = (task, project)
        }
    }

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
