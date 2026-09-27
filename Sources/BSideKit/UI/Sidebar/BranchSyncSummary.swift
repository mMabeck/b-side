import Foundation

/// Formats a task row's trailing branch-sync summary. A clean, unmerged branch shows nothing at all.
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

    /// Never true alongside ``isEffectivelyMerged(_:)``, since uncommitted changes alone forces that false.
    public static func hasPendingWork(ahead: Int, hasUncommittedChanges: Bool) -> Bool {
        ahead > 0 || hasUncommittedChanges
    }

    public static func hasPendingWork(for status: TaskWorktreeService.BranchSyncStatus) -> Bool {
        hasPendingWork(ahead: status.ahead, hasUncommittedChanges: status.hasUncommittedChanges)
    }

    /// The "Merged" badge's gate: merged into base *and* no uncommitted changes on top.
    public static func isEffectivelyMerged(_ status: TaskWorktreeService.BranchSyncStatus) -> Bool {
        status.merged && !status.hasUncommittedChanges
    }

    /// Kept separate from ``hasPendingWork(for:)``: being behind base isn't "pending work" of the task's own.
    public static func behindCaption(for status: TaskWorktreeService.BranchSyncStatus) -> String? {
        status.behind > 0 ? "↓\(status.behind)" : nil
    }

    /// E.g. "3 commits not merged, uncommitted changes". `nil` when nothing pending.
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
