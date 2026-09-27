import Foundation
import OSLog

/// Implements "Branches and worktrees" (native rewrite plan §4): creating a task's
/// branch and worktree, copying in ignored files a worktree needs, running setup
/// commands, and tearing worktrees down again. Pure git/filesystem orchestration —
/// callers own persisting the result to the database.
public enum TaskWorktreeService {
    static let logger = Logger(subsystem: "dev.mabeck.bside", category: "task-worktree")

    public enum ServiceError: Error, Sendable, CustomStringConvertible {
        case branchAlreadyCheckedOut(branch: String, path: String)
        case commandFailed(command: String, status: Int32)

        public var description: String {
            switch self {
            case .branchAlreadyCheckedOut(let branch, let path):
                return "Branch '\(branch)' is already checked out at \(path)"
            case .commandFailed(let command, let status):
                return "Command failed (\(status)): \(command)"
            }
        }
    }

    /// Annotated with where it's already checked out, if it is — git refuses
    /// to check out a branch twice, so this must surface up front, not as a failure.
    public struct BranchOption: Identifiable, Sendable, Equatable {
        public let name: String
        public let checkedOutAt: String?
        public var id: String { name }
        public var isCheckedOut: Bool { checkedOutAt != nil }

        public init(name: String, checkedOutAt: String? = nil) {
            self.name = name
            self.checkedOutAt = checkedOutAt
        }
    }

    public struct WorktreeSetupResult: Sendable, Equatable {
        public let branchName: String
        public let branchCreatedByApp: Bool
        public let worktreePath: String
        public let copiedIgnoredFiles: [String]
        /// The baseline `TaskRecord.baseCommit` is persisted from, so `syncStatus`
        /// can tell "no commits yet" apart from "merged". `nil` only if `rev-parse` fails outright.
        public let baseCommit: String?
    }

    public struct BranchSyncStatus: Sendable, Equatable {
        public let ahead: Int
        public let behind: Int
        public let merged: Bool
        /// Either the one passed in, or a reflog fallback for a legacy task
        /// with no recorded `baseCommit`. Callers should persist this back so the fallback isn't repeated.
        public let resolvedBaseCommit: String?
        /// A `merged` branch with uncommitted edits on top hasn't actually
        /// landed everything; callers must never show "Merged" while this is true.
        public let hasUncommittedChanges: Bool

        public init(ahead: Int, behind: Int, merged: Bool, resolvedBaseCommit: String? = nil, hasUncommittedChanges: Bool = false) {
            self.ahead = ahead
            self.behind = behind
            self.merged = merged
            self.resolvedBaseCommit = resolvedBaseCommit
            self.hasUncommittedChanges = hasUncommittedChanges
        }
    }

    // MARK: - Branch discovery

    /// Local branches for `project`, each annotated with the worktree it's already
    /// checked out in, if any.
    public static func availableBranches(for project: Project) async throws -> [BranchOption] {
        let projectURL = URL(fileURLWithPath: project.path)
        let branches = try await GitCLI.localBranches(at: projectURL)
        let worktrees = try await GitCLI.worktrees(at: projectURL)

        var checkedOutPaths: [String: String] = [:]
        for worktree in worktrees {
            if let branch = worktree.branch {
                checkedOutPaths[branch] = worktree.path
            }
        }

        return branches.map { branch in
            BranchOption(name: branch, checkedOutAt: checkedOutPaths[branch])
        }
    }

    /// Candidate base refs for cutting a new branch from: local branches first,
    /// then remote-tracking branches (e.g. `origin/main`), so a base that only
    /// exists on the remote is still offered.
    public static func availableBaseRefs(for project: Project) async throws -> [String] {
        let projectURL = URL(fileURLWithPath: project.path)
        let local = try await GitCLI.localBranches(at: projectURL)
        let remote = try await GitCLI.remoteTrackingBranches(at: projectURL)
        return local + remote
    }

    // MARK: - Creation

