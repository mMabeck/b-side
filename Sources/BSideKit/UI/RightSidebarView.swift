import SwiftUI

/// Right sidebar: Source Control and Subagents tabs. Source Control is still
/// a placeholder; Subagents renders live cards from `SubagentFeedStore`.
struct RightSidebarView: View {
    var store: ProjectsStore
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    private enum Tab: String, CaseIterable, Identifiable {
        case sourceControl = "Source Control"
        case subagents = "Subagents"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .sourceControl: return "arrow.triangle.branch"
            case .subagents: return "person.2"
            }
        }
    }

    @State private var selectedTab: Tab = .sourceControl

    var body: some View {
        VStack(spacing: 0) {
            // Pinned flush to the sidebar's own top edge (no toolbar-clearing
            // padding here): the sidebar sits in the `detail` column's own
            // content area, below the window's unified toolbar, not behind
            // it, so this strip never has to duck the toolbar's right-sidebar
            // toggle button itself.
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(theme.palette.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)

            Rectangle().fill(theme.palette.separator).frame(height: 1)

            Group {
                switch selectedTab {
                case .sourceControl:
                    ContentUnavailableView(
                        "Source Control",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Changed files, staging and commit will appear here.")
                    )
                    .foregroundStyle(theme.palette.textSecondary)
                case .subagents:
                    SubagentsTabView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 260, maxWidth: 320, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.surfaceBackground)
    }
}
