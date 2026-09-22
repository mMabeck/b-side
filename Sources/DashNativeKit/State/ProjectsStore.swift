import Foundation
import GRDB
import OSLog
import SwiftUI

/// Drives the sidebar's project (and nested task) list live from the database,
/// using GRDB's `ValueObservation`.
@MainActor
@Observable
public final class ProjectsStore {
    public private(set) var projects: [Project] = []
    public private(set) var tasksByProject: [Int64: [TaskRecord]] = [:]
    public private(set) var syncStatusByTask: [Int64: TaskWorktreeService.BranchSyncStatus] = [:]
    public private(set) var vanishedWorktreeTaskIds: Set<Int64> = []

    /// The project whose terminals the main area and terminal drawer show.
    /// In-memory only; not persisted. `nil` until the user picks a project.
    public var selectedProjectID: Int64?

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "ai.syv.dash-native", category: "projects-store")

    public init(database: AppDatabase) {
        self.database = database
    }

    public func start() {
        guard observationTask == nil else { return }
        let observation = ValueObservation.tracking { db in
            let projects = try Project.fetchAll(db)
            var tasksByProject: [Int64: [TaskRecord]] = [:]
            for project in projects {
                guard let projectId = project.id else { continue }
                tasksByProject[projectId] = try TaskRecord
                    .filter(TaskRecord.Columns.projectId == projectId)
                    .filter(TaskRecord.Columns.archived == false)
                    .order(TaskRecord.Columns.sortPosition)
                    .fetchAll(db)
            }
            return (projects, tasksByProject)
        }

        observationTask = Task { [weak self, database] in
            guard let self else { return }
            do {
                for try await (projects, tasksByProject) in observation.values(in: database.dbQueue) {
                    self.projects = projects
                    self.tasksByProject = tasksByProject
                }
            } catch {
                Self.logger.error("Project observation failed: \(error, privacy: .public)")
            }
        }

        Task { [weak self] in
            await self?.pruneAndDetectVanishedWorktrees()
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Adds `path` as a project. If it is not already a git repository, `git init`s it.
    public func addProject(at path: URL) async throws {
        if await !GitCLI.isGitRepository(at: path) {
            try await GitCLI.initRepository(at: path)
        }
        let remote = await GitCLI.originRemote(at: path)
        let branch = await GitCLI.currentBranch(at: path)

        let project = Project(
            path: path.path,
            displayName: path.lastPathComponent,
            remote: remote,
            baseRef: branch ?? "main"
        )
        try await database.dbQueue.write { db in
            var project = project
            try project.insert(db)
        }
    }

    public func removeProject(_ project: Project) async throws {
        guard let id = project.id else { return }
        try await database.dbQueue.write { db in
            _ = try Project.deleteOne(db, key: id)
        }
    }

    // MARK: - Tasks and worktrees

    /// Creates a task: resolves the base ref, creates (or attaches to) a branch
    /// and worktree, copies ignored files, runs setup, then persists the task.
    /// `onOutput` streams setup command output for display while creation is
    /// still in progress.
    @discardableResult
    public func createTask(
        project: Project,
        name: String,
        baseRef: String? = nil,
        existingBranch: String? = nil,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TaskRecord {
        let config = ProjectConfig.load(forProjectAt: URL(fileURLWithPath: project.path))

        let setupResult = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: name,
            baseRef: baseRef,
            existingBranch: existingBranch,
            useWorktree: config.taskDefaults.useWorktree,
            setupCommand: config.setupCommand,
            onOutput: onOutput
        )

        let task = TaskRecord(
            projectId: project.id ?? 0,
            name: name,
            branchName: setupResult.branchName,
            branchCreatedByApp: setupResult.branchCreatedByApp,
            worktreePath: setupResult.worktreePath,
            harness: "claude",
            permissionLevel: config.taskDefaults.permissionMode
        )
        return try await database.dbQueue.write { db in
            var task = task
            try task.insert(db)
            return task
        }
    }

    /// Archives a task: hides it (already excluded from `tasksByProject` once
    /// `archived` is set) and, if requested, removes its worktree while keeping
    /// the branch.
    public func archiveTask(_ task: TaskRecord, project: Project, removeWorktree: Bool) async throws {
        if removeWorktree {
            try await TaskWorktreeService.archiveWorktree(
                project: project,
                worktreePath: task.worktreePath,
                removeWorktree: true,
                teardownCommand: task.teardownCommand
            )
        }
        try await database.dbQueue.write { db in
            var updated = task
            updated.archived = true
            try updated.update(db)
        }
    }

    /// Deletes a task: removes its worktree (teardown first), optionally deletes
    /// the local branch — only offer this when the app created it — and
    /// optionally the remote branch, then removes the database record.
    public func deleteTask(
        _ task: TaskRecord,
        project: Project,
        deleteLocalBranch: Bool,
        deleteRemoteBranch: Bool
    ) async throws {
        try await TaskWorktreeService.deleteTask(
            project: project,
            worktreePath: task.worktreePath,
            branchName: task.branchName,
            deleteLocalBranch: deleteLocalBranch && task.branchCreatedByApp,
            deleteRemoteBranch: deleteRemoteBranch,
            teardownCommand: task.teardownCommand
        )
        guard let id = task.id else { return }
        try await database.dbQueue.write { db in
            _ = try TaskRecord.deleteOne(db, key: id)
        }
    }

    /// Refreshes ahead/behind/merged status for `task` against its project's base ref.
    public func refreshSyncStatus(for task: TaskRecord, project: Project) async {
        guard let id = task.id else { return }
        guard let status = try? await TaskWorktreeService.syncStatus(project: project, branchName: task.branchName) else {
            return
        }
        syncStatusByTask[id] = status
    }

    /// Prunes worktree metadata and detects worktrees whose directories vanished
    /// out from under the app. Called on launch.
    public func pruneAndDetectVanishedWorktrees() async {
        var vanished: Set<Int64> = []
        for project in await currentProjects() {
            guard let projectId = project.id else { continue }
            let tasks: [TaskRecord]
            if let cached = tasksByProject[projectId] {
                tasks = cached
            } else {
                tasks = (try? await allTasks(forProjectId: projectId)) ?? []
            }
            let paths = tasks.map(\.worktreePath)
            guard let vanishedPaths = try? await TaskWorktreeService.pruneAndDetectVanished(
                project: project,
                worktreePaths: paths
            ) else { continue }
            for task in tasks where vanishedPaths.contains(task.worktreePath) {
                if let id = task.id { vanished.insert(id) }
            }
        }
        vanishedWorktreeTaskIds = vanished
    }

    private func currentProjects() async -> [Project] {
        (try? await database.dbQueue.read { db in try Project.fetchAll(db) }) ?? []
    }

    private func allTasks(forProjectId projectId: Int64) async throws -> [TaskRecord] {
        try await database.dbQueue.read { db in
            try TaskRecord.filter(TaskRecord.Columns.projectId == projectId).fetchAll(db)
        }
    }
}
