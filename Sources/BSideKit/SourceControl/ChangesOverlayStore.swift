import Foundation
import Observation

/// Drives the "Changes" overlay: a VS Code–like file tree plus the selected
/// file's unified diff, over one of three combined views of what a task has
/// changed — see `Mode`. A separate store from `SourceControlStore`, with
/// its own watcher and refresh cycle, since the overlay is opened rarely and
/// its three modes are pointless work to run on every sidebar refresh.
@MainActor
@Observable
public final class ChangesOverlayStore {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case all
        case committed
        case uncommitted

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .all: return "All"
            case .committed: return "Committed"
            case .uncommitted: return "Uncommitted"
            }
        }
    }

    public enum LoadState: Equatable, Sendable {
        case idle
        case loaded
        case notARepository
        case error(String)
    }

    public private(set) var mode: Mode = .all
    public private(set) var loadState: LoadState = .idle
    public private(set) var files: [ChangesTreeFile] = []
    public private(set) var tree: [ChangesTreeNode] = []
    public private(set) var selectedPath: String?
    public private(set) var diffText: GitCLI.DiffText?
    public private(set) var diffErrorMessage: String?
    public private(set) var branchName: String?
    /// The ref the current mode's files are shown against: the task's
    /// baseline commit for `.all`/`.committed`, or `"HEAD"` for
    /// `.uncommitted`. `nil` only when `.all`/`.committed` couldn't resolve a
    /// baseline at all.
    public private(set) var baseRefLabel: String?

    public var totalAdded: Int { files.reduce(0) { $0 + ($1.linesAdded ?? 0) } }
    public var totalRemoved: Int { files.reduce(0) { $0 + ($1.linesRemoved ?? 0) } }

    private var task: TaskRecord?
    private var worktreeURL: URL? { task.map { URL(fileURLWithPath: $0.worktreePath) } }
    private var watcher: WorktreeWatcher?
    private var refreshGeneration = 0

    public init() {}

    /// Starts driving the overlay for `task`: resets to `.all` with no
    /// selection, and starts a watcher so it live-refreshes while open.
    public func present(task: TaskRecord) {
        self.task = task
        mode = .all
        selectedPath = nil
        diffText = nil
        diffErrorMessage = nil
        loadState = .idle
        files = []
        tree = []
        branchName = nil
        baseRefLabel = nil

        let url = URL(fileURLWithPath: task.worktreePath)
        let watcher = WorktreeWatcher(worktreeURL: url) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        self.watcher = watcher
        watcher.start()
        Task { await refresh() }
    }

    /// Stops the watcher; call when the overlay is dismissed so it doesn't
    /// keep refreshing (and spawning git processes) in the background.
    public func dismiss() {
        watcher?.stop()
        watcher = nil
        task = nil
    }

    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        Task { await refresh() }
    }

    /// Selects `path` and loads its diff. A no-op when `path` is already
    /// selected, so clicking the current row doesn't re-fetch its diff.
    public func select(_ path: String?) {
        guard path != selectedPath else { return }
        selectedPath = path
        Task { await loadDiff() }
    }

    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration

        guard let task, let worktreeURL else { return }

        guard await GitCLI.isGitRepository(at: worktreeURL) else {
            guard generation == refreshGeneration else { return }
            loadState = .notARepository
            files = []
            tree = []
            return
        }

        async let branchTask = GitCLI.currentBranch(at: worktreeURL)
        let baseline = await TaskBaseline.resolved(task: task, at: worktreeURL)
        guard generation == refreshGeneration else { return }

        let newFiles: [ChangesTreeFile]
        do {
            switch mode {
            case .all:
                baseRefLabel = baseline
                guard let baseline else {
                    newFiles = []
                    break
                }
                newFiles = try await GitCLI.workingTreeChanges(against: baseline, at: worktreeURL).map(Self.treeFile)
            case .committed:
                baseRefLabel = baseline
                guard let baseline else {
                    newFiles = []
                    break
                }
                newFiles = try await GitCLI.branchChanges(since: baseline, at: worktreeURL).map(Self.treeFile)
            case .uncommitted:
                baseRefLabel = "HEAD"
                newFiles = try await GitCLI.workingTreeChanges(against: "HEAD", at: worktreeURL).map(Self.treeFile)
            }
        } catch {
            guard generation == refreshGeneration else { return }
            loadState = .error(Self.describe(error))
            return
        }

        branchName = await branchTask
        guard generation == refreshGeneration else { return }

        files = newFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        tree = ChangesTreeBuilder.build(files)
        loadState = .loaded

        // Keep the current selection if it's still present; otherwise fall
        // back to the first file (VS Code's own behaviour when the selected
        // file drops out of the list). Either way, reload the diff: even a
        // preserved selection's content may have changed since the last
        // refresh, which is the whole point of live-refreshing this overlay.
        if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = files.first?.path
        }
        await loadDiff()
    }

    private static func treeFile(_ change: GitCLI.BranchFileChange) -> ChangesTreeFile {
        ChangesTreeFile(
            path: change.path,
            origPath: change.origPath,
            kind: change.kind,
            linesAdded: change.linesAdded,
            linesRemoved: change.linesRemoved,
            isBinary: change.isBinary
        )
    }

    private func loadDiff() async {
        guard let worktreeURL, let selectedPath, let file = files.first(where: { $0.path == selectedPath }) else {
            diffText = nil
            diffErrorMessage = nil
            return
        }
        let requestedPath = selectedPath
        let requestedMode = mode

        do {
            let diff: GitCLI.DiffText
            if file.kind == .untracked {
                diff = try await GitCLI.diffForUntracked(selectedPath, at: worktreeURL)
            } else {
                switch requestedMode {
                case .all, .uncommitted:
                    let ref = baseRefLabel ?? "HEAD"
                    diff = try await GitCLI.workingTreeDiff(for: selectedPath, against: ref, at: worktreeURL)
                case .committed:
                    guard let baseline = baseRefLabel else { return }
                    diff = try await GitCLI.branchDiff(for: selectedPath, since: baseline, at: worktreeURL)
                }
            }
            guard self.selectedPath == requestedPath, self.mode == requestedMode else { return }
            diffText = diff
            diffErrorMessage = nil
        } catch {
            guard self.selectedPath == requestedPath, self.mode == requestedMode else { return }
            diffText = nil
            diffErrorMessage = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? GitCLI.CommandError {
            return error.description
        }
        return String(describing: error)
    }
}
