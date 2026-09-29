import SwiftUI

/// Stands in for the dead surface: Ghostty's "Process exited" overlay is a dead end since the app never adopts a `TerminalSurfaceViewDelegate`.
struct PiSessionEndedView: View {
    var taskID: Int64
    var focusedTaskID: FocusState<Int64?>.Binding
    var onResume: () -> Void
    @ObservedObject var theme: GhosttyResolvedTheme = .shared

    var body: some View {
        VStack(spacing: 14) {
            Text("Pi session ended")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Text("The task agent process exited. Resume to reattach to the same session.")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: onResume) {
                Text("Resume Session")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.glassProminent)
            .tint(theme.palette.accent)
            .controlSize(.large)
            // Return works before first-responder focus lands; `.focused` takes over once `syncFocus()` runs.
            .keyboardShortcut(.defaultAction)
            .focused(focusedTaskID, equals: taskID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.windowBackground)
    }
}
