import SwiftUI

/// Takes over the File menu's standard Close (Cmd+W) slot instead of adding
/// a competing item, since Cmd+W closing the whole window would be
/// destructive: every task's terminal stays mounted for the app's lifetime,
/// so "close" here means "end this one task's terminal".
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

            // Works whether the process is alive (kills then relaunches) or
            // already exited (same as the "Pi session ended" Resume button).
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

public enum TerminalCloseShortcut {
    public static let closeTask = KeyboardShortcut("w", modifiers: [.command])

    /// Cmd+Shift+R rather than plain Cmd+R, which Ghostty's defaults bind to `reload_config`.
    public static let restartSession = KeyboardShortcut("r", modifiers: [.command, .shift])
}
