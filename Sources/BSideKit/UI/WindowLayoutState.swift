import SwiftUI

/// Single source of truth for whether each of the three collapsible chrome
/// regions is collapsed. Both toolbar buttons and View menu commands read
/// and toggle through this shared object so they can never drift apart.
/// The sidebars are window-wide; the terminal drawer is open per task or project.
@MainActor
public final class WindowLayoutState: ObservableObject {
    public static let shared = WindowLayoutState()

    @Published public var leftSidebarCollapsed: Bool {
        didSet { defaults.set(leftSidebarCollapsed, forKey: Keys.leftSidebar) }
    }
    @Published public var rightSidebarCollapsed: Bool {
        didSet { defaults.set(rightSidebarCollapsed, forKey: Keys.rightSidebar) }
    }
    @Published public private(set) var openTerminalDrawers: Set<TerminalDrawerKey> {
        didSet { defaults.set(openTerminalDrawers.map(\.rawValue).sorted(), forKey: Keys.openTerminalDrawers) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let leftSidebar = "leftSidebarCollapsed"
        static let rightSidebar = "rightSidebarCollapsed"
        static let openTerminalDrawers = "openTerminalDrawers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        leftSidebarCollapsed = defaults.object(forKey: Keys.leftSidebar) as? Bool ?? false
        rightSidebarCollapsed = defaults.object(forKey: Keys.rightSidebar) as? Bool ?? false
        let stored = defaults.stringArray(forKey: Keys.openTerminalDrawers) ?? []
        openTerminalDrawers = Set(stored.compactMap(TerminalDrawerKey.init(rawValue:)))
    }

    /// No `withAnimation` for either sidebar: `NavigationSplitView` and `.inspector`
    /// animate themselves, and a SwiftUI animation on top desyncs them under rapid toggling.
    public func toggleLeftSidebar() {
        leftSidebarCollapsed.toggle()
    }

    public func toggleRightSidebar() {
        rightSidebarCollapsed.toggle()
    }

    public func isTerminalDrawerOpen(for selection: MainSelection) -> Bool {
        TerminalDrawerKey(selection).map(openTerminalDrawers.contains) ?? false
    }

    public func toggleTerminalDrawer(for selection: MainSelection) {
        guard let key = TerminalDrawerKey(selection) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            if openTerminalDrawers.remove(key) == nil { openTerminalDrawers.insert(key) }
        }
    }

    /// Only keys seen and then removed: at launch projects load before their
    /// tasks, so "not currently live" doesn't mean deleted.
    func forgetTerminalDrawers(_ removed: Set<TerminalDrawerKey>) {
        guard !openTerminalDrawers.isDisjoint(with: removed) else { return }
        openTerminalDrawers.subtract(removed)
    }
}

public enum TerminalDrawerKey: Hashable, Sendable {
    case task(Int64)
    case project(Int64)

    init?(_ selection: MainSelection) {
        switch selection {
        case .none: return nil
        case .project(let project): guard let id = project.id else { return nil }; self = .project(id)
        case .task(let task, _): guard let id = task.id else { return nil }; self = .task(id)
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let id = Int64(parts[1]) else { return nil }
        switch parts[0] {
        case "task": self = .task(id)
        case "project": self = .project(id)
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .task(let id): "task:\(id)"
        case .project(let id): "project:\(id)"
        }
    }
}
