import SwiftUI

/// File-menu command for closing the selected task's terminal — takes over
/// the File menu's standard Close (Cmd+W) slot instead of adding a
/// competing item, since Cmd+W closing *the whole window* would be
/// destructive here: every task's terminal stays mounted for the app's
/// whole lifetime (see `MainAreaView`'s doc comment), so "close" for this
/// app means "end this one task's terminal", not "close the window".
///
/// Mirrors `ProjectCommands`'s and `NavigationCommands`'s pattern of a
/// `Commands` struct driving a per-window `ProjectsStore`.
public struct TerminalCommands: Commands {
    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close Task Terminal") {
                if case .task(let task, let project) = store.mainSelection {
                    store.closeTerminal(for: task, project: project)
                }
            }
            .keyboardShortcut(TerminalCloseShortcut.closeTask)
        }
    }
}

/// The task-terminal-close key equivalent, as plain data so it's directly
/// testable without introspecting a rendered `Commands` scene — same
/// rationale as `WindowLayoutShortcut`/`NavigationShortcuts`.
public enum TerminalCloseShortcut {
    public static let closeTask = KeyboardShortcut("w", modifiers: [.command])
}
