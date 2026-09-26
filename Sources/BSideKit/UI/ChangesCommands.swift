import SwiftUI

/// View-menu command for opening the Changes overlay (`ChangesOverlaySheet`)
/// for the selected task. Mirrors `EditorCommands`'/`TerminalCommands`'
/// pattern of a `Commands` struct driving a per-window `ProjectsStore`; the
/// Source Control panel's "Show All Changes" button sets the same
/// `store.pendingChangesOverlayTask` so the two triggers can never disagree
/// about what's shown or leave two sheets fighting over presentation.
public struct ChangesCommands: Commands {
    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show All Changes") {
                if case .task(let task, _) = store.mainSelection {
                    store.pendingChangesOverlayTask = task
                }
            }
            .keyboardShortcut(ChangesOverlayShortcut.showAllChanges)
            .disabled(!isTaskSelected)
        }
    }

    private var isTaskSelected: Bool {
        if case .task = store.mainSelection { return true }
        return false
    }
}

/// The Changes overlay's key equivalent, as plain data so it's directly
/// testable without introspecting a rendered `Commands` scene — same
/// rationale as `EditorShortcut`/`TerminalCloseShortcut`. Ghostty has no
/// confirmed default binding on Cmd+Shift+D, but it's released defensively
/// in `GhosttyBridge.appOwnedKeybinds` anyway, on the same basis as
/// Cmd+Shift+N there.
public enum ChangesOverlayShortcut {
    public static let showAllChanges = KeyboardShortcut("d", modifiers: [.command, .shift])
}
