import AppKit
import Foundation
import GRDB
import OSLog
import SwiftUI

public enum MainSelection: Equatable {
    case none
    case project(Project)
    case task(TaskRecord, Project)

    public var taskCreationTarget: Project? {
        switch self {
        case .none: return nil
        case .project(let project): return project
        case .task(_, let project): return project
        }
    }
}

public enum ProjectMoveDirection {
    case up
    case down
}

@MainActor
@Observable
public final class ProjectsStore {
    public private(set) var projects: [Project] = []
    public private(set) var tasksByProject: [Int64: [TaskRecord]] = [:]
    public private(set) var syncStatusByTask: [Int64: TaskWorktreeService.BranchSyncStatus] = [:]
    public private(set) var vanishedWorktreeTaskIds: Set<Int64> = []

    public private(set) var taskIDsNeedingAttention: Set<Int64> = []

    public private(set) var busyTaskIDs: Set<Int64> = []

    public private(set) var unreadTaskIDs: Set<Int64> = []

    /// Only a genuine not-busy -> busy transition bumps ordering, so repeated pings don't reorder the Active section. Also clears a question's red state: busy means it was answered.
    public func setTaskBusy(_ taskId: Int64) {
        let wasAlreadyBusy = busyTaskIDs.contains(taskId)
        busyTaskIDs.insert(taskId)
        taskIDsNeedingAttention.remove(taskId)
        guard !wasAlreadyBusy else { return }
        bumpTaskActivity(taskId)
    }

    public func clearTaskBusy(_ taskId: Int64) {
        if markIdle(taskId) {
            bumpTaskActivity(taskId)
        }
    }

    /// Never bumps recency, unlike `clearTaskBusy`: teardown isn't a user activity signal.
    public func dropTaskBusy(_ taskId: Int64) {
        markIdle(taskId)
    }

    /// A genuine busy→idle transition also marks the task unread, unless B-Side is frontmost and already showing it.
    @discardableResult
    private func markIdle(_ taskId: Int64) -> Bool {
        let wasBusy = busyTaskIDs.remove(taskId) != nil
        guard wasBusy else { return false }
        let isFrontmostAndSelected = NSApp?.isActive == true && selectedTaskID == taskId
        if !isFrontmostAndSelected {
            unreadTaskIDs.insert(taskId)
        }
        return true
    }

    private var lastTerminalAlertAt: [Int64: Date] = [:]

    @ObservationIgnored
    public var playAlertSound: @MainActor (TaskAlertKind) -> Void = { TaskAlertSoundPlayer.play(kind: $0) }

    public var selectedProjectID: Int64?

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    public var selectedTaskID: Int64?

    /// Bumped on every selection, even of the current one, so `MainAreaView.syncFocus()` reruns.
    public private(set) var focusRequestToken: Int = 0

    /// Single source for the task-creation sheet so it can't be shown twice or point at a stale project.
    public var pendingTaskCreationProject: Project?

    public var pendingChangesOverlayTask: TaskRecord?

    public var selectedTask: TaskRecord? {
        guard let selectedTaskID else { return nil }
        return tasksByProject.values.lazy.flatMap { $0 }.first { $0.id == selectedTaskID }
    }

    /// Ordered by recent activity so Cmd+1 tracks the most recently active task; `MainAreaView` is the only writer of open/close.
    public private(set) var openTerminalTaskIDs: [Int64] = []

    public func noteTerminalOpened(taskID: Int64) {
        openTerminalTaskIDs = Self.addingOpenTerminal(taskID, to: openTerminalTaskIDs)
    }

    public func pruneOpenTerminals(removing removed: Set<Int64>) {
        openTerminalTaskIDs = Self.removingOpenTerminals(removed, from: openTerminalTaskIDs)
    }

