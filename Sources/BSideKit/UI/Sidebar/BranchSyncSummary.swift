import Foundation

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

    public static func hasPendingWork(ahead: Int, hasUncommittedChanges: Bool) -> Bool {
        ahead > 0 || hasUncommittedChanges
    }

    public static func hasPendingWork(for status: TaskWorktreeService.BranchSyncStatus) -> Bool {
        hasPendingWork(ahead: status.ahead, hasUncommittedChanges: status.hasUncommittedChanges)
    }

    public static func isEffectivelyMerged(_ status: TaskWorktreeService.BranchSyncStatus) -> Bool {
        status.merged && !status.hasUncommittedChanges
    }

    public static func behindCaption(for status: TaskWorktreeService.BranchSyncStatus) -> String? {
        status.behind > 0 ? "↓\(status.behind)" : nil
    }

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
