import SwiftUI
import Testing

@testable import DashNativeKit

/// Pure logic for the three collapsible-region toggles: no live window, no
/// rendered menu, no terminal.
@MainActor
@Suite("Window layout toggles and shortcuts")
struct WindowLayoutTests {
    @Test("Left sidebar shortcut is Cmd+B")
    func leftSidebarShortcut() {
        #expect(WindowLayoutShortcut.leftSidebar.key.character == "b")
        #expect(WindowLayoutShortcut.leftSidebar.modifiers == [.command])
    }

    @Test("Right sidebar shortcut is Cmd+Option+B")
    func rightSidebarShortcut() {
        #expect(WindowLayoutShortcut.rightSidebar.key.character == "b")
        #expect(WindowLayoutShortcut.rightSidebar.modifiers == [.command, .option])
    }

    @Test("Terminal drawer shortcut is Cmd+Æ")
    func terminalDrawerShortcut() {
        #expect(WindowLayoutShortcut.terminalDrawer.key.character == "æ")
        #expect(WindowLayoutShortcut.terminalDrawer.modifiers == [.command])
    }

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

    @Test("Each toggle flips only its own region, independent of the others")
    func togglesAreIndependent() {
        let state = WindowLayoutState(defaults: makeIsolatedDefaults())
        let (left, right, drawer) = (state.leftSidebarCollapsed, state.rightSidebarCollapsed, state.terminalDrawerCollapsed)

        state.toggleLeftSidebar()
        #expect(state.leftSidebarCollapsed == !left)
        #expect(state.rightSidebarCollapsed == right)
        #expect(state.terminalDrawerCollapsed == drawer)

        state.toggleRightSidebar()
        #expect(state.rightSidebarCollapsed == !right)
        #expect(state.terminalDrawerCollapsed == drawer)

        state.toggleTerminalDrawer()
        #expect(state.terminalDrawerCollapsed == !drawer)
    }

    @Test("Toggling twice returns a region to its original state")
    func doubleToggleIsIdentity() {
        let state = WindowLayoutState(defaults: makeIsolatedDefaults())
        let original = state.terminalDrawerCollapsed

        state.toggleTerminalDrawer()
        state.toggleTerminalDrawer()

        #expect(state.terminalDrawerCollapsed == original)
    }

    @Test("Layout state persists collapsed flags under the app's established UserDefaults keys")
    func persistsUnderEstablishedKeys() {
        let defaults = makeIsolatedDefaults()
        let state = WindowLayoutState(defaults: defaults)

        state.toggleLeftSidebar()
        state.toggleTerminalDrawer()

        #expect(defaults.object(forKey: "leftSidebarCollapsed") as? Bool == state.leftSidebarCollapsed)
        #expect(defaults.object(forKey: "terminalDrawerCollapsed") as? Bool == state.terminalDrawerCollapsed)
    }
}

/// A `UserDefaults` suite unique to each call, so tests never read or write
/// the app's real persisted layout state (or each other's).
private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "WindowLayoutTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}
