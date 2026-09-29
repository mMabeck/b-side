import AppKit
import SwiftUI

/// Which kind of window is key, so app-wide menu commands that act on the
/// task window stand down while another window (Settings) is in front.
@MainActor
public final class TaskWindowFocus: ObservableObject {
    public enum Role: Equatable {
        case task
        /// A sheet presented on a task window, e.g. the Changes overlay.
        case taskSheet
        case other
    }

    public static let shared = TaskWindowFocus()

    @Published public private(set) var keyWindowRole: Role = .other
    private let taskWindows = NSHashTable<NSWindow>.weakObjects()
    private let sheetCloseActions = NSMapTable<NSWindow, CloseAction>.weakToStrongObjects()

    private final class CloseAction {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    public var isTaskWindowInFront: Bool { keyWindowRole != .other }

    func register(_ window: NSWindow) {
        guard !taskWindows.contains(window) else { return }
        taskWindows.add(window)
        refresh()
    }

    func role(of window: NSWindow?) -> Role {
        guard let window else { return .other }
        if taskWindows.contains(window) { return .task }
        var parent = window.sheetParent
        while let current = parent {
            if taskWindows.contains(current) { return .taskSheet }
            parent = current.sheetParent
        }
        return .other
    }

    func setSheetCloseAction(_ action: @escaping () -> Void, for window: NSWindow) {
        sheetCloseActions.setObject(CloseAction(action), forKey: window)
    }

    /// Cmd+W: ends the task terminal in a task window, runs a sheet's own
    /// dismiss (sheets have no close button, so `performClose` would only
    /// beep), and closes any other window normally.
    func close(_ window: NSWindow?, closeTaskTerminal: () -> Void) {
        guard let window else { return }
        switch role(of: window) {
        case .task:
            closeTaskTerminal()
        case .taskSheet:
            sheetCloseActions.object(forKey: window)?.run()
        case .other:
            window.performClose(nil)
        }
    }

    private func refresh() {
        let role = role(of: NSApplication.shared.keyWindow)
        if role != keyWindowRole { keyWindowRole = role }
    }
}

extension View {
    func registersTaskWindow() -> some View {
        background(WindowAccessor { TaskWindowFocus.shared.register($0) })
    }

    /// For a sheet on the task window: what Cmd+W does while it is key.
    func closesSheetOnCommandW(_ action: @escaping () -> Void) -> some View {
        background(WindowAccessor { TaskWindowFocus.shared.setSheetCloseAction(action, for: $0) })
    }
}
