import Foundation
import SwiftUI

/// Scratch shells for the user's own commands, one per task (or project), hidden
/// rather than torn down on selection change or collapse so
/// a running command survives; `ContentView` keeps this mounted at zero height.
struct TerminalDrawerView: View {
    typealias DrawerKey = TerminalDrawerKey

    private struct DrawerState: Equatable {
        let key: DrawerKey?
        let isCollapsed: Bool
    }

    var store: ProjectsStore
    var isCollapsed: Bool
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var hostsByKey: [DrawerKey: TerminalSurfaceHost] = [:]

    private var currentKey: DrawerKey? {
        DrawerKey(store.mainSelection)
    }

    /// Every key the current projects and tasks still back; `purgeHosts` drops the rest.
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
        .onChange(of: DrawerState(key: currentKey, isCollapsed: isCollapsed), initial: true) { old, new in
            if !new.isCollapsed { ensureHost(for: new.key) }
            syncVisibility()
            // Focus moves only on a toggle; switching to a task whose drawer
            // is open leaves focus with that task's main terminal.
            guard old.key == new.key, old.isCollapsed != new.isCollapsed, let key = new.key else { return }
            if new.isCollapsed {
                hostsByKey[key]?.resignFocus()
                store.requestTerminalFocus()
            } else {
                hostsByKey[key]?.focus()
            }
        }
        .onChange(of: liveKeys) { old, keys in
            purgeHosts(keeping: keys)
            WindowLayoutState.shared.forgetTerminalDrawers(old.subtracting(keys))
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

    private func purgeHosts(keeping keys: Set<DrawerKey>) {
        hostsByKey = hostsByKey.filter { keys.contains($0.key) }
    }
}
