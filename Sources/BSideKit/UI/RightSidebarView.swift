import SwiftUI

/// Right sidebar: Source Control. The Subagents tab was removed — subagent
/// activity now renders as a card strip inside each task's own terminal area
/// (see `SubagentStripView`), not as a separate sidebar surface.
struct RightSidebarView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView(
                "Source Control",
                systemImage: "arrow.triangle.branch",
                description: Text("Changed files, staging and commit will appear here.")
            )
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.palette.surfaceBackground)
    }
}
