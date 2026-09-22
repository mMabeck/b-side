import Foundation
import SwiftUI

/// The bottom terminal drawer: a second, independent shell surface in the
/// same directory as the main-area terminal, for the user's own use.
///
/// Collapsing the drawer does not tear down its surface — it marks it
/// not-visible (`TerminalSurfaceHost.isVisible = false`) per
/// native-rewrite.md §6, so its grid, scrollback and running shell survive
/// being hidden. `ContentView` keeps this view mounted at zero height rather
/// than conditionally removing it, so the surface is never deinitialized by
/// the collapse toggle.
struct TerminalDrawerView: View {
    var store: ProjectsStore
    var isCollapsed: Bool

    @State private var host: TerminalSurfaceHost?

    var body: some View {
        ZStack {
            if let host {
                TerminalHostView(host: host)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
        .task(id: store.selectedProject?.id) {
            let newHost = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(for: store))
            newHost.isVisible = !isCollapsed
            host = newHost
        }
        .onChange(of: isCollapsed) { _, collapsed in
            host?.isVisible = !collapsed
        }
    }
}
