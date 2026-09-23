import SwiftUI
import Testing

@testable import BSideKit

/// Pure logic behind the sidebar's "Active" section and its Cmd+1…9/Ctrl+1…9
/// shortcuts: no live window, no rendered menu, no terminal.
@MainActor
@Suite("Navigation shortcuts and open-terminal ordering")
struct NavigationShortcutsTests {
    // MARK: - ProjectsStore.openTerminalTaskIDs ordering

    @Test("Opening a terminal appends its task id in order opened")
    func addingOpenTerminalAppendsInOrder() {
        var ids: [Int64] = []
        ids = ProjectsStore.addingOpenTerminal(3, to: ids)
        ids = ProjectsStore.addingOpenTerminal(1, to: ids)
        ids = ProjectsStore.addingOpenTerminal(2, to: ids)
        #expect(ids == [3, 1, 2])
    }

    @Test("Re-opening an already-tracked task id does not reorder it")
    func addingOpenTerminalIsIdempotentAndPreservesOrder() {
        let ids = ProjectsStore.addingOpenTerminal(1, to: [3, 1, 2])
        #expect(ids == [3, 1, 2])
    }

    @Test("Removing open terminals drops only the removed ids, preserving order")
    func removingOpenTerminalsPreservesOrder() {
        let ids = ProjectsStore.removingOpenTerminals([1, 5], from: [3, 1, 2, 5])
        #expect(ids == [3, 2])
    }

    @Test("Removing ids not present in the list is a no-op")
    func removingOpenTerminalsIgnoresUnknownIds() {
        let ids = ProjectsStore.removingOpenTerminals([99], from: [3, 1, 2])
        #expect(ids == [3, 1, 2])
    }

    // MARK: - NavigationShortcuts index mapping

    @Test("Active task id at index maps to the Nth-opened terminal")
    func activeTaskIDMapsByPosition() {
        let openTaskIDs: [Int64] = [10, 20, 30]
        #expect(NavigationShortcuts.activeTaskID(atIndex: 0, in: openTaskIDs) == 10)
        #expect(NavigationShortcuts.activeTaskID(atIndex: 1, in: openTaskIDs) == 20)
        #expect(NavigationShortcuts.activeTaskID(atIndex: 2, in: openTaskIDs) == 30)
    }

    @Test("Active task id is nil past the end of the open list")
    func activeTaskIDNilPastEnd() {
        #expect(NavigationShortcuts.activeTaskID(atIndex: 3, in: [10, 20, 30]) == nil)
        #expect(NavigationShortcuts.activeTaskID(atIndex: 0, in: []) == nil)
    }

    @Test("Active task id is nil past the ninth position even with more open terminals")
    func activeTaskIDStopsAtNine() {
        let openTaskIDs: [Int64] = Array(1...12).map(Int64.init)
        #expect(NavigationShortcuts.activeTaskID(atIndex: 8, in: openTaskIDs) == 9)
        #expect(NavigationShortcuts.activeTaskID(atIndex: 9, in: openTaskIDs) == nil)
    }

    @Test("Project at index maps to the Nth sidebar project")
    func projectAtIndexMapsByPosition() {
        let projects = [
            Project(id: 1, path: "/a", displayName: "A", baseRef: "main"),
            Project(id: 2, path: "/b", displayName: "B", baseRef: "main"),
        ]
        #expect(NavigationShortcuts.project(atIndex: 0, in: projects)?.id == 1)
        #expect(NavigationShortcuts.project(atIndex: 1, in: projects)?.id == 2)
        #expect(NavigationShortcuts.project(atIndex: 2, in: projects) == nil)
    }

    // MARK: - Shortcut definitions

    @Test("Active task shortcuts are Cmd+1…9")
    func activeTaskShortcutsAreCmdDigits() {
        for index in 0..<9 {
            let shortcut = NavigationShortcuts.activeTaskShortcut(forIndex: index)
            #expect(shortcut.key.character == Character("\(index + 1)"))
            #expect(shortcut.modifiers == [.command])
        }
    }

    @Test("Project shortcuts are Ctrl+1…9")
    func projectShortcutsAreCtrlDigits() {
        for index in 0..<9 {
            let shortcut = NavigationShortcuts.projectShortcut(forIndex: index)
            #expect(shortcut.key.character == Character("\(index + 1)"))
            #expect(shortcut.modifiers == [.control])
        }
    }

    @Test("Active task and project shortcuts never collide")
    func shortcutFamiliesAreDisjoint() {
        for index in 0..<9 {
            let task = NavigationShortcuts.activeTaskShortcut(forIndex: index)
            let project = NavigationShortcuts.projectShortcut(forIndex: index)
            #expect(task.modifiers != project.modifiers)
        }
    }

    // MARK: - Ghostty unbinds

    @Test("The generated Ghostty config unbinds Cmd+1…9 and Ctrl+1…9")
    func ghosttyConfigUnbindsDigitShortcuts() {
        for digit in 1...9 {
            #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = cmd+\(digit)=unbind"))
            #expect(GhosttyBridge.appOwnedKeybinds.contains("keybind = ctrl+\(digit)=unbind"))
        }
    }
}
