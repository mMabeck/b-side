import AppKit
import SwiftUI

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

    private static func offerToInitRepository(at url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Not a Git Repository"
        alert.informativeText = "\(url.lastPathComponent) isn't a git repository yet. Run \"git init\" in it?"
        alert.addButton(withTitle: "Initialize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
