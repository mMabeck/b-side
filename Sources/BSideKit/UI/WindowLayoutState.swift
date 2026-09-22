import SwiftUI

/// Single source of truth for whether each of the three collapsible chrome
/// regions (left sidebar, right sidebar, terminal drawer) is collapsed.
/// Both the toolbar buttons and the View menu commands read and toggle
/// through this shared, `UserDefaults`-backed object instead of keeping
/// parallel state, so the keyboard shortcuts and the on-screen controls can
/// never drift out of sync. Persists under the same keys the app's earlier
/// `@AppStorage` properties used.
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

    /// Brief, standard-eased toggle: fast enough that repeated toggling never
    /// feels sluggish. Wrapping the mutation here, rather than at each call
    /// site, keeps every trigger (toolbar button, menu item, shortcut)
    /// animating identically.
    public func toggleLeftSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { leftSidebarCollapsed.toggle() }
    }

    /// Deliberately *not* wrapped in a custom `withAnimation`, unlike the
    /// other two. The right sidebar is presented by SwiftUI's native
    /// `.inspector` modifier, which animates its own show/hide transition;
    /// imposing a 0.18s `easeInOut` on top of that overrides the system
    /// curve and is what made this side feel unlike the left column, which
    /// AppKit animates internally no matter what this wrapper says.
    public func toggleRightSidebar() {
        rightSidebarCollapsed.toggle()
    }

    public func toggleTerminalDrawer() {
        withAnimation(.easeInOut(duration: 0.18)) { terminalDrawerCollapsed.toggle() }
    }
}
