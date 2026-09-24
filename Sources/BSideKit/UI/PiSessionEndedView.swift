import SwiftUI

/// Replaces a task's dead terminal surface once its Pi process has exited
/// on its own (the user quit `pi`, or it crashed). Ghostty's own built-in
/// "Process exited. Press any key to close the terminal." overlay is a dead
/// end in this app: `GhosttyBridge`'s doc comment on the events this app
/// handles notes that this app never adopts a `TerminalSurfaceViewDelegate`,
/// so nothing here ever acts on that keypress and the overlay just sits
/// there. This view stands in for that dead surface instead, mounted in the
/// same slot `TerminalHostView` normally fills (see `TaskTerminalAreaView`),
/// themed off the same resolved Ghostty palette as the rest of the app
/// rather than Ghostty's own hardcoded overlay styling.
///
/// `onResume` tears down the dead host and relaunches it along the same
/// `PiSessionService.launchCommand` path a normal reopen uses \u2014 see
/// `MainAreaView.relaunchHost(for:project:)` \u2014 so resuming reattaches to
/// the same pi session/transcript rather than starting a fresh one.
///
/// Shares `focusedTaskID` with `TerminalHostView` rather than using a
/// separate `@FocusState`: while a task is exited, no terminal surface is
/// mounted for its id (see `TaskTerminalAreaView`), so nothing else is
/// competing to bind that id and `MainAreaView.syncFocus()` setting
/// `focusedTaskID` to the visible task's id lands the Resume button focus
/// exactly like it lands terminal focus for a running task.
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
            // Default action: Return works even before the button has
            // explicit first-responder focus, and `.focused` below still
            // gives it real keyboard focus once `MainAreaView.syncFocus()`
            // hands this task's id to `focusedTaskID`.
            .keyboardShortcut(.defaultAction)
            .focused(focusedTaskID, equals: taskID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.windowBackground)
    }
}
