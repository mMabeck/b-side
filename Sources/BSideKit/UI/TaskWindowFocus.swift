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
        if let parent = window.sheetParent, taskWindows.contains(parent) { return .taskSheet }
        return .other
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
}
