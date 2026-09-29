import SwiftUI

/// Go-menu commands for jumping directly to an open task terminal
/// (Cmd+1…9) or a sidebar project (Ctrl+1…9), per `NavigationShortcuts`.
/// Mirrors `ProjectCommands`'s pattern of a `Commands` struct driving a
/// per-window `ProjectsStore` rather than a static singleton, so these
/// menu items and any keystroke that reaches them always act on the same
/// store the sidebar and main area show.
public struct NavigationCommands: Commands {
    private var store: ProjectsStore
    @ObservedObject private var focus = TaskWindowFocus.shared

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
            .disabled(!focus.isTaskWindowInFront)
        }
    }
}
