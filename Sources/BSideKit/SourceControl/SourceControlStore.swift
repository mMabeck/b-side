import AppKit
import Foundation
import Observation

/// Drives the Source Control sidebar (native-rewrite.md §7) for whichever
/// task is selected. One instance lives for the lifetime of `RightSidebarView`
/// and is retargeted — not recreated — as the selection changes, via
/// `setTask`.
///
/// Status loads first and publishes immediately; per-file added/removed line
/// counts are a second, slower pass (numstat, plus one `diff --no-index` per
/// untracked file) that fills in once it lands, so the sidebar never blocks
/// its first paint on diff stats. See `GitCLI+Changes.swift`.
@MainActor
@Observable
public final class SourceControlStore {
    public enum LoadState: Equatable {
        case idle
        case loaded
        case notARepository
        case error(String)
    }

    /// One row in the sidebar, unifying `GitCLI.FileChange` (staged/unstaged)
    /// and `GitCLI.BranchFileChange` (committed-on-branch) behind a single
    /// shape the UI renders the same way.
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Origin: Equatable, Sendable {
            case staged
            case unstaged
            case branch
        }

        public let id: String
        public let path: String
        public let origPath: String?
        public let kind: GitCLI.FileChange.Kind
        public let origin: Origin
        public var linesAdded: Int?
        public var linesRemoved: Int?
        public var isBinary: Bool

        public var displayName: String { (path as NSString).lastPathComponent }

        public var directory: String {
            (path as NSString).deletingLastPathComponent
        }

        init(fileChange: GitCLI.FileChange, origin: Origin) {
            self.id = "\(origin == .staged ? "staged" : "unstaged"):\(fileChange.path)"
            self.path = fileChange.path
            self.origPath = fileChange.origPath
            self.kind = fileChange.kind
            self.origin = origin
            self.linesAdded = fileChange.linesAdded
            self.linesRemoved = fileChange.linesRemoved
            self.isBinary = fileChange.isBinary
        }

