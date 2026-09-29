import SwiftUI

public struct NavigationCommands: Commands {
    private var store: ProjectsStore
    @FocusedValue(\.projectsStore) private var focusedStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandMenu("Go") {
            Group {
                ForEach(0..<NavigationShortcuts.digitCount, id: \.self) { index in
                    Button("Switch to Active Task \(index + 1)") {
                        guard
                            let id = NavigationShortcuts.activeTaskID(atIndex: index, in: store.openTerminalTaskIDs),
                            let match = store.taskAndProject(forID: id)
                        else { return }
                        store.selectTask(match.task, project: match.project)
                    }
                    .keyboardShortcut(NavigationShortcuts.activeTaskShortcut(forIndex: index))
                }

                Divider()

                ForEach(0..<NavigationShortcuts.digitCount, id: \.self) { index in
                    Button("Switch to Project \(index + 1)") {
                        guard let project = NavigationShortcuts.project(atIndex: index, in: store.projects) else { return }
                        store.selectProject(project)
                    }
                    .keyboardShortcut(NavigationShortcuts.projectShortcut(forIndex: index))
                }
            }
            .disabled(focusedStore == nil)
        }
    }
}
