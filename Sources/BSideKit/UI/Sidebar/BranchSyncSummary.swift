import Foundation

/// Formats a task row's trailing branch-sync summary from the existing git
/// layer's `TaskWorktreeService.BranchSyncStatus`. Kept quiet and compact: a
/// clean, unmerged branch shows nothing at all.
public enum BranchSyncSummary {
    public static func text(ahead: Int, behind: Int, merged: Bool) -> String? {
        if merged { return "merged" }
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static func text(for status: TaskWorktreeService.BranchSyncStatus) -> String? {
        text(ahead: status.ahead, behind: status.behind, merged: status.merged)
    }

    /// Whether a task has work the base ref doesn't have yet: commits of its
    /// own beyond the base, or uncommitted edits sitting in its worktree.
    /// Never true at the same time as ``isEffectivelyMerged(_:)`` reads true,
    /// since uncommitted changes alone already forces that false.
    public static func hasPendingWork(ahead: Int, hasUncommittedChanges: Bool) -> Bool {
        ahead > 0 || hasUncommittedChanges
    }

    public static func hasPendingWork(for status: TaskWorktreeService.BranchSyncStatus) -> Bool {
        hasPendingWork(ahead: status.ahead, hasUncommittedChanges: status.hasUncommittedChanges)
    }

    /// The "Merged" badge's actual gate: the branch must be merged into its
    /// base ref *and* have no uncommitted changes sitting on top of it — a
    /// branch that's landed but has since gained local edits hasn't fully
    /// landed those edits too, so it must not read as done.
    public static func isEffectivelyMerged(_ status: TaskWorktreeService.BranchSyncStatus) -> Bool {
        status.merged && !status.hasUncommittedChanges
    }

    /// The quiet, non-actionable behind-only caption — kept separate from
    /// ``hasPendingWork(for:)`` since being behind the base ref isn't "pending
    /// work" of the task's own.
    public static func behindCaption(for status: TaskWorktreeService.BranchSyncStatus) -> String? {
        status.behind > 0 ? "↓\(status.behind)" : nil
    }

    /// VoiceOver label for the pending-work pill, e.g. "3 commits not
    /// merged, uncommitted changes". `nil` when there's nothing pending.
    public static func accessibilityLabel(ahead: Int, hasUncommittedChanges: Bool) -> String? {
        guard hasPendingWork(ahead: ahead, hasUncommittedChanges: hasUncommittedChanges) else { return nil }
        var parts: [String] = []
        if ahead > 0 {
            parts.append("\(ahead) commit\(ahead == 1 ? "" : "s") not merged")
        }
        if hasUncommittedChanges {
            parts.append("uncommitted changes")
        }
        return parts.joined(separator: ", ")
    }

    public static func accessibilityLabel(for status: TaskWorktreeService.BranchSyncStatus) -> String? {
        accessibilityLabel(ahead: status.ahead, hasUncommittedChanges: status.hasUncommittedChanges)
    }
}
