import Foundation
import GRDB
import OSLog
import SwiftUI

/// What the main area currently shows, derived from `ProjectsStore`'s
/// selection state. A project by itself is never a terminal — only a task
/// is — so this collapses the two separately-nilable IDs into one thing the
/// main area can switch on instead of scattering nil-checks across it.
public enum MainSelection: Equatable {
    case none
    case project(Project)
    case task(TaskRecord, Project)
}

/// Drives the sidebar's project (and nested task) list live from the database,
/// using GRDB's `ValueObservation`.
@MainActor
@Observable
public final class ProjectsStore {
    public private(set) var projects: [Project] = []
    public private(set) var tasksByProject: [Int64: [TaskRecord]] = [:]
    public private(set) var syncStatusByTask: [Int64: TaskWorktreeService.BranchSyncStatus] = [:]
    public private(set) var vanishedWorktreeTaskIds: Set<Int64> = []

    /// The project whose dashboard or task list the sidebar and main area
    /// reflect. In-memory only; not persisted. `nil` until the user picks a
    /// project. Kept in sync with `selectedTaskID` by `selectProject(_:)` /
    /// `selectTask(_:project:)` below rather than set directly, so the two
    /// never point at a project/task pair that disagree with each other.
    public var selectedProjectID: Int64?

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    /// The task whose subagents (and, later, split panes) the right sidebar
    /// and left sidebar rows reflect, and whose terminal the main area shows.
    /// In-memory only; not persisted. `nil` means the main area shows the
    /// selected project's dashboard (or, with no project either, an empty
    /// state) rather than a task terminal — a project alone is never a
    /// terminal.
    public var selectedTaskID: Int64?

    public var selectedTask: TaskRecord? {
        guard let selectedTaskID else { return nil }
        return tasksByProject.values.lazy.flatMap { $0 }.first { $0.id == selectedTaskID }
    }

    /// Selects `project` for the sidebar/dashboard and clears any task
    /// selection: a project on its own is never a terminal, so picking one
    /// always evicts whatever task terminal was showing.
    public func selectProject(_ project: Project) {
        selectedProjectID = project.id
        selectedTaskID = nil
    }

    /// Selects `task` and, since a task's terminal is meaningless without
    /// knowing which project owns it, its project too — the two selections
    /// are set together so they can never disagree.
    public func selectTask(_ task: TaskRecord, project: Project) {
        selectedProjectID = project.id
        selectedTaskID = task.id
    }

    /// Reconciles selection against a fresh `projects`/`tasksByProject`
    /// snapshot so a task or project that disappeared — via `archiveTask`,
    /// `deleteTask`, `removeProject`, or any other change underneath the
    /// database, not just this store's own mutations — never leaves the
    /// selection pointing at something no sidebar row or dashboard reads as
    /// selected. Falls back to the vanished task's parent project (still
    /// valid, since `selectTask` always keeps `selectedProjectID` in sync
    /// with it) if that project still exists, and to no selection at all
    /// once even the project is gone. Run from the `ValueObservation`
    /// callback in `start()`, which is why it's pure and static: it needs to
    /// react to *any* refresh of `projects`/`tasksByProject`, and being pure
    /// makes that reaction directly testable without a database.
    static func reconcileSelection(
        selectedProjectID: Int64?,
        selectedTaskID: Int64?,
        projects: [Project],
        tasksByProject: [Int64: [TaskRecord]]
    ) -> (selectedProjectID: Int64?, selectedTaskID: Int64?) {
        if let selectedTaskID {
            let taskStillExists = tasksByProject.values.contains { $0.contains { $0.id == selectedTaskID } }
            let projectStillExists = projects.contains { $0.id == selectedProjectID }
            if taskStillExists && projectStillExists {
                return (selectedProjectID, selectedTaskID)
            }
            return (projectStillExists ? selectedProjectID : nil, nil)
        }
        if let selectedProjectID {
            let projectStillExists = projects.contains { $0.id == selectedProjectID }
            return (projectStillExists ? selectedProjectID : nil, nil)
        }
        return (nil, nil)
    }

    /// What the main area should show, derived from the selection above
    /// rather than tracked separately, so there is exactly one place that
    /// decides dashboard vs. terminal vs. empty state. A task selection wins
    /// over a project selection if both happen to be set (defensive against
    /// anything that mutates `selectedProjectID`/`selectedTaskID` directly
    /// instead of through `selectProject`/`selectTask`).
    public var mainSelection: MainSelection {
        if let task = selectedTask, let project = projects.first(where: { $0.id == task.projectId }) {
            return .task(task, project)
        }
        if let selectedProject {
            return .project(selectedProject)
        }
        return .none
    }

    /// Feed of child agent runs, keyed by task. One store for the whole app so
    /// the Subagents tab and the left sidebar's per-task indicators read the
    /// same data.
    public let subagentFeed = SubagentFeedStore()

    /// The local HTTP endpoint agent processes report status and subagent
    /// events to (native-rewrite.md §5, §6). `nil` until `start()` has bound it.
    public private(set) var subagentServer: SubagentEventServer?

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "ai.syv.bside", category: "projects-store")

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
                    let reconciled = Self.reconcileSelection(
                        selectedProjectID: self.selectedProjectID,
                        selectedTaskID: self.selectedTaskID,
                        projects: projects,
                        tasksByProject: tasksByProject
                    )
                    self.selectedProjectID = reconciled.selectedProjectID
                    self.selectedTaskID = reconciled.selectedTaskID
                }
            } catch {
                Self.logger.error("Project observation failed: \(error, privacy: .public)")
            }
        }

        Task { [weak self] in
            await self?.pruneAndDetectVanishedWorktrees()
        }

        Task { [weak self] in
            await self?.startSubagentServer()
        }
    }

    private func startSubagentServer() async {
        guard subagentServer == nil else { return }
        do {
            let server = try SubagentEventServer(store: subagentFeed)
            try await server.start()
            subagentServer = server
            Self.logger.info("Subagent event server listening on \(server.address ?? "?", privacy: .public)")
        } catch {
            Self.logger.error("Failed to start subagent event server: \(error, privacy: .public)")
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
