import Foundation
import SwiftUI

/// Scratch shells for the user's own commands, one per task (or project), hidden
/// rather than torn down on selection change or collapse so
/// a running command survives; `ContentView` keeps this mounted at zero height.
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

    private func purgeHosts(keeping keys: Set<DrawerKey>) {
        hostsByKey = hostsByKey.filter { keys.contains($0.key) }
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
