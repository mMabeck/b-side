import SwiftUI

/// The Subagents tab of the right sidebar: a scrollable list of cards, one
/// per child the selected task has spawned, driven by `SubagentFeedStore`.
/// Native splits are a separate, later piece of stage 7 — this is the card
/// half, and both will render from this same feed.
struct SubagentsTabView: View {
    var store: ProjectsStore

    var body: some View {
        let runs = store.selectedTaskID.map(store.subagentFeed.runs(forTask:)) ?? []

        Group {
            if store.selectedTaskID == nil {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "person.2",
                    description: Text("Select a task to see its subagents.")
                )
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "Subagents",
                    systemImage: "person.2",
                    description: Text("Child agents spawned by this task will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(runs) { run in
                            SubagentCardView(run: run, theme: GhosttyResolvedTheme.shared)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
