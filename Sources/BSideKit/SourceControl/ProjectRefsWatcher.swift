import CoreServices
import Foundation

/// Watches a project's git refs — `HEAD`, `refs/**`, and `packed-refs` —
/// without watching its working tree. Powers `ProjectsStore`'s live re-check
/// of every task's ahead/behind/merged status when a task branch gains
/// commits or the base branch moves, from anywhere: a terminal commit in a
/// task's worktree, a fetch, a merge run from outside the app entirely.
///
/// Deliberately narrower than `WorktreeWatcher`: a task row's sync status
/// doesn't need to react to working-tree file edits (`WorktreeWatcher`
/// already covers those, per-task, for the Source Control sidebar), only to
/// ref changes — so this never fires on the high-frequency file churn a
/// running agent produces, and one instance per *project* is enough rather
/// than one per task.
@MainActor
final class ProjectRefsWatcher {
    private let projectURL: URL
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    nonisolated(unsafe) private var gitDirStream: FSEventStreamRef?
    nonisolated(unsafe) private var commonGitDirStream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    init(projectURL: URL, debounceInterval: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.projectURL = projectURL
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        if let gitDirStream {
            FSEventStreamStop(gitDirStream)
            FSEventStreamInvalidate(gitDirStream)
            FSEventStreamRelease(gitDirStream)
        }
        if let commonGitDirStream {
            FSEventStreamStop(commonGitDirStream)
            FSEventStreamInvalidate(commonGitDirStream)
            FSEventStreamRelease(commonGitDirStream)
        }
    }

    func start() {
        stop()
        guard let gitDir = WorktreeWatcher.resolveGitDir(forWorktree: projectURL) else { return }

        // `HEAD` in the project's own (possibly private, for a linked
        // worktree) git dir — not relevant to ahead/behind against a named
        // base ref, but cheap to include and correct for the rarer case of a
        // detached-HEAD base.
        gitDirStream = WorktreeWatcher.makeStream(paths: [gitDir.standardizedFileURL.path], latency: 0.3) { [weak self] paths in
            MainActor.assumeIsolated {
                let relevant = paths.contains { (($0 as NSString).lastPathComponent) == "HEAD" }
                guard relevant else { return }
                self?.scheduleRefresh()
            }
        }

        // `refs/heads`, `refs/remotes`, and `packed-refs` live in the
        // *common* git dir shared by every worktree — the same distinction
        // `WorktreeWatcher` draws — so a commit or merge made from any task's
        // worktree, or from a terminal in the project root itself, is caught
        // here regardless of which worktree it happened in.
        if let commonGitDir = WorktreeWatcher.resolveCommonGitDir(forGitDir: gitDir) {
            commonGitDirStream = WorktreeWatcher.makeStream(paths: [commonGitDir.standardizedFileURL.path], latency: 0.3) { [weak self] paths in
                MainActor.assumeIsolated {
                    let relevant = paths.contains { WorktreeWatcher.isRelevantCommonGitDirPath($0) }
                    guard relevant else { return }
                    self?.scheduleRefresh()
                }
            }
        }
    }

    func stop() {
        if let gitDirStream {
            FSEventStreamStop(gitDirStream)
            FSEventStreamInvalidate(gitDirStream)
            FSEventStreamRelease(gitDirStream)
            self.gitDirStream = nil
        }
        if let commonGitDirStream {
            FSEventStreamStop(commonGitDirStream)
            FSEventStreamInvalidate(commonGitDirStream)
            FSEventStreamRelease(commonGitDirStream)
            self.commonGitDirStream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
