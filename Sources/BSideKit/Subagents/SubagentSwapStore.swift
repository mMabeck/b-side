import Foundation

@MainActor
@Observable
public final class SubagentSwapStore {
    public private(set) var shownChildIDByTask: [Int64: String] = [:]

    public private(set) var highlightedChildIDByTask: [Int64: String] = [:]

    /// Bumped when the shown child changes, not for highlighting alone, so `MainAreaView` re-derives visibility.
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

    public func toggle(childId: String, forTask taskId: Int64) {
        if shownChildIDByTask[taskId] == childId {
            showMain(forTask: taskId)
        } else {
            show(childId: childId, forTask: taskId)
        }
    }

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

public enum SubagentSwapNavigation {
    public static func childID(atIndex index: Int, strip: [String]) -> String? {
        guard index >= 0, index < strip.count else { return nil }
        return strip[index]
    }

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
