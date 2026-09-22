import Foundation
import SwiftUI

/// The selected task's agent terminal. For this stage (before task
/// creation exists) it hosts a plain login shell in the currently selected
/// project's directory, falling back to the user's home directory.
struct MainAreaView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    @State private var host: TerminalSurfaceHost?

    var body: some View {
        ZStack {
            if let host {
                TerminalHostView(host: host)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.windowBackground)
        .task(id: store.selectedProject?.id) {
            host = TerminalSurfaceHost(workingDirectory: MainAreaView.resolvedDirectory(for: store))
        }
    }

    static func resolvedDirectory(for store: ProjectsStore) -> URL {
        store.selectedProject.map { URL(fileURLWithPath: $0.path) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
