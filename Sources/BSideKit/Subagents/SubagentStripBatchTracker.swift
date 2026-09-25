import Foundation

/// Decides which of a task's children (`SubagentFeedStore.runs(forTask:)`)
/// the strip currently shows.
///
/// A run is visible while it's active/blocked, and for a short linger after
/// it finishes (`lingerInterval` past `endedAt`) so its ✓/✗ is briefly
/// readable before the card disappears — unless that child's pane is
/// currently swapped into the main area, in which case it stays until the
/// user swaps back. Visibility is a pure function of the runs themselves
/// plus wall-clock time, so no batch membership needs to be remembered
/// across calls (`nextBatch` below is directly testable without an
/// instance).
///
/// `SubagentFeedStore` stays the single source of truth for run data; this
/// only derives which of its runs currently belong in the strip.
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

    /// Retained for callers that used to reset per-task batch memory on host
    /// teardown (`MainAreaView.closeHost`/`purgeHosts`); visibility no
    /// longer depends on any tracked state, so there is nothing to reset.
    public func reset(taskId: Int64) {}

    /// Pure visibility rule, directly testable: the set of run ids that
    /// belong in the strip right now.
    ///
    /// - Active/blocked runs are always visible.
    /// - A completed/failed run stays visible for `lingerInterval` past its
    ///   `endedAt`, so the ✓/✗ is briefly visible rather than the card
    ///   vanishing the instant it finishes.
    /// - A finished run whose child pane is currently swapped into view
    ///   (`swappedInChildID`) stays visible past the linger, until the user
    ///   swaps back to main.
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

    /// Live pane ids that should be torn down right now: ones whose card has
    /// aged out of `nextBatch`, so a finished child stops holding a
    /// `SubagentPaneStore.maxPanesPerTask` slot once its strip card is gone.
    public static func agedOutPaneIDs(
        allRuns: [ChildRun],
        livePaneIDs: Set<String>,
        now: Date,
        swappedInChildID: String?
    ) -> Set<String> {
        livePaneIDs.subtracting(nextBatch(allRuns: allRuns, now: now, swappedInChildID: swappedInChildID))
    }
}
