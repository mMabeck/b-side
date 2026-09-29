import AppKit
import SwiftUI

/// Real View-menu commands for the three collapsible chrome regions, rather
/// than invisible global key handlers. Titles flip between Show/Hide so the
/// menu always reflects current state, and every toggle goes through
/// ``WindowLayoutState/shared`` \u2014 the same object the toolbar buttons drive \u2014
/// so there is one source of truth, not parallel state.
public struct WindowLayoutCommands: Commands {
    @ObservedObject private var layout = WindowLayoutState.shared
    private var store: ProjectsStore
    @ObservedObject private var focus = TaskWindowFocus.shared

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Group {
                Button(layout.leftSidebarCollapsed ? "Show Left Sidebar" : "Hide Left Sidebar") {
                    // AppKit's own toggle survives rapid repeats; flipping SwiftUI state races
                    // the split view's animation and its stale visibility write-back.
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(WindowLayoutShortcut.leftSidebar)

                Button(layout.rightSidebarCollapsed ? "Show Right Sidebar" : "Hide Right Sidebar") {
                    layout.toggleRightSidebar()
                }
                .keyboardShortcut(WindowLayoutShortcut.rightSidebar)

                Button(layout.isTerminalDrawerOpen(for: store.mainSelection) ? "Hide Terminal" : "Show Terminal") {
                    layout.toggleTerminalDrawer(for: store.mainSelection)
                }
                .disabled(store.mainSelection == .none)
                .keyboardShortcut(WindowLayoutShortcut.terminalDrawer)
            }
            .disabled(!focus.isTaskWindowInFront)
        }
    }
}

/// The three region-toggle key equivalents, as plain data so they can be
/// asserted on directly in tests without introspecting a rendered `Commands`
/// scene. Cmd+B and Cmd+Option+B are the conventional macOS pairing for a
/// primary/secondary sidebar; Cmd+Æ uses the physical key that produces
/// "æ" on a Danish keyboard for the one region with no macOS convention to
/// follow.
public enum WindowLayoutShortcut {
    public static let leftSidebar = KeyboardShortcut("b", modifiers: [.command])
    public static let rightSidebar = KeyboardShortcut("b", modifiers: [.command, .option])
    public static let terminalDrawer = KeyboardShortcut("æ", modifiers: [.command])
}
