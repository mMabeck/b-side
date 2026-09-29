import SwiftUI
import Testing

@testable import BSideKit

@MainActor
@Suite("Window layout toggles and shortcuts")
struct WindowLayoutTests {
    @Test("The three shortcuts are pairwise distinct")
    func shortcutsAreDistinct() {
        let all = [
            WindowLayoutShortcut.leftSidebar,
            WindowLayoutShortcut.rightSidebar,
            WindowLayoutShortcut.terminalDrawer,
        ]
        for i in all.indices {
            for j in all.indices where i != j {
                let same = all[i].key.character == all[j].key.character && all[i].modifiers == all[j].modifiers
                #expect(!same)
            }
        }
    }

    @Test("Each sidebar toggle flips only its own region, and a double toggle restores it")
    func sidebarToggles() {
        let state = WindowLayoutState(defaults: makeIsolatedDefaults())
        let (left, right) = (state.leftSidebarCollapsed, state.rightSidebarCollapsed)

        state.toggleLeftSidebar()
        #expect(state.leftSidebarCollapsed == !left)
        #expect(state.rightSidebarCollapsed == right)

        state.toggleRightSidebar()
        state.toggleRightSidebar()
        #expect(state.rightSidebarCollapsed == right)
    }

    @Test("The terminal drawer opens for one task only, survives relaunch, and is forgotten once the task is deleted")
    func terminalDrawerIsPerTask() {
        let defaults = makeIsolatedDefaults()
        let project = Project(id: 7, path: "/tmp/project", displayName: "P", baseRef: "main")
        func task(_ id: Int64) -> MainSelection {
            .task(
                TaskRecord(
                    id: id, projectId: 7, name: "T", branchName: "b\(id)", worktreePath: "/tmp/w\(id)",
                    harness: "claude", permissionLevel: "default"
                ),
                project
            )
        }
        let state = WindowLayoutState(defaults: defaults)

        state.toggleTerminalDrawer(for: task(1))
        #expect(state.isTerminalDrawerOpen(for: task(1)))
        #expect(!state.isTerminalDrawerOpen(for: task(2)))
        #expect(!state.isTerminalDrawerOpen(for: .project(project)))
        #expect(!state.isTerminalDrawerOpen(for: .none))

        let relaunched = WindowLayoutState(defaults: defaults)
        #expect(relaunched.isTerminalDrawerOpen(for: task(1)))

        relaunched.forgetTerminalDrawers([.task(1)])
        #expect(!relaunched.isTerminalDrawerOpen(for: task(1)))
    }
}

private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "WindowLayoutTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}
