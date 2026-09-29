import Foundation
import OSLog

/// Git/filesystem orchestration for task branches and worktrees; callers persist the results.
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

    /// Git refuses to check out a branch twice, so where it's checked out is surfaced up front.
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
        public let baseCommit: String?
    }

    public struct BranchSyncStatus: Sendable, Equatable {
        public let ahead: Int
        public let behind: Int
        public let merged: Bool
        /// Callers should persist this so the legacy reflog fallback isn't repeated.
        public let resolvedBaseCommit: String?
        /// A merged branch with uncommitted edits hasn't landed everything; never show "Merged" while true.
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

    public static func availableBaseRefs(for project: Project) async throws -> [String] {
        let projectURL = URL(fileURLWithPath: project.path)
        let local = try await GitCLI.localBranches(at: projectURL)
        let remote = try await GitCLI.remoteTrackingBranches(at: projectURL)
        return local + remote
    }

    // MARK: - Creation

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

    /// `<projectPath>-worktrees/<slug>`, outside the repository.
    public static func worktreePath(forProjectAt projectPath: String, slug: String) -> String {
        let projectURL = URL(fileURLWithPath: projectPath)
        let siblingRoot = projectURL.deletingLastPathComponent()
            .appendingPathComponent("\(projectURL.lastPathComponent)-worktrees")
        return siblingRoot.appendingPathComponent(slug).path
    }

    /// Bounds the dedupe loop so a pathological filesystem/branch state can't spin it forever.
    static let maxUniqueSlugAttempts = 1000

    /// Permanent content-free identifier: the worktree directory is never renamed.
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

    /// `merged` needs more than the ancestor check, which is also true for a fresh branch or an in-place task on `baseRef`.
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

    static func isBranchMerged(branchName: String, baseRef: String, baseCommit: String?, at projectURL: URL) async throws -> Bool {
        guard branchName != baseRef else { return false }
        return try await GitCLI.isMerged(branch: branchName, into: baseRef, since: baseCommit, at: projectURL)
    }
}
