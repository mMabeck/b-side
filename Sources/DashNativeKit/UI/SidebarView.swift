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

    var body: some View {
        List {
            ForEach(store.projects) { project in
                Section {
                    let tasks = project.id.flatMap { store.tasksByProject[$0] } ?? []
                    if tasks.isEmpty {
                        Text("No tasks")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tasks) { task in
                            Label(task.name, systemImage: "circle")
                        }
                    }
                } header: {
                    Text(project.displayName)
                }
                .contextMenu {
                    Button("Remove Project", role: .destructive) {
                        Task { try? await store.removeProject(project) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button(action: addProject) {
                    Label("Add Project", systemImage: "plus")
                }
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
