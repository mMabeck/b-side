import SwiftUI

public struct EditorCommands: Commands {
    private var store: ProjectsStore
    @ObservedObject private var focus = TaskWindowFocus.shared
    private let launcher = EditorLauncher()

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Group {
                Button("Open in VS Code") {
                    if let folder = Self.targetFolder(selection: store.mainSelection) {
                        launcher.openFolder(folder)
                    }
                }
                .keyboardShortcut(EditorShortcut.openInEditor)
                .disabled(Self.targetFolder(selection: store.mainSelection) == nil)
            }
            .disabled(!focus.isTaskWindowInFront)
        }
    }

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

/// Shift+Cmd+O has no default Ghostty binding, so no `appOwnedKeybinds` entry is needed.
public enum EditorShortcut {
    public static let openInEditor = KeyboardShortcut("o", modifiers: [.command, .shift])
}
