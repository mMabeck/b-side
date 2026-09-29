import Foundation

/// Falls back to the branch's reflog creation commit for legacy tasks with no `baseCommit`, matching `TaskWorktreeService.syncStatus`.
enum TaskBaseline {
    static func resolved(task: TaskRecord, at worktreeURL: URL) async -> String? {
        if let baseCommit = task.baseCommit {
            return baseCommit
        }
        return await GitCLI.reflogCreationCommit(forBranch: task.branchName, at: worktreeURL)
    }
}
