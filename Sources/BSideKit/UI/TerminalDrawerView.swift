import Foundation
import SwiftUI

/// The bottom terminal drawer: a second, independent scratch shell, started
/// in whatever directory the main area's selection resolved to the first time this view appeared.
///
/// Collapsing marks the surface not-visible (native-rewrite.md §6) rather
/// than tearing it down; `ContentView` keeps this view mounted at zero
/// height so it's never deinitialized by the collapse toggle.
///
/// Only ever one for the whole session, created once and never torn down or
/// replaced — the user may be mid-command in it, so silently respawning it
/// on every selection change would be far more surprising than a stable
/// shell that doesn't follow the selection.
struct TerminalDrawerView: View {
    var store: ProjectsStore
    var isCollapsed: Bool
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var host: TerminalSurfaceHost?

    var body: some View {
        ZStack {
            if let host {
                TerminalHostView(host: host)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
        .background(theme.palette.elevatedSurfaceBackground)
        .task {
            // No `id:`: keying on `resolvedDirectory(for: store)` like the
            // main area's per-task hosts do would recreate this host —
            // killing whatever's running in it — on every selection change.
            guard host == nil else { return }
            let newHost = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(for: store))
            newHost.isVisible = !isCollapsed
            host = newHost
        }
        // Collapsing must hand focus back to the task terminal, or the now-hidden shell would keep swallowing keystrokes.
        .onChange(of: isCollapsed) { _, collapsed in
            host?.isVisible = !collapsed
            if collapsed {
                host?.resignFocus()
                store.requestTerminalFocus()
            } else {
                host?.focus()
            }
        }
    }
}