    static func nextActiveTaskID(afterClosing taskID: Int64, in openTaskIDs: [Int64]) -> Int64? {
        guard let index = openTaskIDs.firstIndex(of: taskID) else { return nil }
        let remaining = removingOpenTerminals([taskID], from: openTaskIDs)
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)]
    }

    /// One-shot request set by `closeTerminal` and cleared by `MainAreaView` once purged.
    public private(set) var closedTerminalTaskID: Int64?

    public func closeTerminal(for task: TaskRecord, project: Project) {
        guard let id = task.id else { return }
        let nextID = Self.nextActiveTaskID(afterClosing: id, in: openTerminalTaskIDs)
        openTerminalTaskIDs = Self.removingOpenTerminals([id], from: openTerminalTaskIDs)
        unreadTaskIDs.remove(id)
        closedTerminalTaskID = id
        if let nextID, let match = taskAndProject(forID: nextID) {
            selectTask(match.task, project: match.project)
        } else {
            selectProject(project)
        }
    }

    /// No-op if a different (or no) close request is pending, so a stale acknowledgement can't clear a newer one.
    public func acknowledgeTerminalClosed(_ id: Int64) {
        guard closedTerminalTaskID == id else { return }
        closedTerminalTaskID = nil
    }

    public private(set) var restartRequestedTaskID: Int64?

    /// Relaunches via `PiSessionService.launchCommand` so the same pi session resumes.
    public func requestRestartTerminal(for task: TaskRecord) {
        guard let id = task.id else { return }
        restartRequestedTaskID = id
    }

    public func acknowledgeRestartRequested(_ id: Int64) {
        guard restartRequestedTaskID == id else { return }
        restartRequestedTaskID = nil
    }

    public func project(forTask task: TaskRecord) -> Project? {
        projects.first { $0.id == task.projectId }
    }

    static func addingOpenTerminal(_ id: Int64, to ids: [Int64]) -> [Int64] {
        ids.contains(id) ? ids : ids + [id]
    }

    static func removingOpenTerminals(_ removed: Set<Int64>, from ids: [Int64]) -> [Int64] {
        ids.filter { !removed.contains($0) }
    }

    static func movingToFront(_ id: Int64, in ids: [Int64]) -> [Int64] {
        guard let index = ids.firstIndex(of: id) else { return ids }
        var result = ids
        result.remove(at: index)
        result.insert(id, at: 0)
        return result
    }

    public func bumpTaskActivity(_ id: Int64) {
        openTerminalTaskIDs = Self.movingToFront(id, in: openTerminalTaskIDs)
        Task { [database] in
            try? await database.dbQueue.write { db in
                guard var task = try TaskRecord.fetchOne(db, key: id) else { return }
                try task.updateChanges(db) { $0.lastActivityAt = Date() }
            }
        }
    }

    public func taskAndProject(forID id: Int64) -> (task: TaskRecord, project: Project)? {
        for (projectID, tasks) in tasksByProject {
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            guard let project = projects.first(where: { $0.id == projectID }) else { continue }
            return (task, project)
        }
        return nil
    }

    public func selectProject(_ project: Project) {
        selectedProjectID = project.id
        selectedTaskID = nil
        focusRequestToken += 1
    }

    public func requestTerminalFocus() {
        focusRequestToken += 1
    }

    public func selectTask(_ task: TaskRecord, project: Project) {
        selectedProjectID = project.id
        selectedTaskID = task.id
        if let id = task.id {
            taskIDsNeedingAttention.remove(id)
            unreadTaskIDs.remove(id)
        }
        focusRequestToken += 1
    }

    // MARK: - Terminal alerts

    public func handleTerminalDesktopNotification(taskID: Int64, title: String, body: String) {
        handleTerminalAlert(
            taskID: taskID,
            kind: TaskAlertClassifier.classify(title: title, body: body),
            title: title,
            body: body
        )
    }

    /// Always classified as a question: a bare bell has no more specific text to go on.
    public func handleTerminalBell(taskID: Int64) {
        handleTerminalAlert(taskID: taskID, kind: .question, title: "Bell", body: "")
    }

    private func handleTerminalAlert(taskID: Int64, kind: TaskAlertKind, title: String, body: String) {
        let now = Date()
        if TaskAlertDebouncer.isDebounced(previous: lastTerminalAlertAt[taskID], now: now) { return }
        lastTerminalAlertAt[taskID] = now

        playAlertSound(kind)

        if kind == .question {
            taskIDsNeedingAttention.insert(taskID)
            bumpTaskActivity(taskID)
        }

        guard UserDefaults.standard.object(forKey: TaskAlertSettingsKeys.enabled) as? Bool ?? true else { return }
        let isFrontmostAndSelected = NSApp?.isActive == true && selectedTaskID == taskID
        guard !isFrontmostAndSelected else { return }

        let taskName = taskAndProject(forID: taskID)?.task.name ?? "Task"
        TaskAlertNotificationCenter.shared.notify(taskID: taskID, taskName: taskName, title: title, body: body)
    }

    /// Falls back to the vanished task's parent project if it still exists, else no selection.
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

    /// A task selection wins if both are somehow set.
    public var mainSelection: MainSelection {
        if let task = selectedTask, let project = projects.first(where: { $0.id == task.projectId }) {
            return .task(task, project)
        }
        if let selectedProject {
            return .project(selectedProject)
        }
        return .none
    }

    public let subagentFeed = SubagentFeedStore()

    public let subagentPanes = SubagentPaneStore()

    public let subagentSwap = SubagentSwapStore()

    public let subagentStripBatches = SubagentStripBatchTracker()

    public private(set) var subagentServer: SubagentEventServer?

    /// What `SubagentSwapNavigation` steps through. A headless card-only child never appears: there is nothing to swap to.
    public func stripChildIDsWithLiveSurface(forTask taskId: Int64) -> [String] {
        let allRuns = subagentFeed.runs(forTask: taskId)
        let swappedIn = subagentSwap.shownChildID(forTask: taskId)
        let visible = subagentStripBatches.visibleRuns(forTask: taskId, allRuns: allRuns, swappedInChildID: swappedIn)
        let liveIDs = Set(subagentPanes.panes(forTask: taskId).map(\.id))
        return visible.map(\.id).filter { liveIDs.contains($0) }
    }

    /// Bumped per strip-prune tick: a card leaving after its linger is otherwise triggered by no event.
    public private(set) var stripTickToken = 0

    private func pruneAgedOutStripPanes() {
        let now = Date()
        var changed = false
        for taskId in subagentFeed.runsByTask.keys {
            let allRuns = subagentFeed.runs(forTask: taskId)
            if allRuns.contains(where: { run in
                run.endedAt.map { now.timeIntervalSince($0) <= SubagentStripBatchTracker.lingerInterval + 1 } ?? false
            }) {
                changed = true
            }
            let livePaneIDs = Set(subagentPanes.panes(forTask: taskId).map(\.id))
            guard !livePaneIDs.isEmpty else { continue }
            let swappedIn = subagentSwap.shownChildID(forTask: taskId)
            let agedOut = SubagentStripBatchTracker.agedOutPaneIDs(
                allRuns: allRuns,
                livePaneIDs: livePaneIDs,
                now: now,
                swappedInChildID: swappedIn
            )
            for childId in agedOut {
                subagentPanes.close(taskId: taskId, childId: childId)
                changed = true
            }
        }
        if changed { stripTickToken &+= 1 }
    }

    private let database: AppDatabase
    private var observationTask: Task<Void, Never>?
    private var stripPruneTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private var refsWatchers: [Int64: ProjectRefsWatcher] = [:]
    /// Guards against a ref change piling up a second concurrent git call for the same task.
    private var syncRefreshInFlight: Set<Int64> = []
    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "projects-store")

    public init(database: AppDatabase) {
        self.database = database
    }

    public func start() {
        guard observationTask == nil else { return }
        let observation = ValueObservation.tracking { db in
            let projects = try Project.order(Project.Columns.sortOrder, Project.Columns.id).fetchAll(db)
            var tasksByProject: [Int64: [TaskRecord]] = [:]
            for project in projects {
                guard let projectId = project.id else { continue }
                // SQLite sorts NULL last in DESC, so pre-migration rows fall to the bottom; `id.desc` is the tiebreaker.
                tasksByProject[projectId] = try TaskRecord
                    .filter(TaskRecord.Columns.projectId == projectId)
                    .filter(TaskRecord.Columns.archived == false)
                    .order(TaskRecord.Columns.lastActivityAt.desc, TaskRecord.Columns.id.desc)
                    .fetchAll(db)
            }
            return (projects, tasksByProject)
        }

        // `-BSideSelectTaskOnLaunch <id>` opens a task without UI input, for scripted measurement runs.
        let launchArgument = UserDefaults.standard.integer(forKey: "BSideSelectTaskOnLaunch")
        observationTask = Task { [weak self, database] in
            guard let self else { return }
            var launchTaskID: Int64? = launchArgument > 0 ? Int64(launchArgument) : nil
            do {
                for try await (projects, tasksByProject) in observation.values(in: database.dbQueue) {
                    self.projects = projects
                    self.tasksByProject = tasksByProject
                    self.syncRefsWatchers()
                    let reconciled = Self.reconcileSelection(
                        selectedProjectID: self.selectedProjectID,
                        selectedTaskID: self.selectedTaskID,
                        projects: projects,
                        tasksByProject: tasksByProject
                    )
                    self.selectedProjectID = reconciled.selectedProjectID
                    self.selectedTaskID = reconciled.selectedTaskID
                    if let id = launchTaskID, let pair = self.taskAndProject(forID: id) {
                        launchTaskID = nil
                        self.selectTask(pair.task, project: pair.project)
                    }
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

        stripPruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.pruneAgedOutStripPanes()
            }
        }

        TaskAlertNotificationCenter.shared.activateIfSupported()
        TaskAlertNotificationCenter.shared.onSelectTask = { [weak self] taskID in
            guard let self, let pair = self.taskAndProject(forID: taskID) else { return }
            self.selectTask(pair.task, project: pair.project)
        }

        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let id = self.selectedTaskID {
                    self.unreadTaskIDs.remove(id)
                }
                // Backstop for FSEvents coalescing that may miss a commit/merge made while suspended.
                await self.refreshAllSyncStatuses()
            }
        }
    }

    private func syncRefsWatchers() {
        let currentIDs = Set(projects.compactMap(\.id))
        for id in refsWatchers.keys where !currentIDs.contains(id) {
            refsWatchers[id]?.stop()
            refsWatchers[id] = nil
        }
        for project in projects {
            guard let id = project.id, refsWatchers[id] == nil else { continue }
            let watcher = ProjectRefsWatcher(projectURL: URL(fileURLWithPath: project.path)) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refreshSyncStatuses(forProjectID: id)
                }
            }
            watcher.start()
            refsWatchers[id] = watcher
        }
    }

    /// Skips a task whose refresh is already in flight rather than queuing a second; the next trigger catches up.
    private func refreshSyncStatuses(forProjectID projectID: Int64) async {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let tasks = tasksByProject[projectID] ?? []
        for task in tasks {
            guard let taskID = task.id, !syncRefreshInFlight.contains(taskID) else { continue }
            syncRefreshInFlight.insert(taskID)
            await refreshSyncStatus(for: task, project: project)
            syncRefreshInFlight.remove(taskID)
        }
    }

    private func refreshAllSyncStatuses() async {
        for project in projects {
            guard let id = project.id else { continue }
            await refreshSyncStatuses(forProjectID: id)
        }
    }

    private func startSubagentServer() async {
        guard subagentServer == nil else { return }
        do {
            let server = try SubagentEventServer(
                store: subagentFeed,
                paneStore: subagentPanes,
                taskExists: { [weak self] taskId in self?.task(withId: taskId) != nil },
                onAgentBusy: { [weak self] taskId in self?.setTaskBusy(taskId) },
                onAgentIdle: { [weak self] taskId in self?.clearTaskBusy(taskId) },
                onAgentAlert: { [weak self] taskId, kind, title, body in
                    self?.handleTerminalAlert(taskID: taskId, kind: kind, title: title, body: body)
                }
            )
            try await server.start()
            subagentServer = server
            Self.logger.info("Subagent event server listening on \(server.address ?? "?", privacy: .public)")
            if let address = server.address, let fileURL = Self.subagentEndpointFileURL() {
                Self.writeSubagentEndpointFile(address: address, to: fileURL)
            }
        } catch {
            Self.logger.error("Failed to start subagent event server: \(error, privacy: .public)")
        }
    }

    /// The port changes every launch; the Pi-side spawner reads this file to find it.
    static func subagentEndpointFileURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent(AppDatabase.appSupportName, isDirectory: true)
            .appendingPathComponent("subagent-endpoint", isDirectory: false)
    }

    static func writeSubagentEndpointFile(address: String, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try address.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write subagent endpoint file: \(error, privacy: .public)")
        }
    }

    static func removeSubagentEndpointFile(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        subagentServer?.stop()
        subagentServer = nil
        stripPruneTask?.cancel()
        stripPruneTask = nil
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
        for watcher in refsWatchers.values { watcher.stop() }
        refsWatchers.removeAll()
        if let fileURL = Self.subagentEndpointFileURL() {
            Self.removeSubagentEndpointFile(at: fileURL)
        }
    }

    public func addProject(at path: URL) async throws {
        if await !GitCLI.isGitRepository(at: path) {
            try await GitCLI.initRepository(at: path)
        }
        let remote = await GitCLI.originRemote(at: path)
        let branch = await GitCLI.currentBranch(at: path)

        try await database.dbQueue.write { db in
            let maxSortOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM project") ?? -1
            var project = Project(
                path: path.path,
                displayName: path.lastPathComponent,
                remote: remote,
                baseRef: branch ?? "main",
                sortOrder: maxSortOrder + 1
            )
            try project.insert(db)
        }
    }

    /// Updates `projects` optimistically so the drag doesn't snap back while the write is in flight.
    public func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int) async throws {
        var reordered = projects
        reordered.move(fromOffsets: source, toOffset: destination)
        projects = reordered

        let orderedIDs = reordered.map(\.id)
        try await database.dbQueue.write { db in
            for (index, id) in orderedIDs.enumerated() {
                guard let id else { continue }
                try db.execute(sql: "UPDATE project SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }

    /// VoiceOver alternative to drag reordering.
    public func moveProject(_ project: Project, direction: ProjectMoveDirection) async throws {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let destination = direction == .up ? index - 1 : index + 2
        guard destination >= 0, destination <= projects.count else { return }
        try await moveProjects(fromOffsets: IndexSet(integer: index), toOffset: destination)
    }

    public func removeProject(_ project: Project) async throws {
        guard let id = project.id else { return }
        try await database.dbQueue.write { db in
            _ = try Project.deleteOne(db, key: id)
        }
    }

    /// Base ref is persisted only when a non-blank new-branch base was used.
    public func rememberTaskCreationChoices(
        project: Project,
        baseRef: String?,
        useWorktree: Bool,
        mode: TaskCreationMode
    ) async throws {
        guard let id = project.id else { return }
        try await database.dbQueue.write { db in
            guard var current = try Project.fetchOne(db, key: id) else { return }
            try current.updateChanges(db) { row in
                if let baseRef, !baseRef.trimmingCharacters(in: .whitespaces).isEmpty {
                    row.baseRef = baseRef
                }
                row.lastUseWorktree = useWorktree
                row.lastTaskCreationMode = mode.rawValue
            }
        }
        if let index = projects.firstIndex(where: { $0.id == id }) {
            if let baseRef, !baseRef.trimmingCharacters(in: .whitespaces).isEmpty {
                projects[index].baseRef = baseRef
            }
            projects[index].lastUseWorktree = useWorktree
            projects[index].lastTaskCreationMode = mode.rawValue
        }
    }

    // MARK: - Tasks and worktrees

    @discardableResult
    public func createTask(
        project: Project,
        name: String,
        baseRef: String? = nil,
        existingBranch: String? = nil,
        useWorktree: Bool? = nil,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TaskRecord {
        let config = ProjectConfig.load(forProjectAt: URL(fileURLWithPath: project.path))
        let nameWasBlank = name.trimmingCharacters(in: .whitespaces).isEmpty
        let resolvedName = nameWasBlank ? "New Task" : name

        let setupResult = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: resolvedName,
            baseRef: baseRef,
            existingBranch: existingBranch,
            useWorktree: useWorktree ?? config.taskDefaults.useWorktree,
            setupCommand: config.setupCommand,
            baseSlugOverride: nameWasBlank ? TaskWorktreeService.randomTaskSlug() : nil,
            onOutput: onOutput
        )

        let task = TaskRecord(
            projectId: project.id ?? 0,
            name: resolvedName,
            branchName: setupResult.branchName,
            branchCreatedByApp: setupResult.branchCreatedByApp,
            worktreePath: setupResult.worktreePath,
            harness: "claude",
            permissionLevel: config.taskDefaults.permissionMode,
            awaitingAutoRename: nameWasBlank,
            baseCommit: setupResult.baseCommit,
            lastActivityAt: Date()
        )
        let inserted = try await database.dbQueue.write { db in
            var task = task
            try task.insert(db)
            return task
        }
        // Inserted ahead of the observation refresh so `selectTask` resolves to `.task` immediately; only if absent, since the observation may win the race.
        tasksByProject[inserted.projectId] = Self.insertingIfAbsent(
            inserted,
            into: tasksByProject[inserted.projectId] ?? []
        )
        selectTask(inserted, project: project)
        return inserted
    }

    static func insertingIfAbsent(_ task: TaskRecord, into tasks: [TaskRecord]) -> [TaskRecord] {
        guard !tasks.contains(where: { $0.id == task.id }) else { return tasks }
        return [task] + tasks
    }

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
        if let id = task.id {
            discardBusyAndUnread(id)
        }
    }

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
        discardBusyAndUnread(id)
    }

    private func discardBusyAndUnread(_ taskId: Int64) {
        busyTaskIDs.remove(taskId)
        unreadTaskIDs.remove(taskId)
    }

    // MARK: - Pi conversations

    public func activeConversation(forTaskId taskId: Int64) async -> Conversation? {
        try? await database.dbQueue.read { db in
            try Conversation
                .filter(Conversation.Columns.taskId == taskId)
                .filter(Conversation.Columns.isActive == true)
                .order(Conversation.Columns.startedAt.desc)
                .fetchOne(db)
        }
    }

    @discardableResult
    public func startConversation(for task: TaskRecord, sessionID: String) async throws -> Conversation {
        let conversation = Conversation(taskId: task.id ?? 0, sessionId: sessionID, transcriptPath: "")
        return try await database.dbQueue.write { db in
            var conversation = conversation
            try conversation.insert(db)
            return conversation
        }
    }

    public func recordTranscriptPath(_ path: String, for conversation: Conversation) async throws {
        guard let id = conversation.id else { return }
        try await database.dbQueue.write { db in
            guard var updated = try Conversation.fetchOne(db, key: id) else { return }
            updated.transcriptPath = path
            try updated.update(db)
        }
    }

    public func task(withId id: Int64) -> TaskRecord? {
        tasksByProject.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    public var titleGenerator: (String) async -> String? = TaskTitleGenerator.generate

    public func applyAutoRename(task: TaskRecord, project: Project, prompt: String) async {
        guard task.awaitingAutoRename else { return }

        let title: String
        if let modelTitle = await titleGenerator(prompt) {
            title = modelTitle
        } else if let heuristicTitle = TaskAutoRenameService.deriveTitle(fromPrompt: prompt) {
            Self.logger.notice(
                "auto-rename falling back to heuristic title for task \(task.id ?? -1, privacy: .public)"
            )
            title = heuristicTitle
        } else {
            await clearAwaitingAutoRename(task)
            return
        }

        let renamed = await TaskAutoRenameService.applyRename(task: task, project: project, newName: title)
        guard let id = task.id else { return }
        try? await database.dbQueue.write { db in
            guard var updated = try TaskRecord.fetchOne(db, key: id) else { return }
            updated.name = renamed.name
            updated.branchName = renamed.branchName
            updated.worktreePath = renamed.worktreePath
            updated.awaitingAutoRename = false
            try updated.update(db)
        }
    }

    private func clearAwaitingAutoRename(_ task: TaskRecord) async {
        guard let id = task.id else { return }
        try? await database.dbQueue.write { db in
            guard var updated = try TaskRecord.fetchOne(db, key: id) else { return }
            updated.awaitingAutoRename = false
            try updated.update(db)
        }
    }

    /// A legacy task with no `baseCommit` gets one backfilled from `syncStatus`'s reflog fallback so the lookup isn't repeated.
    public func refreshSyncStatus(for task: TaskRecord, project: Project) async {
        guard let id = task.id else { return }
        guard let status = try? await TaskWorktreeService.syncStatus(
            project: project,
            branchName: task.branchName,
            baseCommit: task.baseCommit,
            worktreePath: task.worktreePath
        ) else {
            return
        }
        syncStatusByTask[id] = status
        if task.baseCommit == nil, let resolvedBaseCommit = status.resolvedBaseCommit {
            try? await database.dbQueue.write { db in
                guard var updated = try TaskRecord.fetchOne(db, key: id) else { return }
                updated.baseCommit = resolvedBaseCommit
                try updated.update(db)
            }
            if let index = tasksByProject[task.projectId]?.firstIndex(where: { $0.id == id }) {
                tasksByProject[task.projectId]?[index].baseCommit = resolvedBaseCommit
            }
        }
    }

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
        (try? await database.dbQueue.read { db in
            try Project.order(Project.Columns.sortOrder, Project.Columns.id).fetchAll(db)
        }) ?? []
    }

    private func allTasks(forProjectId projectId: Int64) async throws -> [TaskRecord] {
        try await database.dbQueue.read { db in
            try TaskRecord.filter(TaskRecord.Columns.projectId == projectId).fetchAll(db)
        }
    }
}
