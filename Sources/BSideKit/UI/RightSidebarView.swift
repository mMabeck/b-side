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
            // Pinned flush to the sidebar's own top edge: the sidebar lives
            // in the `detail` column's content area, below the window's
            // unified toolbar rather than behind it, so the strip never has
            // to duck the toolbar's right-sidebar toggle button.
            InspectorTabStrip(
                items: Tab.allCases.map {
                    .init(tab: $0, title: $0.rawValue, systemImage: $0.systemImage)
                },
                selection: $selectedTab,
                accent: theme.palette.accent
            )
            .frame(height: 24)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Rectangle().fill(theme.palette.separator).frame(height: 1)

            Group {
                switch selectedTab {
                case .sourceControl:
                    ContentUnavailableView(
                        "Source Control",
                        systemImage: Tab.sourceControl.systemImage,
                        description: Text("Changed files, staging and commit will appear here.")
                    )
                    .foregroundStyle(theme.palette.textSecondary)
                case .subagents:
                    SubagentsTabView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.palette.surfaceBackground)
    }
}
