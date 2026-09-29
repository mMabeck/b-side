import SwiftUI

public struct ProjectCommands: Commands {
    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

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
            .keyboardShortcut(ProjectCommandShortcut.newTask)

            Button("Add Project…") {
                ProjectCreation.addProject(store: store)
            }
            .keyboardShortcut(ProjectCommandShortcut.addProject)
        }
    }
}

public enum ProjectCommandShortcut {
    public static let newTask = KeyboardShortcut("n", modifiers: [.command])
    public static let addProject = KeyboardShortcut("n", modifiers: [.command, .shift])
}
