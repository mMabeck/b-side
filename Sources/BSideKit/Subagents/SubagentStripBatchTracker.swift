import Foundation

/// Decides which of a task's children the strip currently shows: active/
/// blocked always, plus a short linger past `endedAt` so a ✓/✗ is briefly
/// readable, unless swapped into the main area (stays until swapped back).
/// Pure function of the runs plus wall-clock time, so nothing needs to be
/// remembered across calls (`nextBatch` is directly testable).
@MainActor
public final class SubagentStripBatchTracker {
    public static let lingerInterval: TimeInterval = 3

    public init() {}

    /// Runs to show for `taskId`'s strip right now, oldest first.
    public func visibleRuns(
        forTask taskId: Int64,
        allRuns: [ChildRun],
        swappedInChildID: String? = nil,
        now: Date = Date()
    ) -> [ChildRun] {
        let ids = Self.nextBatch(allRuns: allRuns, now: now, swappedInChildID: swappedInChildID)
        return allRuns.filter { ids.contains($0.id) }
    }

    /// Retained for callers that used to reset per-task batch memory on
    /// teardown; visibility no longer depends on tracked state.
    public func reset(taskId: Int64) {}

    public static func nextBatch(
        allRuns: [ChildRun],
        now: Date,
        swappedInChildID: String?,
        lingerInterval: TimeInterval = lingerInterval
    ) -> Set<String> {
        Set(allRuns.compactMap { run -> String? in
            switch run.state {
            case .active, .blocked:
                return run.id
            case .completed, .failed:
                if run.id == swappedInChildID { return run.id }
                guard let endedAt = run.endedAt else { return run.id }
                return now.timeIntervalSince(endedAt) < lingerInterval ? run.id : nil
            }
        })
    }

    /// Ones whose card has aged out of `nextBatch`, so a finished child stops holding a pane slot.
    public static func agedOutPaneIDs(
        allRuns: [ChildRun],
        livePaneIDs: Set<String>,
        now: Date,
        swappedInChildID: String?
    ) -> Set<String> {
        livePaneIDs.subtracting(nextBatch(allRuns: allRuns, now: now, swappedInChildID: swappedInChildID))
    }
}
