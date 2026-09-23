import Foundation
import OSLog

/// Implements "Branches and worktrees" (native rewrite plan §4): creating a task's
/// branch and worktree, copying in ignored files a worktree needs, running setup
/// commands, and tearing worktrees down again. Pure git/filesystem orchestration —
/// callers own persisting the result to the database.
public enum TaskWorktreeService {
    static let logger = Logger(subsystem: "ai.syv.bside", category: "task-worktree")

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

    /// A branch as offered to the user when starting a task from existing work,
    /// annotated with where it's already checked out if it is — git refuses to
    /// check out a branch a second time, so this must be surfaced up front rather
    /// than discovered as a failure.
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
    }

    public struct BranchSyncStatus: Sendable, Equatable {
        public let ahead: Int
        public let behind: Int
        public let merged: Bool
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

    /// Upper bound on the `-2`, `-3`, … suffixes `uniqueSlug` tries before giving
    /// up and returning its last candidate, so a pathological filesystem/branch
    /// state can't spin the dedupe loop forever.
    static let maxUniqueSlugAttempts = 1000

    /// A variant of `baseSlug` whose worktree directory and `task/`-prefixed
    /// branch name are both free, suffixing with `-2`, `-3`, … so repeated task
    /// names — notably the blank-name placeholder "New Task" — get distinct
    /// worktrees instead of colliding with an existing task's directory or a
    /// branch left behind by a partially failed rename.
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

    /// Creates a task's branch and worktree, in the order the plan specifies:
    /// resolve base ref, create branch, create worktree, copy ignored files, run
    /// setup. If `existingBranch` is given, no branch is created — a worktree is
    /// attached to it instead, after confirming it isn't already checked out
    /// elsewhere.
    ///
    /// If `useWorktree` is false, the task runs in-place: no branch or worktree is
    /// created, and the project's own path and current branch are used.
    @discardableResult
    public static func createWorktree(
        for project: Project,
        taskName: String,
        baseRef: String? = nil,
        existingBranch: String? = nil,
        useWorktree: Bool = true,
        setupCommand: String? = nil,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> WorktreeSetupResult {
        let projectURL = URL(fileURLWithPath: project.path)

        guard useWorktree else {
            let branch = await GitCLI.currentBranch(at: projectURL) ?? project.baseRef
            return WorktreeSetupResult(
                branchName: branch,
                branchCreatedByApp: false,
                worktreePath: project.path,
                copiedIgnoredFiles: []
            )
        }

        let baseSlug = slug(forTaskName: taskName)
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

        let copied = try await copyIgnoredFiles(from: projectURL, to: worktreeURL)

        if let setupCommand, !setupCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            try await runCommand(setupCommand, in: worktreeURL, onOutput: onOutput)
        }

        return WorktreeSetupResult(
            branchName: branchName,
            branchCreatedByApp: branchCreatedByApp,
            worktreePath: worktreePathString,
            copiedIgnoredFiles: copied
        )
    }

    /// Copies loose git-ignored files (see `GitCLI.looseIgnoredFiles`) from the
    /// project into a freshly created worktree, preserving relative paths and
    /// creating intermediate directories as needed. Returns the relative paths copied.
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

    /// Archives a task: optionally removes its worktree (running teardown first
    /// and pruning afterwards), but never touches the branch.
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

    /// Deletes a task entirely: removes its worktree (teardown first), then
    /// optionally the local branch (only ever offered when the app created it) and
    /// the remote branch.
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
        if deleteLocalBranch {
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

        try await GitCLI.removeWorktree(at: worktreeURL, in: projectURL, force: true)
        try await GitCLI.pruneWorktrees(in: projectURL)
    }

    // MARK: - Hygiene

    /// Prunes stale worktree metadata and reports which of `worktreePaths` no
    /// longer exist on disk (their directories vanished out from under the app).
    /// Call on launch.
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

    /// Ahead/behind counts and merged status for `branchName` against `baseRef`.
    public static func syncStatus(project: Project, branchName: String, baseRef: String? = nil) async throws -> BranchSyncStatus {
        let projectURL = URL(fileURLWithPath: project.path)
        let resolvedBaseRef = baseRef ?? project.baseRef
        let (ahead, behind) = try await GitCLI.aheadBehind(branch: branchName, baseRef: resolvedBaseRef, at: projectURL)
        let merged = try await GitCLI.isMerged(branch: branchName, into: resolvedBaseRef, at: projectURL)
        return BranchSyncStatus(ahead: ahead, behind: behind, merged: merged)
    }
}
