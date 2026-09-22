import SwiftUI

/// Right sidebar: Source Control and Subagents tabs. Both are placeholders at
/// this stage.
struct RightSidebarView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case sourceControl = "Source Control"
        case subagents = "Subagents"
        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .sourceControl

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch selectedTab {
            case .sourceControl:
                ContentUnavailableView(
                    "Source Control",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Changed files, staging and commit will appear here.")
                )
            case .subagents:
                ContentUnavailableView(
                    "Subagents",
                    systemImage: "person.2",
                    description: Text("Child agents spawned by the current task will appear here.")
                )
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 260, maxWidth: 320, maxHeight: .infinity)
    }
}
