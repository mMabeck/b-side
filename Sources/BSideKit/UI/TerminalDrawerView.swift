import Foundation
import SwiftUI

/// The bottom terminal drawer: a second, independent shell surface in the
/// same directory the main area's current selection resolves to (a task's
/// worktree, its project's path with no task selected, or home with nothing
/// selected — see `MainAreaView.resolvedDirectory(for:)`), for the user's own
/// use.
///
/// Collapsing the drawer does not tear down its surface — it marks it
/// not-visible (`TerminalSurfaceHost.isVisible = false`) per
/// native-rewrite.md §6, so its grid, scrollback and running shell survive
/// being hidden. `ContentView` keeps this view mounted at zero height rather
/// than conditionally removing it, so the surface is never deinitialized by
/// the collapse toggle.
///
/// This one surface is replaced (not cached per task, unlike the main area's
/// task terminals) whenever the resolved directory changes: it is the user's
/// own scratch shell, not a per-task artifact worth keeping alive once they
/// have moved on.
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
        .task(id: MainAreaView.resolvedDirectory(for: store)) {
            let newHost = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(for: store))
            newHost.isVisible = !isCollapsed
            host = newHost
        }
        .onChange(of: isCollapsed) { _, collapsed in
            host?.isVisible = !collapsed
        }
    }
}
