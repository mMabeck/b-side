import AppKit
import SwiftUI

extension FocusedValues {
    /// Non-nil while the task window (or a sheet on it) is key; Settings doesn't publish it.
    @Entry var projectsStore: ProjectsStore?
}

@MainActor
enum CommandWindowRouting {
    private final class Action {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private static let sheetActions = NSMapTable<NSWindow, Action>.weakToStrongObjects()

    static func setSheetCloseAction(_ action: @escaping () -> Void, for window: NSWindow) {
        sheetActions.setObject(Action(action), forKey: window)
    }

    /// Cmd+W: a sheet runs its own dismiss (it has no close button, so `performClose` would
    /// only beep), the task window ends its terminal, any other window closes normally.
    static func close(_ window: NSWindow?, isTaskWindow: Bool, closeTaskTerminal: () -> Void) {
        guard let window else { return }
        if window.sheetParent != nil {
            sheetActions.object(forKey: window)?.run()
        } else if isTaskWindow {
            closeTaskTerminal()
        } else {
            window.performClose(nil)
        }
    }
}

extension View {
    func closesSheetOnCommandW(_ action: @escaping () -> Void) -> some View {
        background(WindowAccessor { CommandWindowRouting.setSheetCloseAction(action, for: $0) })
    }
}
