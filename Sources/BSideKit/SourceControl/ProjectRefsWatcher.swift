import CoreServices
import Foundation

/// Watches a project's git refs (`HEAD`, `refs/**`, `packed-refs`), not its
/// working tree, powering `ProjectsStore`'s live ahead/behind/merged re-check
/// from anywhere a branch or base ref moves.
///
/// Narrower than `WorktreeWatcher`: no working-tree file edits, only ref
/// changes, so it never fires on high-frequency agent file churn, and one instance per project suffices.
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

        // `HEAD` in the project's own (possibly private) git dir — cheap to
        // include and correct for the rarer detached-HEAD base case.
        gitDirStream = WorktreeWatcher.makeStream(paths: [gitDir.standardizedFileURL.path], latency: 0.3) { [weak self] paths in
            MainActor.assumeIsolated {
                let relevant = paths.contains { (($0 as NSString).lastPathComponent) == "HEAD" }
                guard relevant else { return }
                self?.scheduleRefresh()
            }
        }

        // Shared refs live in the common git dir, so a commit/merge from any worktree is caught here.
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
