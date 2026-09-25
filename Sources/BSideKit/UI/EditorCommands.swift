import SwiftUI

/// File-menu command for "Open in VS Code": opens the selected task's
/// worktree, falling back to the selected project's own path when no task
/// is selected. Mirrors `ProjectCommands`'s and `TerminalCommands`'s pattern
/// of a `Commands` struct driving a per-window `ProjectsStore`, and the
/// toolbar button in `ContentView` calls the same `EditorLauncher` through
/// the same target-resolution logic so the two triggers can never disagree
/// about what "Open in VS Code" opens.
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

    /// The folder "Open in VS Code" should open: the selected task's own
    /// worktree when a task is selected — since a task is always the more
    /// specific selection, same rationale as
    /// `MainSelection.taskCreationTarget` — else the selected project's own
    /// path, else `nil` so both the toolbar button and the menu item can
    /// disable themselves rather than guessing when nothing is selected.
    /// Pure so it's directly testable without a store.
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

/// The "Open in VS Code" key equivalent, as plain data so it's directly
/// testable without introspecting a rendered `Commands` scene — same
/// rationale as `WindowLayoutShortcut`/`TerminalCloseShortcut`. Shift+Cmd+O
/// has no default Ghostty binding (unlike plain Cmd+O, which Ghostty's
/// defaults don't bind either, but which collides with no shortcut here to
/// begin with) and no existing app shortcut, so no
/// `GhosttyBridge.appOwnedKeybinds` entry is needed for it.
public enum EditorShortcut {
    public static let openInEditor = KeyboardShortcut("o", modifiers: [.command, .shift])
}
