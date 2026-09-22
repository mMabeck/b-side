import SwiftUI

/// The app's single window: left sidebar, main area, right sidebar, and a
/// collapsible bottom terminal drawer. All three regions are independently
/// collapsible and persist their collapsed state.
public struct ContentView: View {
    @AppStorage("leftSidebarCollapsed") private var leftSidebarCollapsed = false
    @AppStorage("rightSidebarCollapsed") private var rightSidebarCollapsed = false
    @AppStorage("terminalDrawerCollapsed") private var terminalDrawerCollapsed = true

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
                    MainAreaView()
                    if !rightSidebarCollapsed {
                        Divider()
                        RightSidebarView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !terminalDrawerCollapsed {
                    Divider()
                    TerminalDrawerView()
                }
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
    }
}