    /// Slugifies a task name into something safe for branch names and directory
    /// names: lowercase, alphanumerics separated by single hyphens.
    public static func slug(forTaskName name: String) -> String {
        let lowered = name.lowercased()
        var result = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen && !result.isEmpty {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "task" : result
    }

    /// The sibling worktree directory for `projectPath` and a given task slug:
    /// `<projectPath>-worktrees/<slug>`, outside the repository itself.
    public static func worktreePath(forProjectAt projectPath: String, slug: String) -> String {
        let projectURL = URL(fileURLWithPath: projectPath)
        let siblingRoot = projectURL.deletingLastPathComponent()
            .appendingPathComponent("\(projectURL.lastPathComponent)-worktrees")
        return siblingRoot.appendingPathComponent(slug).path
    }

    /// Bounds the dedupe loop so a pathological filesystem/branch state can't spin it forever.
    static let maxUniqueSlugAttempts = 1000

    /// `<adjective>-<noun>-<4 hex chars>`, e.g. `quiet-otter-3f9a` — a
    /// permanent, content-free identifier since the worktree directory is
    /// never renamed (see `TaskAutoRenameService`).
    static func randomTaskSlug() -> String {
        let hexDigits = Array("0123456789abcdef")
        let suffix = String((0..<4).map { _ in hexDigits.randomElement()! })
        return "\(slugAdjectives.randomElement()!)-\(slugNouns.randomElement()!)-\(suffix)"
    }

    static let slugAdjectives = [
        "amber", "bold", "brave", "brisk", "calm", "clever", "cosy", "crisp",
        "dapper", "eager", "fancy", "fleet", "fond", "gentle", "glad", "golden",
        "grand", "happy", "hardy", "hazel", "humble", "jolly", "keen", "kind",
        "lively", "lucky", "mellow", "merry", "mighty", "misty", "nimble", "noble",
        "patient", "plucky", "polite", "proud", "quick", "quiet", "rapid", "ready",
        "rosy", "rustic", "sandy", "shiny", "silent", "silver", "sleek", "snowy",
        "solid", "spry", "steady", "stout", "sunny", "swift", "tidy", "tranquil",
        "vivid", "warm", "wise", "witty", "young", "zany", "zesty", "breezy",
    ]

    static let slugNouns = [
        "badger", "beacon", "birch", "bison", "brook", "canyon", "cedar", "comet",
        "coral", "crane", "delta", "dune", "ember", "falcon", "fern", "finch",
        "fjord", "fox", "glacier", "harbor", "hawk", "heron", "island", "lark",
        "lynx", "maple", "meadow", "mesa", "moose", "moth", "nebula", "oak",
        "orca", "otter", "owl", "panda", "pebble", "pine", "plover", "prairie",
        "puffin", "quartz", "raven", "reef", "ridge", "river", "robin", "saturn",
        "sparrow", "spruce", "summit", "swan", "thistle", "tiger", "tundra", "valley",
        "walrus", "willow", "wren", "yak", "zebra", "aurora", "heath", "lagoon",
    ]

    /// Suffixes with `-2`, `-3`, … so repeated task names get distinct worktrees instead of colliding.
    static func uniqueSlug(forProjectAt projectPath: String, baseSlug: String) async -> String {
        let projectURL = URL(fileURLWithPath: projectPath)
        var candidate = baseSlug
        var suffix = 2
        for _ in 0..<maxUniqueSlugAttempts {
            let pathTaken = FileManager.default.fileExists(atPath: worktreePath(forProjectAt: projectPath, slug: candidate))
            let branchTaken = (try? await GitCLI.branchExists("task/\(candidate)", at: projectURL)) ?? false
            if !pathTaken && !branchTaken { return candidate }
            candidate = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// If `existingBranch` is given, a worktree is attached to it instead of
    /// creating one, after confirming it isn't checked out elsewhere. If
    /// `useWorktree` is false, the task runs in-place. `baseSlugOverride`, if
    /// given, replaces the slug derived from `taskName` (e.g. for a blank-name task).
    @discardableResult
    public static func createWorktree(
        for project: Project,
        taskName: String,
        baseRef: String? = nil,
        existingBranch: String? = nil,
        useWorktree: Bool = true,
        setupCommand: String? = nil,
        baseSlugOverride: String? = nil,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> WorktreeSetupResult {
        let projectURL = URL(fileURLWithPath: project.path)

        guard useWorktree else {
            let branch = await GitCLI.currentBranch(at: projectURL) ?? project.baseRef
            let baseCommit = try? await GitCLI.revParse(branch, at: projectURL)
            return WorktreeSetupResult(
                branchName: branch,
                branchCreatedByApp: false,
                worktreePath: project.path,
                copiedIgnoredFiles: [],
                baseCommit: baseCommit
            )
        }

        let baseSlug = baseSlugOverride ?? slug(forTaskName: taskName)
        let taskSlug = await uniqueSlug(forProjectAt: project.path, baseSlug: baseSlug)
        let worktreePathString = worktreePath(forProjectAt: project.path, slug: taskSlug)
        let worktreeURL = URL(fileURLWithPath: worktreePathString)

        let branchName: String
        let branchCreatedByApp: Bool

        if let existingBranch {
            let worktrees = try await GitCLI.worktrees(at: projectURL)
            if let existing = worktrees.first(where: { $0.branch == existingBranch }) {
                throw ServiceError.branchAlreadyCheckedOut(branch: existingBranch, path: existing.path)
            }
            branchName = existingBranch
            branchCreatedByApp = false
            try await GitCLI.addWorktree(at: worktreeURL, existingBranch: existingBranch, in: projectURL)
        } else {
            let resolvedBaseRef = baseRef ?? project.baseRef
            branchName = "task/\(taskSlug)"
            branchCreatedByApp = true
            try await GitCLI.addWorktree(at: worktreeURL, newBranch: branchName, from: resolvedBaseRef, in: projectURL)
        }

        let baseCommit = try? await GitCLI.revParse(branchName, at: worktreeURL)
        let copied = try await copyIgnoredFiles(from: projectURL, to: worktreeURL)

        if let setupCommand, !setupCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            try await runCommand(setupCommand, in: worktreeURL, onOutput: onOutput)
        }

        return WorktreeSetupResult(
            branchName: branchName,
            branchCreatedByApp: branchCreatedByApp,
            worktreePath: worktreePathString,
            copiedIgnoredFiles: copied,
            baseCommit: baseCommit
        )
    }

    /// Returns the relative paths copied.
    @discardableResult
    public static func copyIgnoredFiles(from projectURL: URL, to worktreeURL: URL) async throws -> [String] {
        let relativePaths = try await GitCLI.looseIgnoredFiles(at: projectURL)
        let fileManager = FileManager.default
        var copied: [String] = []
        for relativePath in relativePaths {
            let source = projectURL.appendingPathComponent(relativePath)
            let destination = worktreeURL.appendingPathComponent(relativePath)
            let destinationDirectory = destination.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                copied.append(relativePath)
            } catch {
                logger.error(
                    "Failed to copy ignored file \(relativePath, privacy: .public): \(error, privacy: .public)"
                )
            }
        }
        return copied
    }

    /// Runs a project/task command (setup or teardown) in `directory`, streaming
    /// output to `onOutput`.
    public static func runCommand(
        _ command: String,
        in directory: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        do {
            try await StreamingProcessRunner.run(command: command, in: directory, onOutput: onOutput)
        } catch let error as StreamingProcessRunner.NonZeroExit {
            throw ServiceError.commandFailed(command: error.command, status: error.status)
        }
    }

    // MARK: - Removal

    /// Optionally removes the worktree (teardown, then prune), never touches the branch.
    public static func archiveWorktree(
        project: Project,
        worktreePath: String,
        removeWorktree: Bool,
        teardownCommand: String?,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard removeWorktree, worktreePath != project.path else { return }
        try await teardownAndRemoveWorktree(
            project: project,
            worktreePath: worktreePath,
            teardownCommand: teardownCommand,
            onOutput: onOutput
        )
    }

    /// `deleteLocalBranch` should only be offered when the app created it.
    public static func deleteTask(
        project: Project,
        worktreePath: String,
        branchName: String,
        deleteLocalBranch: Bool,
        deleteRemoteBranch: Bool,
        teardownCommand: String?,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        if worktreePath != project.path {
            try await teardownAndRemoveWorktree(
                project: project,
                worktreePath: worktreePath,
                teardownCommand: teardownCommand,
                onOutput: onOutput
            )
        }

        let projectURL = URL(fileURLWithPath: project.path)
        if deleteRemoteBranch {
            try await GitCLI.deleteRemoteBranch(branchName, at: projectURL)
        }
        // Already gone (deleted outside the app) must not block removing the task.
        if deleteLocalBranch, try await GitCLI.branchExists(branchName, at: projectURL) {
            try await GitCLI.deleteLocalBranch(branchName, at: projectURL, force: true)
        }
    }

    private static func teardownAndRemoveWorktree(
        project: Project,
        worktreePath: String,
        teardownCommand: String?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let worktreeURL = URL(fileURLWithPath: worktreePath)
        let projectURL = URL(fileURLWithPath: project.path)

        if let teardownCommand, !teardownCommand.trimmingCharacters(in: .whitespaces).isEmpty,
            FileManager.default.fileExists(atPath: worktreePath)
        {
            try await runCommand(teardownCommand, in: worktreeURL, onOutput: onOutput)
        }

        // Removed outside the app makes `git worktree remove` fail ("is not a working tree"); pruning alone clears stale metadata.
        if FileManager.default.fileExists(atPath: worktreePath) {
            try await GitCLI.removeWorktree(at: worktreeURL, in: projectURL, force: true)
        }
        try await GitCLI.pruneWorktrees(in: projectURL)
    }

    // MARK: - Hygiene

    /// Reports which of `worktreePaths` no longer exist on disk. Call on launch.
    public static func pruneAndDetectVanished(project: Project, worktreePaths: [String]) async throws -> Set<String> {
        let projectURL = URL(fileURLWithPath: project.path)
        try await GitCLI.pruneWorktrees(in: projectURL)
        let fileManager = FileManager.default
        var vanished: Set<String> = []
        for path in worktreePaths where path != project.path {
            if !fileManager.fileExists(atPath: path) {
                vanished.insert(path)
            }
        }
        return vanished
    }

    // MARK: - Sync status

    /// `merged` requires more than `GitCLI.isMerged`'s ancestor check, which
    /// alone is also true for a fresh branch or an in-place task whose branch
    /// *is* `baseRef`. A legacy task with no `baseCommit` falls back to the
    /// branch's reflog creation entry, reporting not-merged if even that's unavailable.
    public static func syncStatus(
        project: Project,
        branchName: String,
        baseRef: String? = nil,
        baseCommit: String? = nil,
        worktreePath: String? = nil
    ) async throws -> BranchSyncStatus {
        let projectURL = URL(fileURLWithPath: project.path)
        let resolvedBaseRef = baseRef ?? project.baseRef
        let (ahead, behind) = try await GitCLI.aheadBehind(branch: branchName, baseRef: resolvedBaseRef, at: projectURL)

        let resolvedBaseCommit: String?
        if let baseCommit {
            resolvedBaseCommit = baseCommit
        } else {
            resolvedBaseCommit = await GitCLI.reflogCreationCommit(forBranch: branchName, at: projectURL)
        }
        let merged = try await isBranchMerged(
            branchName: branchName,
            baseRef: resolvedBaseRef,
            baseCommit: resolvedBaseCommit,
            at: projectURL
        )
        // Falls back to `projectURL` for an in-place task, where uncommitted changes would live.
        let dirtyCheckURL = worktreePath.map { URL(fileURLWithPath: $0) } ?? projectURL
        let hasUncommittedChanges = (try? await GitCLI.isWorkingTreeDirty(at: dirtyCheckURL)) ?? false
        return BranchSyncStatus(
            ahead: ahead,
            behind: behind,
            merged: merged,
            resolvedBaseCommit: resolvedBaseCommit,
            hasUncommittedChanges: hasUncommittedChanges
        )
    }

    /// Never merged for an in-place task whose branch *is* `baseRef` —
    /// `GitCLI.isMerged` alone can't tell that apart from a genuine merge, since every commit is trivially its own ancestor.
    static func isBranchMerged(branchName: String, baseRef: String, baseCommit: String?, at projectURL: URL) async throws -> Bool {
        guard branchName != baseRef else { return false }
        return try await GitCLI.isMerged(branch: branchName, into: baseRef, since: baseCommit, at: projectURL)
    }
}
