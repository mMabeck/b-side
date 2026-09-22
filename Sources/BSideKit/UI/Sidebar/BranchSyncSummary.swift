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
}
