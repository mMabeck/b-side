import AppKit
import SwiftUI

/// Replaces the standard Close slot: Cmd+W ends the task's terminal instead of closing the whole window.
public struct TerminalCommands: Commands {
    private var store: ProjectsStore
    @FocusedValue(\.projectsStore) private var focusedStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(focusedStore != nil ? "Close Task Terminal" : "Close") {
                // Re-read at click time: a sheet or Settings may have become key since the menu was built.
                CommandWindowRouting.close(NSApplication.shared.keyWindow, isTaskWindow: focusedStore != nil) {
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
            .disabled(!isTaskSelected || focusedStore == nil)

            Button(isSelectedTaskUnread ? "Mark as Read" : "Mark as Unread") {
                if let id = selectedTaskID {
                    store.toggleTaskUnread(id)
                }
            }
            .keyboardShortcut(TerminalCloseShortcut.toggleUnread)
            .disabled(selectedTaskID == nil || focusedStore == nil)
        }
    }

    private var isTaskSelected: Bool {
        selectedTaskID != nil
    }

    private var selectedTaskID: Int64? {
        if case .task(let task, _) = store.mainSelection { return task.id }
        return nil
    }

    private var isSelectedTaskUnread: Bool {
        selectedTaskID.map(store.unreadTaskIDs.contains) ?? false
    }
}

public enum TerminalCloseShortcut {
    public static let closeTask = KeyboardShortcut("w", modifiers: [.command])

    /// Cmd+Shift+R, since Ghostty binds plain Cmd+R to `reload_config`.
    public static let restartSession = KeyboardShortcut("r", modifiers: [.command, .shift])

    public static let toggleUnread = KeyboardShortcut("u", modifiers: [.command, .shift])
}
