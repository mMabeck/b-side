import SwiftUI

/// The app's single window: left sidebar, main area, right sidebar, and a
/// collapsible bottom terminal drawer. All three regions are independently
/// collapsible and persist their collapsed state.
public struct ContentView: View {
    @ObservedObject private var layout = WindowLayoutState.shared
    @ObservedObject private var theme = GhosttyResolvedTheme.shared

    private var store: ProjectsStore
    private let editorLauncher = EditorLauncher()

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

    // Drives `.inspector` from the same flag the toolbar button and menu item toggle, one source of truth.
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
                // The default column is narrow enough to truncate most task names.
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                MainAreaView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .inspector(isPresented: rightSidebarPresented) {
                        RightSidebarView(store: store)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 480)
                    }

                if !layout.terminalDrawerCollapsed {
                    Rectangle().fill(theme.palette.separator).frame(height: 1)
                }
                // Always mounted, collapsed to zero height: removing it would
                // deinit its surface instead of marking it not-visible (native-rewrite.md §6).
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
            // The left sidebar already has NavigationSplitView's native toggle;
            // everything else with no other on-screen affordance earns a toolbar slot too.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let folder = EditorCommands.targetFolder(selection: store.mainSelection) {
                            editorLauncher.openFolder(folder)
                        }
                    } label: {
                        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("Open in VS Code (⇧⌘O)")
                    .accessibilityLabel("Open in VS Code")
                    .disabled(EditorCommands.targetFolder(selection: store.mainSelection) == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        layout.toggleTerminalDrawer()
                    } label: {
                        Label("Toggle Terminal", systemImage: "terminal")
                    }
                    .help(layout.terminalDrawerCollapsed ? "Show Terminal (⌘æ)" : "Hide Terminal (⌘æ)")
                    .accessibilityLabel(layout.terminalDrawerCollapsed ? "Show Terminal" : "Hide Terminal")
                    .disabled(store.mainSelection == .none)
                }
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
        // The one place the task-creation sheet is presented; every trigger
        // just sets `store.pendingTaskCreationProject` so it's never shown twice.
        .sheet(item: pendingTaskCreationProjectBinding) { project in
            // `project` can be stale if choices were persisted moments earlier; prefer the current store copy.
            TaskCreationView(project: store.projects.first(where: { $0.id == project.id }) ?? project, store: store) {
                store.pendingTaskCreationProject = nil
            }
        }
        // Same one-presentation-site rationale as above.
        .sheet(item: pendingChangesOverlayTaskBinding) { task in
            ChangesOverlaySheet(task: task) { path in
                editorLauncher.openFile(
                    URL(fileURLWithPath: task.worktreePath).appendingPathComponent(path),
                    in: URL(fileURLWithPath: task.worktreePath)
                )
            }
        }
    }

    private var pendingTaskCreationProjectBinding: Binding<Project?> {
        Binding(
            get: { store.pendingTaskCreationProject },
            set: { store.pendingTaskCreationProject = $0 }
        )
    }

    private var pendingChangesOverlayTaskBinding: Binding<TaskRecord?> {
        Binding(
            get: { store.pendingChangesOverlayTask },
            set: { store.pendingChangesOverlayTask = $0 }
        )
    }
}
