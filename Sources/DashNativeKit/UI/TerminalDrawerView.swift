import SwiftUI

/// Placeholder for the bottom terminal drawer: a separate terminal, distinct from
/// the agent terminal, for the user's own shell in the same worktree.
struct TerminalDrawerView: View {
    var body: some View {
        ContentUnavailableView(
            "Terminal",
            systemImage: "terminal",
            description: Text("A shell in the task's worktree will appear here.")
        )
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
    }
}
