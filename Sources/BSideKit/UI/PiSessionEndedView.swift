import SwiftUI

/// Replaces a task's dead terminal surface once its Pi process exits on its
/// own. Ghostty's own "Process exited" overlay is a dead end here since this
/// app never adopts a `TerminalSurfaceViewDelegate` to act on its keypress,
/// so this view stands in for the dead surface instead, in the same slot
/// `TerminalHostView` normally fills, themed off the resolved Ghostty palette.
///
/// `onResume` relaunches along the same `PiSessionService.launchCommand`
/// path a normal reopen uses, so resuming reattaches to the same session.
///
/// Shares `focusedTaskID` with `TerminalHostView` rather than a separate
/// `@FocusState`: while exited, nothing else competes to bind that id, so
/// `MainAreaView.syncFocus()` lands the Resume button focus the same way it lands terminal focus.
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
                    .foregroundStyle(theme.palette.selectionForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.palette.accent)
                    )
            }
            .buttonStyle(.plain)
            // Return works before explicit first-responder focus; `.focused`
            // below still gives it real focus once `syncFocus()` sets `focusedTaskID`.
            .keyboardShortcut(.defaultAction)
            .focused(focusedTaskID, equals: taskID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.windowBackground)
    }
}
