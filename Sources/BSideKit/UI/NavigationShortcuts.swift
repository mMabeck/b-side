import SwiftUI

/// Digit shortcuts for jumping straight to one of the sidebar's "Active"
/// tasks or projects, as plain data \u2014 same rationale as
/// `WindowLayoutShortcut`: directly testable without introspecting a
/// rendered `Commands` scene. Cmd+1\u20269 picks by position among currently
/// open task terminals (`ProjectsStore.openTerminalTaskIDs`), which reorders
/// on recent activity \u2014 so a given Cmd+digit's target task can shift as
/// tasks become active. Ctrl+1\u20269 picks by position among sidebar
/// projects (`ProjectsStore.projects`), whose order is unaffected. Both stop
/// at 9 since that's all a single digit key can address.
public enum NavigationShortcuts {
    /// How many digit shortcuts exist in each family (1\u20269).
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

    /// The task id Cmd+`(index + 1)` should select, or `nil` when that
    /// position has no open terminal (fewer than `index + 1` tasks are
    /// open, or `index` is out of the addressable 0\u20268 range). Pure and
    /// index-based, mirroring `MainAreaView.idsToPurge`'s "testable without
    /// a live store" shape.
    public static func activeTaskID(atIndex index: Int, in openTaskIDs: [Int64]) -> Int64? {
        guard index >= 0, index < digitCount, index < openTaskIDs.count else { return nil }
        return openTaskIDs[index]
    }

    /// The project Ctrl+`(index + 1)` should select, or `nil` when that
    /// position has no project.
    public static func project(atIndex index: Int, in projects: [Project]) -> Project? {
        guard index >= 0, index < digitCount, index < projects.count else { return nil }
        return projects[index]
    }
}
