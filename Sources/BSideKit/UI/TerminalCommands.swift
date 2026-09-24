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

            // Works whether the task's agent process is still alive (kills
            // it, then relaunches) or has already exited (the "Pi session
            // ended" state's Resume button is the other way to trigger the
            // same request) — both just call `ProjectsStore.requestRestartTerminal`,
            // which `MainAreaView` is the sole actor on.
            Button("Restart Pi Session") {
                if case .task(let task, _) = store.mainSelection {
                    store.requestRestartTerminal(for: task)
                }
            }
            .keyboardShortcut(TerminalCloseShortcut.restartSession)
            .disabled(!isTaskSelected)
        }
    }

    private var isTaskSelected: Bool {
        if case .task = store.mainSelection { return true }
        return false
    }
}

/// The task-terminal-close key equivalent, as plain data so it's directly
/// testable without introspecting a rendered `Commands` scene — same
/// rationale as `WindowLayoutShortcut`/`NavigationShortcuts`.
public enum TerminalCloseShortcut {
    public static let closeTask = KeyboardShortcut("w", modifiers: [.command])

    /// Cmd+Shift+R rather than plain Cmd+R, which Ghostty's own defaults
    /// bind to `reload_config` — see `GhosttyBridge.appOwnedKeybinds`'s
    /// defensive unbind of it.
    public static let restartSession = KeyboardShortcut("r", modifiers: [.command, .shift])
}
