import AppKit
import Foundation
import Observation

/// Drives the Source Control sidebar (native-rewrite.md §7) for whichever
/// task is selected. One instance, retargeted (not recreated) via `setTask`.
///
/// Status loads first and publishes immediately; per-file line counts are a
/// slower second pass that fills in once it lands, so the sidebar never blocks its first paint.
@MainActor
@Observable
public final class SourceControlStore {
    public enum LoadState: Equatable {
        case idle
        case loaded
        case notARepository
        case error(String)
    }

    /// Unifies `GitCLI.FileChange` and `GitCLI.BranchFileChange` behind one shape the UI renders the same way.
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
    /// See `GitCLI.branchChanges`. Never reflects uncommitted work.
    public private(set) var branchChanges: [Row] = []

    public var commitMessage: String = ""
    public private(set) var isCommitting = false
    public private(set) var commitLog: [String] = []

    public struct AheadBehind: Equatable, Sendable {
        public let ahead: Int
        public let behind: Int
    }

    /// The Push button and History section are both hidden without a remote.
    public private(set) var hasRemote = false
    /// `nil` before the first refresh, or with no upstream yet (still shows the Push button).
    public private(set) var aheadBehind: AheadBehind?
    public private(set) var isPushing = false
    public private(set) var pushLog: [String] = []

    /// Most recent first, the History section. Same baseline as `branchChanges`.
    public private(set) var history: [GitCLI.CommitSummary] = []
    private static let historyLimit = 50

