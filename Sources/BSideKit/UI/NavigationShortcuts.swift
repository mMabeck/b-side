import SwiftUI

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

    public static func activeTaskID(atIndex index: Int, in openTaskIDs: [Int64]) -> Int64? {
        guard index >= 0, index < digitCount, index < openTaskIDs.count else { return nil }
        return openTaskIDs[index]
    }

    public static func project(atIndex index: Int, in projects: [Project]) -> Project? {
        guard index >= 0, index < digitCount, index < projects.count else { return nil }
        return projects[index]
    }
}
