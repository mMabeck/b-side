import SwiftUI

/// Opens the selected task's worktree, falling back to the selected
/// project's own path. `ContentView`'s toolbar button uses the same
/// `targetFolder` resolution, so the two triggers can never disagree.
public struct EditorCommands: Commands {
    private var store: ProjectsStore
    private let launcher = EditorLauncher()

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open in VS Code") {
                if let folder = Self.targetFolder(selection: store.mainSelection) {
                    launcher.openFolder(folder)
                }
            }
            .keyboardShortcut(EditorShortcut.openInEditor)
            .disabled(Self.targetFolder(selection: store.mainSelection) == nil)
        }
    }

    /// A task's worktree, else the project's path, else `nil` so both triggers can disable themselves.
    static func targetFolder(selection: MainSelection) -> URL? {
        switch selection {
        case .none:
            return nil
        case .project(let project):
            return URL(fileURLWithPath: project.path)
        case .task(let task, _):
            return URL(fileURLWithPath: task.worktreePath)
        }
    }
}

/// Shift+Cmd+O has no default Ghostty binding, so no `GhosttyBridge.appOwnedKeybinds` entry is needed.
public enum EditorShortcut {
    public static let openInEditor = KeyboardShortcut("o", modifiers: [.command, .shift])
}
