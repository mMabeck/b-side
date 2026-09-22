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
}
