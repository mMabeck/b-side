import SwiftUI

/// Cmd+1\u20269 picks by position among open task terminals, which reorder on
/// recent activity, so a given Cmd+digit's target can shift. Ctrl+1\u20269
/// picks by position among sidebar projects, unaffected by activity. Both
/// stop at 9 since that's all a single digit key can address.
public enum NavigationShortcuts {
    public static let digitCount = 9

    public static func activeTaskShortcut(forIndex index: Int) -> KeyboardShortcut {
        KeyboardShortcut(digitKey(forIndex: index), modifiers: [.command])
    }

    public static func projectShortcut(forIndex index: Int) -> KeyboardShortcut {
        KeyboardShortcut(digitKey(forIndex: index), modifiers: [.control])
    }

    private static func digitKey(forIndex index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }

    /// `nil` when that position has no open terminal or `index` is out of range.
    public static func activeTaskID(atIndex index: Int, in openTaskIDs: [Int64]) -> Int64? {
        guard index >= 0, index < digitCount, index < openTaskIDs.count else { return nil }
        return openTaskIDs[index]
    }

    /// `nil` when that position has no project.
    public static func project(atIndex index: Int, in projects: [Project]) -> Project? {
        guard index >= 0, index < digitCount, index < projects.count else { return nil }
        return projects[index]
    }
}
