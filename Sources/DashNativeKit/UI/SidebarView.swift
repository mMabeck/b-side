import AppKit
import SwiftUI

/// Left sidebar: projects with tasks nested beneath.
///
/// Uses SwiftUI `List` for now. Per the native UI decisions this should become an
/// `NSOutlineView` in source-list style (better at large, frequently updating,
/// per-row-status lists with drag reordering and context menus) — deferred past
/// the skeleton stage.
struct SidebarView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var taskCreationProject: Project?
    @State private var pendingDeleteTask: (task: TaskRecord, project: Project)?

    var body: some View {
        List {
            ForEach(store.projects) { project in
                Section {
                    let tasks = project.id.flatMap { store.tasksByProject[$0] } ?? []
                    if tasks.isEmpty {
                        Text("No tasks")
                            .foregroundStyle(theme.palette.textSecondary)
                    } else {
                        ForEach(tasks) { task in
                            taskRow(task, project: project)
                        }
                    }
                } header: {
                    Button {
                        store.selectedProjectID = project.id
                    } label: {
                        HStack {
                            Text(project.displayName)
                            if store.selectedProjectID == project.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .contextMenu {
                    Button("New Task…") {
                        taskCreationProject = project
                    }
                    Button("Remove Project", role: .destructive) {
                        Task { try? await store.removeProject(project) }
                    }
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

    private func taskRow(_ task: TaskRecord, project: Project) -> some View {
        let summary = task.id.map(store.subagentFeed.summary(forTask:)) ?? TaskChildSummary(activeCount: 0, totalCount: 0, isBlocked: false)
        return Button {
            store.selectedTaskID = task.id
        } label: {
            HStack {
                Label(task.name, systemImage: store.vanishedWorktreeTaskIds.contains(task.id ?? -1) ? "exclamationmark.triangle" : "circle")
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
                if store.selectedTaskID == task.id {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Archive") {
                Task { try? await store.archiveTask(task, project: project, removeWorktree: true) }
            }
            Button("Delete…", role: .destructive) {
                pendingDeleteTask = (task, project)
            }
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
