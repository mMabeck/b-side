import AppKit
import SwiftUI

public struct WindowLayoutCommands: Commands {
    @ObservedObject private var layout = WindowLayoutState.shared
    private var store: ProjectsStore
    @FocusedValue(\.projectsStore) private var focusedStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Group {
                Button(layout.leftSidebarCollapsed ? "Show Left Sidebar" : "Hide Left Sidebar") {
                    // AppKit's own toggle survives rapid repeats; flipping SwiftUI state races the split view's animation and stale visibility write-back.
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
            .disabled(focusedStore == nil)
        }
    }
}

/// Cmd+Æ uses the physical key that produces "æ" on a Danish keyboard.
public enum WindowLayoutShortcut {
    public static let leftSidebar = KeyboardShortcut("b", modifiers: [.command])
    public static let rightSidebar = KeyboardShortcut("b", modifiers: [.command, .option])
    public static let terminalDrawer = KeyboardShortcut("æ", modifiers: [.command])
}
