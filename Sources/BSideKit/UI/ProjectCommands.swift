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

    /// Which project a bare "New Task"/Cmd+N should target when nothing is
    /// selected: `selection`'s own target (the most recently selected task's
    /// or project's project — `selectedProjectID` is sticky across
    /// deselection, so this already covers "most recently selected") if
    /// there is one, else the first project in list order, else `nil` so the
    /// action can no-op rather than guessing when there are no projects at
    /// all. Pure so it's directly testable without a store.
    static func defaultTaskCreationProject(selection: MainSelection, projects: [Project]) -> Project? {
        selection.taskCreationTarget ?? projects.first
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                if let project = Self.defaultTaskCreationProject(selection: store.mainSelection, projects: store.projects) {
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
