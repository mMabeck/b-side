import SwiftUI

/// Placeholder for the selected task's agent terminal.
struct MainAreaView: View {
    var body: some View {
        ContentUnavailableView(
            "No Task Selected",
            systemImage: "terminal",
            description: Text("The agent terminal will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