        init(branchChange: GitCLI.BranchFileChange) {
            self.id = "branch:\(branchChange.path)"
            self.path = branchChange.path
            self.origPath = branchChange.origPath
            self.kind = branchChange.kind
            self.origin = .branch
            self.linesAdded = branchChange.linesAdded
            self.linesRemoved = branchChange.linesRemoved
            self.isBinary = branchChange.isBinary
        }
    }

    public private(set) var task: TaskRecord?
    public private(set) var loadState: LoadState = .idle
    public private(set) var staged: [Row] = []
    public private(set) var unstaged: [Row] = []
    /// Everything committed on this task's branch since it diverged from
    /// base — see `GitCLI.branchChanges`. Never reflects uncommitted work.
    public private(set) var branchChanges: [Row] = []

    public var commitMessage: String = ""
    public private(set) var isCommitting = false
    public private(set) var commitLog: [String] = []

    /// Moves untracked files to the Trash. Injected so tests can assert
    /// discard behaviour without touching a real Trash.
    @ObservationIgnored
    public var recycle: (@Sendable ([URL]) async -> Void) = { urls in
        guard !urls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { _, _ in continuation.resume() }
        }
    }

    @ObservationIgnored private var watcher: WorktreeWatcher?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    public init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    private var worktreeURL: URL? {
        task.map { URL(fileURLWithPath: $0.worktreePath) }
    }

    /// Retargets the store at `newTask`. A no-op for the store's own reset
    /// state when the worktree path is unchanged (e.g. a re-selection of the
    /// same task, or a `TaskRecord` update that only touched unrelated
    /// fields), aside from keeping the latest record around for
    /// `baseCommit`. A worktree path change tears down the old watcher,
    /// clears all state, and starts fresh.
    public func setTask(_ newTask: TaskRecord?) {
        if newTask?.worktreePath == task?.worktreePath, newTask?.id == task?.id {
            task = newTask
            return
        }

        cancelCommit()
        task = newTask
        commitMessage = ""
        commitLog = []
        staged = []
        unstaged = []
        branchChanges = []
        loadState = .idle
        watcher?.stop()
        watcher = nil

        guard let newTask else { return }
        let url = URL(fileURLWithPath: newTask.worktreePath)
        let watcher = WorktreeWatcher(worktreeURL: url) { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        self.watcher = watcher
        watcher.start()
        Task { await refresh() }
    }

    // MARK: - Refresh

    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration

        guard let task, let worktreeURL else {
            loadState = .idle
            staged = []
            unstaged = []
            branchChanges = []
            return
        }

        guard await GitCLI.isGitRepository(at: worktreeURL) else {
            guard generation == refreshGeneration else { return }
            loadState = .notARepository
            staged = []
            unstaged = []
            branchChanges = []
            return
        }

        let changes: [GitCLI.FileChange]
        do {
            changes = try await GitCLI.changedFiles(at: worktreeURL)
        } catch {
            guard generation == refreshGeneration else { return }
            loadState = .error(Self.describe(error))
            return
        }
        guard generation == refreshGeneration else { return }
        staged = changes.filter { $0.area == .staged }.map { Row(fileChange: $0, origin: .staged) }
        unstaged = changes.filter { $0.area == .unstaged }.map { Row(fileChange: $0, origin: .unstaged) }
        loadState = .loaded

        let untrackedPaths = unstaged.filter { $0.kind == .untracked }.map(\.path)
        async let countsTask: (staged: [String: GitCLI.LineCount], unstaged: [String: GitCLI.LineCount])? = try? GitCLI.lineCounts(at: worktreeURL)
        async let untrackedCountsTask = Self.untrackedLineCounts(untrackedPaths, at: worktreeURL)
        let counts = await countsTask
        let untrackedCounts = await untrackedCountsTask
        guard generation == refreshGeneration else { return }
        if let counts {
            applyLineCounts(staged: counts.staged, unstaged: counts.unstaged, untracked: untrackedCounts)
        }

        let baseline = await Self.resolvedBaseline(task: task, at: worktreeURL)
        guard generation == refreshGeneration else { return }
        if let baseline, let branch = try? await GitCLI.branchChanges(since: baseline, at: worktreeURL) {
            guard generation == refreshGeneration else { return }
            branchChanges = branch.map { Row(branchChange: $0) }
        } else {
            branchChanges = []
        }
    }

    private func applyLineCounts(
        staged stagedCounts: [String: GitCLI.LineCount],
        unstaged unstagedCounts: [String: GitCLI.LineCount],
        untracked untrackedCounts: [String: GitCLI.LineCount]
    ) {
        staged = staged.map { row in
            var row = row
            if let count = stagedCounts[row.path] {
                row.linesAdded = count.added
                row.linesRemoved = count.removed
                row.isBinary = row.isBinary || count.isBinary
            }
            return row
        }
        unstaged = unstaged.map { row in
            var row = row
            if row.kind == .untracked {
                if let count = untrackedCounts[row.path] {
                    row.linesAdded = count.added
                    row.linesRemoved = count.removed
                    row.isBinary = count.isBinary
                }
            } else if let count = unstagedCounts[row.path] {
                row.linesAdded = count.added
                row.linesRemoved = count.removed
                row.isBinary = row.isBinary || count.isBinary
            }
            return row
        }
    }

    private static func untrackedLineCounts(_ paths: [String], at url: URL) async -> [String: GitCLI.LineCount] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: GitCLI.LineCount] = [:]
        await withTaskGroup(of: (String, GitCLI.LineCount?).self) { group in
            for path in paths {
                group.addTask {
                    let count = try? await GitCLI.lineCount(forUntracked: path, at: url)
                    return (path, count)
                }
            }
            for await (path, count) in group {
                if let count {
                    result[path] = count
                }
            }
        }
        return result
    }

    /// The baseline for the branch view: the recorded `baseCommit`, or (for a
    /// legacy task with none) the branch's own reflog creation commit — same
    /// fallback `TaskWorktreeService.syncStatus` uses.
    private static func resolvedBaseline(task: TaskRecord, at worktreeURL: URL) async -> String? {
        if let baseCommit = task.baseCommit {
            return baseCommit
        }
        return await GitCLI.reflogCreationCommit(forBranch: task.branchName, at: worktreeURL)
    }

    // MARK: - Operations

    public func stage(_ rows: [Row]) async {
        guard let worktreeURL else { return }
        let paths = rows.map(\.path)
        guard !paths.isEmpty else { return }
        do {
            try await GitCLI.stage(paths, at: worktreeURL)
        } catch {
            loadState = .error(Self.describe(error))
            return
        }
        await refresh()
    }

    public func stageAll() async {
        guard let worktreeURL else { return }
        do {
            try await GitCLI.stageAll(at: worktreeURL)
        } catch {
            loadState = .error(Self.describe(error))
            return
        }
        await refresh()
    }

    public func unstage(_ rows: [Row]) async {
        guard let worktreeURL else { return }
        let paths = rows.map(\.path)
        guard !paths.isEmpty else { return }
        do {
            try await GitCLI.unstage(paths, at: worktreeURL)
        } catch {
            loadState = .error(Self.describe(error))
            return
        }
        await refresh()
    }

    public func unstageAll() async {
        guard let worktreeURL else { return }
        do {
            try await GitCLI.unstageAll(at: worktreeURL)
        } catch {
            loadState = .error(Self.describe(error))
            return
        }
        await refresh()
    }

    /// Discards `rows`. Tracked files are reverted to `HEAD` in both the
    /// index and the working tree; untracked files go to the Trash via
    /// `recycle` rather than `rm`, so a discard is always recoverable.
    public func discard(_ rows: [Row]) async {
        guard let worktreeURL else { return }
        let trackedPaths = rows.filter { $0.kind != .untracked }.map(\.path)
        let untrackedRows = rows.filter { $0.kind == .untracked }
        do {
            if !trackedPaths.isEmpty {
                try await GitCLI.discardTracked(trackedPaths, at: worktreeURL)
            }
        } catch {
            loadState = .error(Self.describe(error))
            return
        }
        if !untrackedRows.isEmpty {
            await recycle(untrackedRows.map { worktreeURL.appendingPathComponent($0.path) })
        }
        await refresh()
    }

    public func addToGitignore(_ row: Row) async {
        guard let worktreeURL else { return }
        do {
            try GitCLI.addToGitignore(row.path, at: worktreeURL)
        } catch {
            loadState = .error(Self.describe(error))
            return
        }
        await refresh()
    }

    // MARK: - Diff

    public func diffText(for row: Row) async throws -> GitCLI.DiffText {
        guard let worktreeURL else {
            return GitCLI.DiffText(text: "", isBinary: false, isTruncated: false)
        }
        switch row.origin {
        case .staged:
            return try await GitCLI.diff(for: row.path, staged: true, at: worktreeURL)
        case .unstaged:
            if row.kind == .untracked {
                return try await GitCLI.diffForUntracked(row.path, at: worktreeURL)
            }
            return try await GitCLI.diff(for: row.path, staged: false, at: worktreeURL)
        case .branch:
            guard let task, let baseline = await Self.resolvedBaseline(task: task, at: worktreeURL) else {
                return GitCLI.DiffText(text: "", isBinary: false, isTruncated: false)
            }
            return try await GitCLI.branchDiff(for: row.path, since: baseline, at: worktreeURL)
        }
    }

    // MARK: - Commit

    /// Commits `commitMessage` against the currently staged changes,
    /// streaming hook output into `commitLog` as it arrives. `commitMessage`
    /// is only cleared on success, so a failed commit (or one killed by
    /// `cancelCommit`) leaves the message and log both visible for the user
    /// to read and retry.
    public func commit() {
        guard let worktreeURL, !isCommitting, !staged.isEmpty else { return }
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = commitMessage
        isCommitting = true
        commitLog = []

        commitTask = Task { [weak self] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await line in stream {
                    self.commitLog.append(line)
                }
            }
            do {
                try await GitCLI.commit(message: message, at: worktreeURL) { line in
                    continuation.yield(line)
                }
                continuation.finish()
                _ = await consumer.value
                await MainActor.run { self.commitMessage = "" }
                await self.refresh()
            } catch {
                continuation.finish()
                _ = await consumer.value
            }
            await MainActor.run { self.isCommitting = false }
        }
    }

    public func cancelCommit() {
        commitTask?.cancel()
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? GitCLI.CommandError {
            return error.description
        }
        return String(describing: error)
    }
}
