import SwiftUI

/// The app's single window: left sidebar, main area, right sidebar, and a
/// collapsible bottom terminal drawer. All three regions are independently
/// collapsible and persist their collapsed state.
public struct ContentView: View {
    @ObservedObject private var layout = WindowLayoutState.shared
    @ObservedObject private var theme = GhosttyResolvedTheme.shared

    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layout.leftSidebarCollapsed ? .detailOnly : .all },
            set: { newValue in
                let collapsed = newValue == .detailOnly
                guard collapsed != layout.leftSidebarCollapsed else { return }
                layout.toggleLeftSidebar()
            }
        )
    }

    // Drives the native `.inspector` presentation from the same
    // `WindowLayoutState.shared.rightSidebarCollapsed` flag the toolbar
    // button and `WindowLayoutCommands`' View-menu item already toggle, so
    // there is one source of truth rather than parallel presentation state.
    private var rightSidebarPresented: Binding<Bool> {
        Binding(
            get: { !layout.rightSidebarCollapsed },
            set: { isPresented in
                guard isPresented == layout.rightSidebarCollapsed else { return }
                layout.toggleRightSidebar()
            }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(store: store)
                // The default sidebar column is narrow enough to truncate most
                // task names to a few characters, which defeats the point of
                // the list. Give it room, and a floor it cannot be dragged below.
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                MainAreaView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The native inspector column: real resizable-by-drag
                    // chrome with its own separator.
                    .inspector(isPresented: rightSidebarPresented) {
                        RightSidebarView(store: store)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 480)
                    }

                if !layout.terminalDrawerCollapsed {
                    Rectangle().fill(theme.palette.separator).frame(height: 1)
                }
                // Always mounted, collapsed to zero height rather than removed:
                // removing it from the hierarchy would deinit its terminal
                // surface instead of just marking it not-visible (see
                // TerminalDrawerView's doc comment and native-rewrite.md §6).
                TerminalDrawerView(store: store, isCollapsed: layout.terminalDrawerCollapsed)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: layout.terminalDrawerCollapsed ? 0 : 160,
                        maxHeight: layout.terminalDrawerCollapsed ? 0 : 240
                    )
                    .opacity(layout.terminalDrawerCollapsed ? 0 : 1)
                    .allowsHitTesting(!layout.terminalDrawerCollapsed)
                    .clipped()
            }
            // Only the right-sidebar toggle earns a toolbar slot: the left
            // sidebar already has NavigationSplitView's own native toggle, and
            // with the View-menu shortcuts from `WindowLayoutCommands` all
            // three regions are reachable regardless. Fewer competing
            // `ToolbarItem`s keeps the toolbar from overflowing into the
            // » chevron at normal window widths.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        layout.toggleRightSidebar()
                    } label: {
                        Label("Toggle Right Sidebar", systemImage: "sidebar.trailing")
                    }
                }
            }
        }
        .task {
            store.start()
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(theme.palette.windowBackground)
        .themedWindow(theme.palette)
    }
}
