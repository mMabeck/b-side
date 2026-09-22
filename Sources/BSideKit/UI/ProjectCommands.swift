import SwiftUI

/// File-menu commands for creating tasks and projects, in the standard
/// `CommandGroup(replacing: .newItem)` slot so they take over the File
/// menu's conventional "New"/Cmd+N position instead of adding a competing
/// item elsewhere. Mirrors `WindowLayoutCommands`'s pattern of a `Commands`
/// struct that only drives shared state (here, `ProjectsStore`, held per
/// window rather than a static `.shared` since the store isn't a singleton)
/// so the menu items, the sidebar's own buttons, and Cmd+N/Cmd+Shift+N can
/// never drift into disagreement about what they trigger.
public struct ProjectCommands: Commands {
    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                if let project = store.mainSelection.taskCreationTarget {
                    store.pendingTaskCreationProject = project
                }
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Add Project…") {
                ProjectCreation.addProject(store: store)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
