import SwiftUI

public struct ChangesCommands: Commands {
    private var store: ProjectsStore
    @ObservedObject private var focus = TaskWindowFocus.shared

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Group {
                Button("Show All Changes") {
                    if case .task(let task, _) = store.mainSelection {
                        store.pendingChangesOverlayTask = task
                    }
                }
                .keyboardShortcut(ChangesOverlayShortcut.showAllChanges)
                .disabled(!isTaskSelected)
            }
            .disabled(!focus.isTaskWindowInFront)
        }
    }

    private var isTaskSelected: Bool {
        if case .task = store.mainSelection { return true }
        return false
    }
}

/// Ghostty binds Cmd+Shift+D to `new_split:down`, so it is released in `GhosttyBridge.appOwnedKeybinds`.
public enum ChangesOverlayShortcut {
    public static let showAllChanges = KeyboardShortcut("d", modifiers: [.command, .shift])
}
