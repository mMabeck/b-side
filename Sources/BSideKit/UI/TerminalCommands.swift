import AppKit
import SwiftUI

/// Replaces the standard Close slot: Cmd+W ends the task's terminal instead of closing the whole window.
public struct TerminalCommands: Commands {
    private var store: ProjectsStore
    @ObservedObject private var focus = TaskWindowFocus.shared

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(focus.keyWindowRole == .task ? "Close Task Terminal" : "Close") {
                // Re-read at click time: a sheet or Settings may have become key since the menu was built.
                focus.close(NSApplication.shared.keyWindow) {
                    if case .task(let task, let project) = store.mainSelection {
                        store.closeTerminal(for: task, project: project)
                    }
                }
            }
            .keyboardShortcut(TerminalCloseShortcut.closeTask)

            Button("Restart Pi Session") {
                if case .task(let task, _) = store.mainSelection {
                    store.requestRestartTerminal(for: task)
                }
            }
            .keyboardShortcut(TerminalCloseShortcut.restartSession)
            .disabled(!isTaskSelected || !focus.isTaskWindowInFront)
        }
    }

    private var isTaskSelected: Bool {
        if case .task = store.mainSelection { return true }
        return false
    }
}

public enum TerminalCloseShortcut {
    public static let closeTask = KeyboardShortcut("w", modifiers: [.command])

    /// Cmd+Shift+R, since Ghostty binds plain Cmd+R to `reload_config`.
    public static let restartSession = KeyboardShortcut("r", modifiers: [.command, .shift])
}
