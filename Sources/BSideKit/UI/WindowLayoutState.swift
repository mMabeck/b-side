import SwiftUI

/// Single source of truth for whether each of the three collapsible chrome
/// regions is collapsed. Both toolbar buttons and View menu commands read
/// and toggle through this shared object so they can never drift apart.
@MainActor
public final class WindowLayoutState: ObservableObject {
    public static let shared = WindowLayoutState()

    @Published public var leftSidebarCollapsed: Bool {
        didSet { defaults.set(leftSidebarCollapsed, forKey: Keys.leftSidebar) }
    }
    @Published public var rightSidebarCollapsed: Bool {
        didSet { defaults.set(rightSidebarCollapsed, forKey: Keys.rightSidebar) }
    }
    @Published public var terminalDrawerCollapsed: Bool {
        didSet { defaults.set(terminalDrawerCollapsed, forKey: Keys.terminalDrawer) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let leftSidebar = "leftSidebarCollapsed"
        static let rightSidebar = "rightSidebarCollapsed"
        static let terminalDrawer = "terminalDrawerCollapsed"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        leftSidebarCollapsed = defaults.object(forKey: Keys.leftSidebar) as? Bool ?? false
        rightSidebarCollapsed = defaults.object(forKey: Keys.rightSidebar) as? Bool ?? false
        terminalDrawerCollapsed = defaults.object(forKey: Keys.terminalDrawer) as? Bool ?? true
    }

    /// No `withAnimation` for either sidebar: `NavigationSplitView` and `.inspector`
    /// animate themselves, and a SwiftUI animation on top desyncs them under rapid toggling.
    public func toggleLeftSidebar() {
        leftSidebarCollapsed.toggle()
    }

    public func toggleRightSidebar() {
        rightSidebarCollapsed.toggle()
    }

    public func toggleTerminalDrawer() {
        withAnimation(.easeInOut(duration: 0.18)) { terminalDrawerCollapsed.toggle() }
    }
}
