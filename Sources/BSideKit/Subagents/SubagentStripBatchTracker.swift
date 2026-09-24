import Foundation

/// Decides which of a task's children (`SubagentFeedStore.runs(forTask:)`)
/// the strip currently shows — "the current batch" per native-rewrite.md's
/// card lifecycle: finished cards stay (dimmed) until a new run begins after
/// every earlier run had finished, at which point the old finished ones
/// clear and the new batch starts fresh.
///
/// `SubagentFeedStore` stays the single source of truth for run data; this
/// only tracks *which* of its runs currently belong in the strip's batch, so
/// a completed run isn't dropped the instant it finishes (it should still be
/// visible, dimmed) but also doesn't accumulate forever across unrelated
/// later fan-outs.
@MainActor
@Observable
public final class SubagentStripBatchTracker {
    private var batchByTask: [Int64: Set<String>] = [:]

    public init() {}

    /// Runs to show for `taskId`'s strip right now: reconciles the tracked
    /// batch against the feed's current runs (dropping any batch member the
    /// feed no longer has, e.g. after `SubagentFeedStore` itself clears) and
    /// advances the batch per `Self.nextBatch` before filtering.
    public func visibleRuns(forTask taskId: Int64, allRuns: [ChildRun]) -> [ChildRun] {
        let current = batchByTask[taskId] ?? []
        let next = Self.nextBatch(currentBatch: current, allRuns: allRuns)
        // Only write when the batch actually changed: this is called from
        // view bodies (`TaskTerminalAreaView`), and `@Observable` fires a
        // change notification on every assignment regardless of whether the
        // value moved — with two or more mounted task areas, an
        // unconditional write here re-invalidated every reader of
        // `batchByTask` (including the very body doing the writing) on
        // every render, driving continuous re-render/CPU use.
        if next != current {
            batchByTask[taskId] = next
        }
        return allRuns.filter { next.contains($0.id) }
    }

    public func reset(taskId: Int64) {
        batchByTask.removeValue(forKey: taskId)
    }

    /// Pure batch-advance rule, directly testable:
    ///
    /// - No runs at all yet: batch is empty.
    /// - Every run currently in the batch has finished (completed/failed)
    ///   and at least one run outside the batch exists: the old batch is
    ///   dropped entirely and the new batch is exactly the runs outside it
    ///   (a fresh fan-out replaces a fully-finished one, not accumulates
    ///   beside it).
    /// - Otherwise: the batch grows to include every run seen so far (a
    ///   still-active batch picks up concurrent siblings as they start).
    static func nextBatch(currentBatch: Set<String>, allRuns: [ChildRun]) -> Set<String> {
        let allIDs = Set(allRuns.map(\.id))
        guard !currentBatch.isEmpty else { return allIDs }

        let byID = Dictionary(uniqueKeysWithValues: allRuns.map { ($0.id, $0) })
        let currentRuns = currentBatch.compactMap { byID[$0] }
        let allCurrentFinished = !currentRuns.isEmpty
            && currentRuns.allSatisfy { $0.state == .completed || $0.state == .failed }
        let newIDs = allIDs.subtracting(currentBatch)

        if allCurrentFinished, !newIDs.isEmpty {
            return newIDs
        }
        return allIDs
    }
}
