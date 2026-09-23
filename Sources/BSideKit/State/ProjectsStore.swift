import AppKit
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

    /// The project a bare "new task" action (Cmd+N, File › New Task) should
    /// target: the selected task's own project when a task is selected —
    /// since a task is always the more specific selection — else the selected
    /// project itself, else `nil` so the action can no-op instead of guessing.
    /// Pure and derived from the same selection `mainSelection` already
    /// resolves, so Cmd+N can never target a different project than the one
    /// the sidebar/dashboard currently show as selected.
    public var taskCreationTarget: Project? {
        switch self {
        case .none: return nil
        case .project(let project): return project
        case .task(_, let project): return project
        }
    }
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

    /// Task ids whose sidebar row should read as "needs attention" because a
    /// terminal alert classified as a question arrived for them — cleared
    /// the next time that task is selected. See `handleTerminalAlert`.
    public private(set) var taskIDsNeedingAttention: Set<Int64> = []

    /// Last time a terminal alert was accepted (post-debounce) for a task,
    /// keyed by task id — feeds `TaskAlertDebouncer.isDebounced`.
    private var lastTerminalAlertAt: [Int64: Date] = [:]

    /// Plays the configured sound for an accepted terminal alert. Swappable
    /// so tests exercising `handleTerminalAlert` don't play real system
    /// sounds on every `swift test` run.
    @ObservationIgnored
    public var playAlertSound: @MainActor (TaskAlertKind) -> Void = { TaskAlertSoundPlayer.play(kind: $0) }

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

    /// Bumped by every `selectTask(_:project:)`/`selectProject(_:)` call,
    /// including a reselection of whatever is already selected. `MainAreaView`
    /// folds this into the id its `.task(id:)` modifier keys off of
    /// (alongside `selectedTaskID` itself) so `syncFocus()` runs on every
    /// explicit selection, not only ones that change `selectedTaskID`'s
    /// value — without it, clicking an already-selected sidebar row while
    /// focus sits elsewhere (the sidebar list itself, another window, ...)
    /// would leave keyboard focus wherever it was, since SwiftUI's
    /// `.task(id:)` only re-runs when its id actually changes.
    public private(set) var focusRequestToken: Int = 0

    /// The project a task-creation sheet should be presented for, or `nil`
    /// when no sheet should be showing. Every trigger — the sidebar's
    /// per-project "+", its context menu, the dashboard's "New Task" button,
    /// Cmd+N, and the File menu — sets this instead of keeping its own
    /// `@State` sheet flag. A single `ProjectsStore`-owned optional, presented
    /// once (in `ContentView`), means it is structurally impossible for two
    /// of those triggers to end up presenting the sheet twice or leaving it
    /// stuck open pointed at a stale project.
    public var pendingTaskCreationProject: Project?

    public var selectedTask: TaskRecord? {
        guard let selectedTaskID else { return nil }
        return tasksByProject.values.lazy.flatMap { $0 }.first { $0.id == selectedTaskID }
    }

    /// Task ids with a live `TerminalSurfaceHost` in `MainAreaView`, ordered
    /// by when each terminal was first opened — not by project/task list
    /// order, so "Cmd+1" always means "the task I opened first", not
    /// whichever task happens to sort first. Owned here rather than as
    /// private `MainAreaView` state so the sidebar's "Active" section and
    /// `NavigationShortcuts` can both read it; `MainAreaView` is still the
    /// only writer, via `noteTerminalOpened(taskID:)`/`pruneOpenTerminals(keeping:)`,
    /// mirroring its own `hostsByTaskID` one-for-one.
    public private(set) var openTerminalTaskIDs: [Int64] = []

    /// Records that `taskID` now has a live terminal host, appending it to
    /// the end of `openTerminalTaskIDs` if it isn't tracked yet. A no-op for
    /// an id already present, since `MainAreaView.ensureHost` only ever
    /// creates a host once per task and re-selecting an existing terminal
    /// must not reorder it.
    public func noteTerminalOpened(taskID: Int64) {
        openTerminalTaskIDs = Self.addingOpenTerminal(taskID, to: openTerminalTaskIDs)
    }

    /// Drops every id in `removed` from `openTerminalTaskIDs`, called from
    /// `MainAreaView.purgeHosts` with the same ids it evicts from
    /// `hostsByTaskID` so the two never disagree about which tasks still
    /// have a live terminal.
    public func pruneOpenTerminals(removing removed: Set<Int64>) {
        openTerminalTaskIDs = Self.removingOpenTerminals(removed, from: openTerminalTaskIDs)
    }

    /// The task id, if any, whose terminal should become the active
    /// selection after `taskID`'s terminal closes: the entry that took
    /// `taskID`'s position in `openTaskIDs` once it's removed (i.e. the
    /// "next" active task), or the new last entry if `taskID` was the last
    /// one open. `nil` once no terminals remain open. Pure so it's directly
    /// testable without a live store.
    static func nextActiveTaskID(afterClosing taskID: Int64, in openTaskIDs: [Int64]) -> Int64? {
        guard let index = openTaskIDs.firstIndex(of: taskID) else { return nil }
        let remaining = removingOpenTerminals([taskID], from: openTaskIDs)
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)]
    }

    /// Task id whose terminal `MainAreaView` should tear down next — set by
    /// `closeTerminal(for:project:)`, observed and cleared (via
    /// `acknowledgeTerminalClosed`) by `MainAreaView` once it has actually
    /// purged that task's `TerminalSurfaceHost`. A one-shot request rather
    /// than a queue: only one Cmd+W can happen at a time, and `MainAreaView`
    /// acts on it before the next one can be issued.
    public private(set) var closedTerminalTaskID: Int64?

    /// Ends `task`'s terminal: drops it from `openTerminalTaskIDs` (so it
    /// leaves the sidebar's "Active" section immediately) and requests that
    /// `MainAreaView` tear down its `TerminalSurfaceHost` via
    /// `closedTerminalTaskID`. The task itself is untouched — still in the
    /// sidebar, its worktree and pi session transcript intact for next time
    /// it's opened. Selects the next sensible target: the task that took
    /// its place among open terminals, or else `project`'s own dashboard.
    public func closeTerminal(for task: TaskRecord, project: Project) {
        guard let id = task.id else { return }
        let nextID = Self.nextActiveTaskID(afterClosing: id, in: openTerminalTaskIDs)
        openTerminalTaskIDs = Self.removingOpenTerminals([id], from: openTerminalTaskIDs)
        closedTerminalTaskID = id
        if let nextID, let match = taskAndProject(forID: nextID) {
            selectTask(match.task, project: match.project)
        } else {
            selectProject(project)
        }
    }

    /// Clears `closedTerminalTaskID` once `MainAreaView` has purged the
    /// host for `id` — a no-op if a different (or no) close request is
    /// currently pending, so a stale acknowledgement can't clear a newer
    /// request.
    public func acknowledgeTerminalClosed(_ id: Int64) {
        guard closedTerminalTaskID == id else { return }
        closedTerminalTaskID = nil
    }

    /// Pure so it's directly testable: appends `id` only if it isn't
    /// already present, preserving the existing order of everything else.
    static func addingOpenTerminal(_ id: Int64, to ids: [Int64]) -> [Int64] {
        ids.contains(id) ? ids : ids + [id]
    }

    /// Pure so it's directly testable: removes every id in `removed`,
    /// preserving the relative order of what remains.
    static func removingOpenTerminals(_ removed: Set<Int64>, from ids: [Int64]) -> [Int64] {
        ids.filter { !removed.contains($0) }
    }

    /// Looks up the (task, owning project) pair for an arbitrary task id —
    /// unlike `selectedTask`, not tied to the current selection. Used by the
    /// sidebar's "Active" section and `NavigationShortcuts` to resolve an
    /// `openTerminalTaskIDs` entry into something `selectTask(_:project:)`
    /// can target.
    public func taskAndProject(forID id: Int64) -> (task: TaskRecord, project: Project)? {
        for (projectID, tasks) in tasksByProject {
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            guard let project = projects.first(where: { $0.id == projectID }) else { continue }
            return (task, project)
        }
        return nil
    }

    /// Selects `project` for the sidebar/dashboard and clears any task
    /// selection: a project on its own is never a terminal, so picking one
    /// always evicts whatever task terminal was showing.
    public func selectProject(_ project: Project) {
        selectedProjectID = project.id
        selectedTaskID = nil
        focusRequestToken += 1
    }

    /// Selects `task` and, since a task's terminal is meaningless without
    /// knowing which project owns it, its project too — the two selections
    /// are set together so they can never disagree.
    public func selectTask(_ task: TaskRecord, project: Project) {
        selectedProjectID = project.id
        selectedTaskID = task.id
        if let id = task.id {
            taskIDsNeedingAttention.remove(id)
        }
        focusRequestToken += 1
    }

    // MARK: - Terminal alerts

    /// A terminal's OSC 777/OSC 9 desktop notification, classified and
    /// routed: plays the configured sound, marks the task's sidebar row
    /// needing attention for a question, and posts a native notification
    /// unless B-Side is frontmost and already showing this task.
    public func handleTerminalDesktopNotification(taskID: Int64, title: String, body: String) {
        handleTerminalAlert(
            taskID: taskID,
            kind: TaskAlertClassifier.classify(title: title, body: body),
            title: title,
            body: body
        )
    }

    /// A terminal bell — always classified as a question, per the same
    /// reasoning Pi's own notify extension uses `SOUND_QUESTION` for a bell:
    /// a bare bell with no OSC 777 text is a program (Claude Code, a shell
    /// prompt) asking for attention with nothing more specific to say.
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
        }

        guard UserDefaults.standard.object(forKey: TaskAlertSettingsKeys.enabled) as? Bool ?? true else { return }
        let isFrontmostAndSelected = NSApp?.isActive == true && selectedTaskID == taskID
        guard !isFrontmostAndSelected else { return }

        let taskName = taskAndProject(forID: taskID)?.task.name ?? "Task"
        TaskAlertNotificationCenter.shared.notify(taskID: taskID, taskName: taskName, title: title, body: body)
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

        TaskAlertNotificationCenter.shared.activateIfSupported()
        TaskAlertNotificationCenter.shared.onSelectTask = { [weak self] taskID in
            guard let self, let pair = self.taskAndProject(forID: taskID) else { return }
            self.selectTask(pair.task, project: pair.project)
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

    /// Persists a new default base ref for `project`, e.g. when a task is
    /// created from a base other than the project's saved default. Updates
    /// `projects` in place too, so a task-creation sheet opened right after
    /// preselects the new default without waiting for the next
    /// `ValueObservation` tick.
    public func updateProjectBaseRef(_ project: Project, baseRef: String) async throws {
        guard let id = project.id else { return }
        try await database.dbQueue.write { db in
            var updated = project
            updated.baseRef = baseRef
            try updated.update(db)
        }
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].baseRef = baseRef
        }
    }

    // MARK: - Tasks and worktrees

    /// Creates a task: resolves the base ref, creates (or attaches to) a branch
    /// and worktree, copies ignored files, runs setup, then persists the task.
    /// `onOutput` streams setup command output for display while creation is
    /// still in progress. A blank `name` falls back to the placeholder "New Task".
    /// `useWorktree` defaults to the project's `ProjectConfig` setting when omitted.
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
            baseSlugOverride: nameWasBlank ? TaskWorktreeService.randomNewTaskSlug() : nil,
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
            awaitingAutoRename: nameWasBlank
        )
        let inserted = try await database.dbQueue.write { db in
            var task = task
            try task.insert(db)
            return task
        }
        // A newly created task should replace whatever the user was looking
        // at before, so its terminal comes up and takes focus immediately
        // instead of leaving the sheet's dismissal reveal the prior
        // project/task selection underneath. Only reached on success — a
        // throwing `createWorktree` above leaves selection untouched.
        //
        // `mainSelection` resolves `selectedTaskID` against `tasksByProject`,
        // which only reflects this insert once the `ValueObservation` loop in
        // `start()` re-fires — asynchronously, after this write already
        // committed. Folding `inserted` into `tasksByProject` here too, ahead
        // of that refresh, means `selectTask` below resolves to `.task`
        // immediately instead of a stale `.project`/`.none` that only
        // self-corrects once the observation catches up. The later refresh
        // overwrites this with the same (authoritative) row, so it's harmless.
        tasksByProject[inserted.projectId, default: []].append(inserted)
        selectTask(inserted, project: project)
        return inserted
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

    // MARK: - Pi conversations

    /// The task's current active conversation — the most recently started
    /// one still marked active — or `nil` if its agent terminal has never
    /// been launched. `MainAreaView` reuses this instead of starting a new
    /// conversation so reopening a task resumes the same pi session.
    public func activeConversation(forTaskId taskId: Int64) async -> Conversation? {
        try? await database.dbQueue.read { db in
            try Conversation
                .filter(Conversation.Columns.taskId == taskId)
                .filter(Conversation.Columns.isActive == true)
                .order(Conversation.Columns.startedAt.desc)
                .fetchOne(db)
        }
    }

    /// Starts and persists a new conversation for `task` under `sessionID`,
    /// with no transcript path yet — pi creates the transcript file itself
    /// shortly after launch; `recordTranscriptPath` fills it in once
    /// `PiSessionService.locateTranscript` resolves it on disk.
    @discardableResult
    public func startConversation(for task: TaskRecord, sessionID: String) async throws -> Conversation {
        let conversation = Conversation(taskId: task.id ?? 0, sessionId: sessionID, transcriptPath: "")
        return try await database.dbQueue.write { db in
            var conversation = conversation
            try conversation.insert(db)
            return conversation
        }
    }

    /// Records the transcript path resolved for `conversation` once pi has
    /// created the file on disk. A no-op if the conversation has since been
    /// deleted (e.g. its task was deleted while resolution was in flight).
    public func recordTranscriptPath(_ path: String, for conversation: Conversation) async throws {
        guard let id = conversation.id else { return }
        try await database.dbQueue.write { db in
            guard var updated = try Conversation.fetchOne(db, key: id) else { return }
            updated.transcriptPath = path
            try updated.update(db)
        }
    }

    /// The task with `id` from the current in-memory snapshot, not the
    /// database — for callers (the auto-rename watcher in `MainAreaView`)
    /// that need the freshest known state without a round trip.
    public func task(withId id: Int64) -> TaskRecord? {
        tasksByProject.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Applies the once-only automatic rename derived from a task's first pi
    /// prompt (see `TaskAutoRenameService`): renames the task, and its
    /// worktree/branch when it owns ones the app created. Always clears
    /// `awaitingAutoRename`, even when `prompt` doesn't yield a usable title,
    /// so this never re-fires for the same task.
    public func applyAutoRename(task: TaskRecord, project: Project, prompt: String) async {
        guard task.awaitingAutoRename else { return }
        guard let title = TaskAutoRenameService.deriveTitle(fromPrompt: prompt) else {
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