    /// Injected so tests can assert discard behaviour without a real Trash.
    @ObservationIgnored
    public var recycle: (@Sendable ([URL]) async -> Void) = { urls in
        guard !urls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { _, _ in continuation.resume() }
        }
    }

    @ObservationIgnored private var watcher: WorktreeWatcher?
    @ObservationIgnored private var refreshGeneration = 0
    /// Bumped only when `setTask` retargets to a different task, unlike
    /// `refreshGeneration`. `commit()`/`push()` check it before every write
    /// so output from a task switched away from can't land on the new task's state.
    @ObservationIgnored private var taskGeneration = 0
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
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

    /// No-op for the store's reset state when the worktree path is unchanged
    /// (aside from keeping the latest record for `baseCommit`); a path change tears down and starts fresh.
    public func setTask(_ newTask: TaskRecord?) {
        if newTask?.worktreePath == task?.worktreePath, newTask?.id == task?.id {
            task = newTask
            return
        }

        cancelCommit()
        cancelPush()
        taskGeneration += 1
        task = newTask
        commitMessage = ""
        commitLog = []
        pushLog = []
        isCommitting = false
        isPushing = false
        staged = []
        unstaged = []
        branchChanges = []
        history = []
        hasRemote = false
        aheadBehind = nil
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
            history = []
            hasRemote = false
            aheadBehind = nil
            return
        }

        guard await GitCLI.isGitRepository(at: worktreeURL) else {
            guard generation == refreshGeneration else { return }
            loadState = .notARepository
            staged = []
            unstaged = []
            branchChanges = []
            history = []
            hasRemote = false
            aheadBehind = nil
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

        let baseline = await TaskBaseline.resolved(task: task, at: worktreeURL)
        guard generation == refreshGeneration else { return }
        if let baseline, let branch = try? await GitCLI.branchChanges(since: baseline, at: worktreeURL) {
            guard generation == refreshGeneration else { return }
            branchChanges = branch.map { Row(branchChange: $0) }
        } else {
            branchChanges = []
        }

        async let originTask = GitCLI.originRemote(at: worktreeURL)
        async let aheadBehindTask = GitCLI.aheadBehind(at: worktreeURL)
        async let historyTask = try? GitCLI.history(since: baseline, limit: Self.historyLimit, at: worktreeURL)
        let origin = await originTask
        let remoteAheadBehind = await aheadBehindTask
        let branchHistory = await historyTask
        guard generation == refreshGeneration else { return }
        hasRemote = origin != nil
        aheadBehind = remoteAheadBehind.map { AheadBehind(ahead: $0.ahead, behind: $0.behind) }
        history = branchHistory ?? []
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

    /// Caps `diff --no-index` processes running at once; `GitCLI.lineCounts(forUntracked:)`
    /// itself skips line counts outright above `untrackedLineCountThreshold`.
    private static let maxConcurrentUntrackedDiffs = 8

    private static func untrackedLineCounts(_ paths: [String], at url: URL) async -> [String: GitCLI.LineCount] {
        await GitCLI.lineCounts(forUntracked: paths, at: url, maxConcurrent: maxConcurrentUntrackedDiffs)
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
        let paths = Self.expandedPaths(for: rows)
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

    /// An unstaged row's edits are reverted in the working tree only,
    /// leaving whatever's staged for the same path alone (VS Code semantics).
    /// Untracked rows go to the Trash via `recycle`, so discard is always
    /// recoverable. A staged row with a `HEAD` entry is only unstaged, never
    /// reverted, so its content isn't lost with no Trash copy; one with no
    /// `HEAD` entry (newly added, or a rename's new name) is unstaged and
    /// trashed instead. Conflicted rows are skipped: `restore` refuses unmerged paths.
    public func discard(_ rows: [Row]) async {
        guard let worktreeURL else { return }

        let untrackedRows = rows.filter { $0.kind == .untracked }

        let unstagedRows = rows.filter {
            $0.origin == .unstaged && $0.kind != .untracked && $0.kind != .conflicted
        }
        let unstagedPaths = Self.expandedPaths(for: unstagedRows)

        let stagedRows = rows.filter { $0.origin == .staged && $0.kind != .conflicted }
        let stagedHeadBacked = stagedRows.filter { $0.kind != .added && $0.kind != .renamed }
        let stagedHeadless = stagedRows.filter { $0.kind == .added || $0.kind == .renamed }

        do {
            if !unstagedPaths.isEmpty {
                try await GitCLI.discardWorktree(unstagedPaths, at: worktreeURL)
            }
            if !stagedHeadBacked.isEmpty {
                try await GitCLI.unstage(Self.expandedPaths(for: stagedHeadBacked), at: worktreeURL)
            }
            for row in stagedHeadless where row.kind == .renamed {
                if let origPath = row.origPath {
                    try await GitCLI.discardTracked([origPath], at: worktreeURL)
                }
            }
            let headlessPaths = stagedHeadless.map(\.path)
            if !headlessPaths.isEmpty {
                try await GitCLI.unstage(headlessPaths, at: worktreeURL)
            }
        } catch {
            loadState = .error(Self.describe(error))
            return
        }

        let toRecycle = untrackedRows + stagedHeadless
        if !toRecycle.isEmpty {
            await recycle(toRecycle.map { worktreeURL.appendingPathComponent($0.path) })
        }
        await refresh()
    }

    /// Plus `origPath` for a renamed row: discarding only the new name leaves the old name's deletion staged.
    private static func expandedPaths(for rows: [Row]) -> [String] {
        var paths: [String] = []
        for row in rows {
            paths.append(row.path)
            if row.kind == .renamed, let origPath = row.origPath {
                paths.append(origPath)
            }
        }
        return paths
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
            guard let task, let baseline = await TaskBaseline.resolved(task: task, at: worktreeURL) else {
                return GitCLI.DiffText(text: "", isBinary: false, isTruncated: false)
            }
            return try await GitCLI.branchDiff(for: row.path, origPath: row.origPath, since: baseline, at: worktreeURL)
        }
    }

    // MARK: - Commit

    /// `commitMessage` is only cleared on success, so a failed or cancelled commit leaves it visible to retry.
    public func commit() {
        guard let worktreeURL, !isCommitting, !isPushing, !staged.isEmpty else { return }
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = commitMessage
        let generation = taskGeneration
        isCommitting = true
        commitLog = []

        commitTask = Task { [weak self] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await line in stream {
                    guard generation == self.taskGeneration else { continue }
                    self.commitLog.append(line)
                }
            }
            do {
                try await GitCLI.commit(message: message, at: worktreeURL) { line in
                    continuation.yield(line)
                }
                continuation.finish()
                _ = await consumer.value
                guard generation == self.taskGeneration else { return }
                self.commitMessage = ""
                await self.refresh()
            } catch {
                continuation.finish()
                _ = await consumer.value
            }
            guard generation == self.taskGeneration else { return }
            self.isCommitting = false
        }
    }

    public func cancelCommit() {
        commitTask?.cancel()
    }

    // MARK: - Push

    /// Sets the upstream if none exists yet. Mutually exclusive with committing.
    public func push() {
        guard let worktreeURL, !isPushing, !isCommitting else { return }

        let generation = taskGeneration
        isPushing = true
        pushLog = []

        pushTask = Task { [weak self] in
            guard let self else { return }
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await line in stream {
                    guard generation == self.taskGeneration else { continue }
                    self.pushLog.append(line)
                }
            }
            do {
                try await GitCLI.push(at: worktreeURL) { line in
                    continuation.yield(line)
                }
                continuation.finish()
                _ = await consumer.value
                if generation == self.taskGeneration {
                    await self.refresh()
                }
            } catch {
                continuation.finish()
                _ = await consumer.value
            }
            guard generation == self.taskGeneration else { return }
            self.isPushing = false
        }
    }

    public func cancelPush() {
        pushTask?.cancel()
    }

    // MARK: - History

    public func diffText(forCommit sha: String) async throws -> GitCLI.DiffText {
        guard let worktreeURL else {
            return GitCLI.DiffText(text: "", isBinary: false, isTruncated: false)
        }
        return try await GitCLI.showCommit(sha, at: worktreeURL)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? GitCLI.CommandError {
            return error.description
        }
        return String(describing: error)
    }
}
