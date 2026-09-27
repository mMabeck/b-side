import Foundation

/// Which surface a task's main area shows: the parent (default, `nil`) or
/// one child's live surface. Keyed by task. Distinct from `SubagentPaneStore`,
/// which owns the actual surfaces; this only tracks which is on screen.
@MainActor
@Observable
public final class SubagentSwapStore {
    public private(set) var shownChildIDByTask: [Int64: String] = [:]

    /// A headless card-only child the user selected — highlighted in the strip, but the main area shows what it already shows.
    public private(set) var highlightedChildIDByTask: [Int64: String] = [:]

    /// Bumped on every `shownChildIDByTask` change so `MainAreaView` can
    /// re-derive `isVisible`/focus. Not bumped for highlighting alone, since that never changes what's shown.
    public private(set) var version = 0

    public init() {}

    public func shownChildID(forTask taskId: Int64) -> String? {
        shownChildIDByTask[taskId]
    }

    public func highlightedChildID(forTask taskId: Int64) -> String? {
        highlightedChildIDByTask[taskId]
    }

    public func showMain(forTask taskId: Int64) {
        highlightedChildIDByTask.removeValue(forKey: taskId)
        guard shownChildIDByTask.removeValue(forKey: taskId) != nil else { return }
        version += 1
    }

    public func show(childId: String, forTask taskId: Int64) {
        highlightedChildIDByTask.removeValue(forKey: taskId)
        guard shownChildIDByTask[taskId] != childId else { return }
        shownChildIDByTask[taskId] = childId
        version += 1
    }

    public func highlight(childId: String, forTask taskId: Int64) {
        highlightedChildIDByTask[taskId] = childId
    }

    /// Clicking the already-shown card swaps back.
    public func toggle(childId: String, forTask taskId: Int64) {
        if shownChildIDByTask[taskId] == childId {
            showMain(forTask: taskId)
        } else {
            show(childId: childId, forTask: taskId)
        }
    }

    /// Swaps back to the parent. No-op if `childId` wasn't the shown one.
    public func handleClosed(childId: String, taskId: Int64) {
        if shownChildIDByTask[taskId] == childId {
            shownChildIDByTask.removeValue(forKey: taskId)
            version += 1
        }
        if highlightedChildIDByTask[taskId] == childId {
            highlightedChildIDByTask.removeValue(forKey: taskId)
        }
    }

    public func closeAll(taskId: Int64) {
        highlightedChildIDByTask.removeValue(forKey: taskId)
        guard shownChildIDByTask.removeValue(forKey: taskId) != nil else { return }
        version += 1
    }
}

/// Pure keyboard-shortcut index/order arithmetic: `⌃⌘0` shows the parent,
/// `⌃⌘1`…`⌃⌘9` the Nth child, `⌃⌘]`/`⌃⌘[` step and wrap (`nil` = before first/after last).
public enum SubagentSwapNavigation {
    public static func childID(atIndex index: Int, strip: [String]) -> String? {
        guard index >= 0, index < strip.count else { return nil }
        return strip[index]
    }

    /// `nil` means the parent is current; "next" goes to the first child, past the last wraps to the parent.
    public static func next(after shown: String?, strip: [String]) -> String? {
        guard !strip.isEmpty else { return nil }
        guard let shown, let index = strip.firstIndex(of: shown) else { return strip[0] }
        let nextIndex = index + 1
        return nextIndex < strip.count ? strip[nextIndex] : nil
    }

    public static func previous(before shown: String?, strip: [String]) -> String? {
        guard !strip.isEmpty else { return nil }
        guard let shown, let index = strip.firstIndex(of: shown) else { return strip[strip.count - 1] }
        let previousIndex = index - 1
        return previousIndex >= 0 ? strip[previousIndex] : nil
    }
}
