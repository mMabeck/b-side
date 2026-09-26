import Foundation

/// The baseline commit a task's branch diverged from: the recorded
/// `baseCommit`, or (for a legacy task with none) the branch's own reflog
/// creation commit \u2014 same fallback `TaskWorktreeService.syncStatus` uses.
/// Shared by `SourceControlStore` (the "Committed on this branch" section)
/// and `ChangesOverlayStore` (the Changes overlay's Committed/All modes), so
/// both agree on what "this task's changes" means relative to.
enum TaskBaseline {
    static func resolved(task: TaskRecord, at worktreeURL: URL) async -> String? {
        if let baseCommit = task.baseCommit {
            return baseCommit
        }
        return await GitCLI.reflogCreationCommit(forBranch: task.branchName, at: worktreeURL)
    }
}
