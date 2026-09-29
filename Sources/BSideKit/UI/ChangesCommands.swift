import SwiftUI

/// View-menu command for opening the Changes overlay (`ChangesOverlaySheet`)
/// for the selected task. Mirrors `EditorCommands`'/`TerminalCommands`'
/// pattern of a `Commands` struct driving a per-window `ProjectsStore`; the
/// Source Control panel's "Show All Changes" button sets the same
/// `store.pendingChangesOverlayTask` so the two triggers can never disagree
/// about what's shown or leave two sheets fighting over presentation.
public struct ChangesCommands: Commands {
    private var store: ProjectsStore
    @FocusedValue(\.projectsStore) private var focusedStore

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
            .disabled(focusedStore == nil)
        }
    }

    private var isTaskSelected: Bool {
        if case .task = store.mainSelection { return true }
        return false
    }
}

/// The Changes overlay's key equivalent, as plain data so it's directly
/// testable without introspecting a rendered `Commands` scene — same
/// rationale as `EditorShortcut`/`TerminalCloseShortcut`. Ghostty's macOS
/// default binds Cmd+Shift+D to `new_split:down`, so it's released in
/// `GhosttyBridge.appOwnedKeybinds` because it's required, not defensive.
public enum ChangesOverlayShortcut {
    public static let showAllChanges = KeyboardShortcut("d", modifiers: [.command, .shift])
}
