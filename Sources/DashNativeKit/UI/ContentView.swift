import SwiftUI

/// The app's single window: left sidebar, main area, right sidebar, and a
/// collapsible bottom terminal drawer. All three regions are independently
/// collapsible and persist their collapsed state.
public struct ContentView: View {
    @AppStorage("leftSidebarCollapsed") private var leftSidebarCollapsed = false
    @AppStorage("rightSidebarCollapsed") private var rightSidebarCollapsed = false
    @AppStorage("terminalDrawerCollapsed") private var terminalDrawerCollapsed = true
    @ObservedObject private var theme = GhosttyResolvedTheme.shared

    private var store: ProjectsStore

    public init(store: ProjectsStore) {
        self.store = store
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { leftSidebarCollapsed ? .detailOnly : .all },
            set: { leftSidebarCollapsed = ($0 == .detailOnly) }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(store: store)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MainAreaView(store: store)
                    if !rightSidebarCollapsed {
                        Rectangle().fill(theme.palette.separator).frame(width: 1)
                        RightSidebarView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !terminalDrawerCollapsed {
                    Rectangle().fill(theme.palette.separator).frame(height: 1)
                }
                // Always mounted, collapsed to zero height rather than removed:
                // removing it from the hierarchy would deinit its terminal
                // surface instead of just marking it not-visible (see
                // TerminalDrawerView's doc comment and native-rewrite.md §6).
                TerminalDrawerView(store: store, isCollapsed: terminalDrawerCollapsed)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: terminalDrawerCollapsed ? 0 : 160,
                        maxHeight: terminalDrawerCollapsed ? 0 : 240
                    )
                    .opacity(terminalDrawerCollapsed ? 0 : 1)
                    .allowsHitTesting(!terminalDrawerCollapsed)
                    .clipped()
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        rightSidebarCollapsed.toggle()
                    } label: {
                        Label("Toggle Right Sidebar", systemImage: "sidebar.trailing")
                    }
                }
                ToolbarItem {
                    Button {
                        terminalDrawerCollapsed.toggle()
                    } label: {
                        Label("Toggle Terminal Drawer", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                }
            }
        }
        .task {
            store.start()
        }
        .background(theme.palette.windowBackground)
        .themedWindow(theme.palette)
    }
}
