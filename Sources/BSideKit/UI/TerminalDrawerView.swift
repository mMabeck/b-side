import Foundation
import SwiftUI

/// The bottom terminal drawer: a second, independent scratch shell for the
/// user's own commands, distinct from the agent terminal in the main area.
///
/// One shell per task (or per project, for a project dashboard with no task
/// selected), cached by `DrawerKey` and never torn down on selection change,
/// only hidden — mirrors `MainAreaView.hostsByTaskID` so a user mid-command
/// in one task's drawer shell isn't interrupted by switching away and back.
/// A shell is created lazily, the first time the drawer is opened for that
/// key, not on every selection change.
///
/// Collapsing marks the visible surface not-visible (native-rewrite.md §6)
/// rather than tearing it down; `ContentView` keeps this view mounted at
/// zero height so it's never deinitialized by the collapse toggle.
struct TerminalDrawerView: View {
    enum DrawerKey: Hashable {
        case task(Int64)
        case project(Int64)
    }

    var store: ProjectsStore
    var isCollapsed: Bool
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var hostsByKey: [DrawerKey: TerminalSurfaceHost] = [:]

    private var currentKey: DrawerKey? {
        Self.key(for: store.mainSelection)
    }

    /// Live keys the current project/task set still supports; anything else cached gets purged.
    private var liveKeys: Set<DrawerKey> {
        var keys = Set(store.tasksByProject.values.flatMap { $0.compactMap { $0.id.map(DrawerKey.task) } })
        keys.formUnion(store.projects.compactMap { $0.id.map(DrawerKey.project) })
        return keys
    }

    var body: some View {
        ZStack {
            ForEach(Array(hostsByKey.keys), id: \.self) { key in
                if let host = hostsByKey[key] {
                    let isVisible = !isCollapsed && key == currentKey
                    TerminalHostView(host: host)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
        .background(theme.palette.elevatedSurfaceBackground)
        .task(id: currentKey) {
            guard !isCollapsed else { return }
            ensureHost(for: currentKey)
            syncVisibility()
        }
        .onChange(of: isCollapsed) { _, collapsed in
            if collapsed {
                if let key = currentKey { hostsByKey[key]?.resignFocus() }
                syncVisibility()
                store.requestTerminalFocus()
            } else {
                ensureHost(for: currentKey)
                syncVisibility()
                if let key = currentKey { hostsByKey[key]?.focus() }
            }
        }
        .onChange(of: liveKeys) { _, keys in
            purgeHosts(keeping: keys)
        }
    }

    private func ensureHost(for key: DrawerKey?) {
        guard let key, hostsByKey[key] == nil, store.mainSelection != .none else { return }
        // Reuses `MainAreaView`'s resolution so this drawer never disagrees
        // with the main area about "where is this selection, on disk".
        hostsByKey[key] = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(for: store))
    }

    private func syncVisibility() {
        for (key, host) in hostsByKey {
            host.isVisible = !isCollapsed && key == currentKey
        }
    }

    private func purgeHosts(keeping liveKeys: Set<DrawerKey>) {
        for key in hostsByKey.keys where !liveKeys.contains(key) {
            hostsByKey.removeValue(forKey: key)
        }
    }

    static func key(for selection: MainSelection) -> DrawerKey? {
        switch selection {
        case .none:
            return nil
        case .project(let project):
            return project.id.map(DrawerKey.project)
        case .task(let task, _):
            return task.id.map(DrawerKey.task)
        }
    }
}
