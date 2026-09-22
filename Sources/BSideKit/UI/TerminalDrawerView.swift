import Foundation
import SwiftUI

/// The bottom terminal drawer: a second, independent shell surface, for the
/// user's own use, started in whatever directory the main area's selection
/// resolved to the first time this view appeared (a task's worktree, its
/// project's path with no task selected, or home with nothing selected —
/// see `MainAreaView.resolvedDirectory(for:)`).
///
/// Collapsing the drawer does not tear down its surface — it marks it
/// not-visible (`TerminalSurfaceHost.isVisible = false`) per
/// native-rewrite.md §6, so its grid, scrollback and running shell survive
/// being hidden. `ContentView` keeps this view mounted at zero height rather
/// than conditionally removing it, so the surface is never deinitialized by
/// the collapse toggle.
///
/// Unlike the main area's per-task terminals, there is only ever one of
/// these for the whole session: it is created once, the first time this view
/// appears, and is never torn down or replaced afterwards — not even when
/// the selected task/project (and so `resolvedDirectory(for:)`) changes.
/// This is the user's own scratch shell, and they may be mid-command in it;
/// silently killing and respawning it every time they click a different
/// task row would be far more surprising than it starting in whatever
/// directory was current when the drawer first appeared. Nothing `cd`s it
/// automatically on selection change — a stable shell is the point, not a
/// synced one.
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
            // No `id:` — this view stays mounted for the whole session (see
            // the type doc comment), so a plain `.task` runs this exactly
            // once. Keying it on `resolvedDirectory(for: store)` like the
            // main area's per-task hosts do would resolve that directory
            // (a synchronous `FileManager.fileExists` call, transitively)
            // on every single body evaluation just to compare it against the
            // previous id, and would tear down and recreate this host —
            // killing whatever the user has running in it — on every
            // selection change instead of only on first appearance.
            guard host == nil else { return }
            let newHost = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(for: store))
            newHost.isVisible = !isCollapsed
            host = newHost
        }
        .onChange(of: isCollapsed) { _, collapsed in
            host?.isVisible = !collapsed
        }
    }
}
