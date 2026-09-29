import Foundation

/// Pure function of runs and wall-clock time, so `nextBatch` needs no remembered state.
@MainActor
public final class SubagentStripBatchTracker {
    public static let lingerInterval: TimeInterval = 3

    public init() {}

    public func visibleRuns(
        forTask taskId: Int64,
        allRuns: [ChildRun],
        swappedInChildID: String? = nil,
        now: Date = Date()
    ) -> [ChildRun] {
        let ids = Self.nextBatch(allRuns: allRuns, now: now, swappedInChildID: swappedInChildID)
        return allRuns.filter { ids.contains($0.id) }
    }

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

    public static func agedOutPaneIDs(
        allRuns: [ChildRun],
        livePaneIDs: Set<String>,
        now: Date,
        swappedInChildID: String?
    ) -> Set<String> {
        livePaneIDs.subtracting(nextBatch(allRuns: allRuns, now: now, swappedInChildID: swappedInChildID))
    }
}
