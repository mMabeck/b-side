import SwiftUI

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
                if collapsed != layout.leftSidebarCollapsed {
                    layout.leftSidebarCollapsed = collapsed
                }
            }
        )
    }

    private var rightSidebarPresented: Binding<Bool> {
        Binding(
            get: { !layout.rightSidebarCollapsed },
            set: { isPresented in
                if isPresented == layout.rightSidebarCollapsed {
                    layout.rightSidebarCollapsed = !isPresented
                }
            }
        )
    }

    private var drawerOpen: Bool {
        layout.isTerminalDrawerOpen(for: store.mainSelection)
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                MainAreaView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .inspector(isPresented: rightSidebarPresented) {
                        RightSidebarView(store: store)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 480)
                    }

                if drawerOpen {
                    Rectangle().fill(theme.palette.separator).frame(height: 1)
                }
                // Always mounted, collapsed to zero height: removing it would deinit its surface instead of marking it not-visible.
                TerminalDrawerView(store: store, isCollapsed: !drawerOpen)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: drawerOpen ? 160 : 0,
                        maxHeight: drawerOpen ? 240 : 0
                    )
                    .opacity(drawerOpen ? 1 : 0)
                    .allowsHitTesting(drawerOpen)
                    .clipped()
            }
            .toolbar {
                // Without the title as flexible space, trailing items collapse leftwards.
                ToolbarSpacer(.flexible)
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
                        layout.toggleTerminalDrawer(for: store.mainSelection)
                    } label: {
                        Label("Toggle Terminal", systemImage: "terminal")
                    }
                    .help(drawerOpen ? "Hide Terminal (⌘æ)" : "Show Terminal (⌘æ)")
                    .accessibilityLabel(drawerOpen ? "Hide Terminal" : "Show Terminal")
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
        .focusedSceneValue(\.projectsStore, store)
        // The sole presentation site for the task-creation sheet; triggers only set `store.pendingTaskCreationProject`.
        .sheet(item: pendingTaskCreationProjectBinding) { project in
            // `project` can be stale if choices were persisted moments earlier; prefer the current store copy.
            TaskCreationView(project: store.projects.first(where: { $0.id == project.id }) ?? project, store: store) {
                store.pendingTaskCreationProject = nil
            }
        }
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
