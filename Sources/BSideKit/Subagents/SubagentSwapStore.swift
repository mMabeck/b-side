import Foundation

/// Which surface a task's main area currently shows: the parent Pi terminal
/// (the default, `nil`) or one child's live surface. Keyed by task so
/// switching tasks in the sidebar never disturbs another task's swap state.
///
/// Distinct from `SubagentPaneStore`, which owns the actual child surfaces —
/// this only tracks *which one is currently on screen*, the same
/// presentation/data split `SubagentPaneStore`'s own doc comment describes
/// for panes vs. `SubagentFeedStore`.
@MainActor
@Observable
public final class SubagentSwapStore {
    public private(set) var shownChildIDByTask: [Int64: String] = [:]

    /// A card the user selected that has no live surface to swap to (a
    /// headless, card-only child) — highlighted in the strip, but the main
    /// area keeps showing whatever it already shows.
    public private(set) var highlightedChildIDByTask: [Int64: String] = [:]

    /// Bumped on every change to `shownChildIDByTask` — which surface a
    /// task's main area shows — so `MainAreaView` can re-derive
    /// `isVisible`/focus on a swap the same way `SubagentPaneStore.version`
    /// lets it react to panes appearing or disappearing. Not bumped for
    /// `highlightedChildIDByTask` alone, since highlighting a headless card
    /// never changes which surface is shown.
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

    /// Clicking the already-shown card, or the "main" hint, swaps back.
    public func toggle(childId: String, forTask taskId: Int64) {
        if shownChildIDByTask[taskId] == childId {
            showMain(forTask: taskId)
        } else {
            show(childId: childId, forTask: taskId)
        }
    }

    /// A shown child's surface closed (Pi `/close`, or the process exited):
    /// swap back to the parent. A no-op if `childId` wasn't the shown one.
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

/// Pure keyboard-shortcut index/order arithmetic for `SubagentSwapStore`,
/// directly testable — `⌃⌘0` shows the parent, `⌃⌘1`…`⌃⌘9` show the Nth
/// child in strip order, `⌃⌘]`/`⌃⌘[` step forward/back through the strip and
/// wrap at either end (`nil` counts as "before the first"/"after the last").
public enum SubagentSwapNavigation {
    public static func childID(atIndex index: Int, strip: [String]) -> String? {
        guard index >= 0, index < strip.count else { return nil }
        return strip[index]
    }

    /// `nil` shown means the parent is current; stepping "next" from the
    /// parent goes to the first child, and stepping past the last child
    /// wraps back to the parent.
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
