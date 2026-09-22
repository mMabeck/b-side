import AppKit
import SwiftUI

/// Adding a project needs an `NSOpenPanel` folder picker and, when the chosen
/// directory isn't a git repo yet, a confirmation alert offering to `git
/// init` it. Several entry points now trigger this flow (the sidebar's
/// toolbar button, its pinned footer row, the empty-projects invite, Cmd+Shift+N,
/// and the File menu), so the panel/alert logic lives here once instead of
/// being copied into each call site. Both `NSOpenPanel.runModal()` and
/// `NSAlert.runModal()` are synchronous and app-modal, so there's no risk of
/// two entry points opening the panel at once the way there is for the task
/// creation sheet (see `ProjectsStore.pendingTaskCreationProject`).
@MainActor
public enum ProjectCreation {
    public static func addProject(store: ProjectsStore) {
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
    private static func offerToInitRepository(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Not a Git Repository"
        alert.informativeText = "\(url.lastPathComponent) isn't a git repository yet. Run \"git init\" in it?"
        alert.addButton(withTitle: "Initialize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
