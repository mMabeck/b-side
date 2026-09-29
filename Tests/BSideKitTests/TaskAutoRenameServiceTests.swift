import Foundation
import Testing

@testable import BSideKit

@Suite("TaskAutoRenameService transcript parsing")
struct TaskAutoRenameServiceTranscriptTests {
    private let header = #"{"type":"session","version":1,"id":"s1","timestamp":"2026-09-22T18:47:13.521Z","cwd":"/tmp/repo"}"#
    private let sessionInfo = #"{"type":"session_info","id":"a","parentId":null,"timestamp":"2026-09-22T18:47:13Z","name":null}"#
    private let modelChange = #"{"type":"model_change","id":"b","parentId":"a","timestamp":"2026-09-22T18:47:13Z","provider":"anthropic","modelId":"claude-x"}"#
    private let thinkingChange = #"{"type":"thinking_level_change","id":"c","parentId":"b","timestamp":"2026-09-22T18:47:13Z","thinkingLevel":"medium"}"#
    private let systemMessage = #"{"type":"message","id":"d","parentId":"c","timestamp":"2026-09-22T18:47:13Z","message":{"role":"system","content":"","sections":{"preamble":"you are pi"}}}"#

    @Test("finds the first user message's content, whether a plain string or a text-block array", arguments: [
        "\"fix the login bug\"",
        "[{\"type\":\"text\",\"text\":\"fix the login bug\"}]",
    ])
    func findsFirstUserPrompt(contentJSON: String) {
        let userMessage = "{\"type\":\"message\",\"id\":\"e\",\"parentId\":\"d\",\"timestamp\":\"2026-09-22T18:47:14Z\",\"message\":{\"role\":\"user\",\"content\":\(contentJSON),\"timestamp\":123}}"
        let lines = [header, sessionInfo, modelChange, thinkingChange, systemMessage, userMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == "fix the login bug")
    }

    @Test("returns nil for a transcript with no user message yet")
    func returnsNilWithoutAUserMessage() {
        let assistantMessage = #"""
        {"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"assistant","content":[{"type":"text","text":"Hello, how can I help?"}]}}
        """#
        let lines = [header, sessionInfo, modelChange, thinkingChange, systemMessage, assistantMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == nil)
    }

    @Test("a tool result, an assistant message, or blank lines preceding the first user message are all skipped as noise", arguments: [
        [#"{"type":"message","id":"z","parentId":"y","timestamp":"2026-09-22T18:47:13Z","message":{"role":"toolResult","toolCallId":"t1","toolName":"bash","content":[{"type":"text","text":"stray output"}]}}"#],
        [#"{"type":"message","id":"x","parentId":"w","timestamp":"2026-09-22T18:47:13Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"planning..."},{"type":"text","text":"Working on it."}]}}"#],
        ["", "   "],
    ])
    func skipsNoiseBeforeFirstUserMessage(precedingLines: [String]) {
        let userMessage = #"{"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"user","content":"real prompt"}}"#
        let lines = [header] + precedingLines + [userMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == "real prompt")
    }
}

@Suite("TaskAutoRenameService title derivation")
struct TaskAutoRenameServiceTitleTests {
    @Test("cleans up markdown, leading punctuation, and internal whitespace", arguments: [
        ("fix the `login()` **bug** in #urgent module", "fix the login() bug in urgent module"),
        ("- fix the bug", "fix the bug"),
        ("fix   the\n\nlogin\tbug", "fix the login bug"),
    ])
    func cleansUpPromptFormatting(prompt: String, expected: String) {
        #expect(TaskAutoRenameService.deriveTitle(fromPrompt: prompt) == expected)
    }

    @Test("truncates long prompts at a word boundary near the max length")
    func truncatesAtWordBoundary() {
        let prompt = "please refactor the entire authentication module to support multiple identity providers and single sign-on"
        let title = TaskAutoRenameService.deriveTitle(fromPrompt: prompt, maxLength: 48)

        #expect(title != nil)
        #expect(title!.count <= 48)
        #expect(!prompt.hasPrefix(title! + "authentic"))
        #expect(prompt.hasPrefix(title!))
        #expect(title!.last != " ")
    }

    @Test("leaves short prompts untouched aside from trimming")
    func leavesShortPromptsUntouched() {
        #expect(TaskAutoRenameService.deriveTitle(fromPrompt: "fix bug") == "fix bug")
    }

    @Test("degenerate all-punctuation input yields nil")
    func degenerateInputYieldsNil() {
        #expect(TaskAutoRenameService.deriveTitle(fromPrompt: "```") == nil)
        #expect(TaskAutoRenameService.deriveTitle(fromPrompt: "   ") == nil)
        #expect(TaskAutoRenameService.deriveTitle(fromPrompt: "!!!---***") == nil)
        #expect(TaskAutoRenameService.deriveTitle(fromPrompt: "") == nil)
    }
}

@Suite("TaskAutoRenameService applyRename")
struct TaskAutoRenameServiceApplyRenameTests {
    @Test("renames the branch but never moves the worktree directory")
    func renamesBranchButKeepsWorktreePath() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let setupResult = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "New Task",
            baseRef: "main"
        )

        let task = TaskRecord(
            id: 1,
            projectId: 1,
            name: "New Task",
            branchName: setupResult.branchName,
            branchCreatedByApp: setupResult.branchCreatedByApp,
            worktreePath: setupResult.worktreePath,
            harness: "claude",
            permissionLevel: "default",
            awaitingAutoRename: true
        )

        let renamed = await TaskAutoRenameService.applyRename(task: task, project: project, newName: "Fix the login bug")

        #expect(renamed.name == "Fix the login bug")
        #expect(renamed.awaitingAutoRename == false)
        #expect(renamed.branchName == "task/fix-the-login-bug")

        // Moving the worktree under a live pi breaks its tools and transcript lookup.
        #expect(renamed.worktreePath == task.worktreePath)
        #expect(FileManager.default.fileExists(atPath: renamed.worktreePath))

        let currentBranch = await GitCLI.currentBranch(at: URL(fileURLWithPath: renamed.worktreePath))
        #expect(currentBranch == "task/fix-the-login-bug")

        let oldBranchExists = try await GitCLI.branchExists(task.branchName, at: repoURL)
        #expect(oldBranchExists == false)
    }

    @Test("a task without its own worktree renames its name only")
    func renamesNameOnlyWhenRunningInPlace() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let task = TaskRecord(
            id: 1,
            projectId: 1,
            name: "New Task",
            branchName: "main",
            branchCreatedByApp: false,
            worktreePath: project.path,
            harness: "claude",
            permissionLevel: "default",
            awaitingAutoRename: true
        )

        let renamed = await TaskAutoRenameService.applyRename(task: task, project: project, newName: "Fix the login bug")

        #expect(renamed.name == "Fix the login bug")
        #expect(renamed.awaitingAutoRename == false)
        #expect(renamed.branchName == "main")
        #expect(renamed.worktreePath == project.path)
    }

    @Test("a pre-existing (not app-created) branch is left alone; only the name is renamed")
    func doesNotRenameAPreExistingBranch() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        _ = try await GitCLI.run(["branch", "feature/existing"], in: repoURL)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let setupResult = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "New Task",
            existingBranch: "feature/existing"
        )

        let task = TaskRecord(
            id: 1,
            projectId: 1,
            name: "New Task",
            branchName: setupResult.branchName,
            branchCreatedByApp: setupResult.branchCreatedByApp,
            worktreePath: setupResult.worktreePath,
            harness: "claude",
            permissionLevel: "default",
            awaitingAutoRename: true
        )

        let renamed = await TaskAutoRenameService.applyRename(task: task, project: project, newName: "Fix the login bug")

        #expect(renamed.name == "Fix the login bug")
        #expect(renamed.branchName == "feature/existing")
        #expect(renamed.worktreePath == task.worktreePath)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test("dedupes against an already-taken branch name by suffixing")
    func dedupesAgainstAnAlreadyTakenName() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        _ = try await TaskWorktreeService.createWorktree(for: project, taskName: "Fix the bug", baseRef: "main")

        let setupResult = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "New Task",
            baseRef: "main"
        )
        let task = TaskRecord(
            id: 2,
            projectId: 1,
            name: "New Task",
            branchName: setupResult.branchName,
            branchCreatedByApp: setupResult.branchCreatedByApp,
            worktreePath: setupResult.worktreePath,
            harness: "claude",
            permissionLevel: "default",
            awaitingAutoRename: true
        )

        let renamed = await TaskAutoRenameService.applyRename(task: task, project: project, newName: "Fix the bug")

        #expect(renamed.branchName == "task/fix-the-bug-2")
        #expect(renamed.worktreePath == task.worktreePath)
    }
}

@Suite("ProjectsStore auto-rename")
struct ProjectsStoreAutoRenameTests {
    @Test("applyAutoRename renames a placeholder task exactly once and leaves an explicitly-named task alone")
    func rendersOnlyPlaceholderTasksAndOnlyOnce() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let database = try AppDatabase.openInMemory()
        let project = Project(path: repoURL.path, displayName: "repo", baseRef: "main")
        let insertedProject = try await database.dbQueue.write { db -> Project in
            var project = project
            try project.insert(db)
            return project
        }

        let store = await ProjectsStore(database: database)
        await MainActor.run { store.titleGenerator = { _ in nil } }
        let placeholderTask = try await store.createTask(project: insertedProject, name: "")
        #expect(placeholderTask.awaitingAutoRename == true)

        let namedTask = try await store.createTask(project: insertedProject, name: "Explicit name")
        #expect(namedTask.awaitingAutoRename == false)

        await store.applyAutoRename(task: placeholderTask, project: insertedProject, prompt: "fix the login bug")

        let refetchedPlaceholder = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: placeholderTask.id!)
        }
        #expect(refetchedPlaceholder?.name == "fix the login bug")
        #expect(refetchedPlaceholder?.awaitingAutoRename == false)

        await store.applyAutoRename(task: refetchedPlaceholder!, project: insertedProject, prompt: "a different prompt entirely")
        let refetchedAgain = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: placeholderTask.id!)
        }
        #expect(refetchedAgain?.name == "fix the login bug")

        let refetchedNamed = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: namedTask.id!)
        }
        #expect(refetchedNamed?.name == "Explicit name")
    }

    @Test("a blank-name task gets a stable <adjective>-<noun>-<hex> worktree directory, not one derived from the placeholder title")
    func blankNameTaskGetsNeutralWorktreeSlug() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let database = try AppDatabase.openInMemory()
        let project = Project(path: repoURL.path, displayName: "repo", baseRef: "main")
        let insertedProject = try await database.dbQueue.write { db -> Project in
            var project = project
            try project.insert(db)
            return project
        }

        let store = await ProjectsStore(database: database)
        let task = try await store.createTask(project: insertedProject, name: "")

        let expectedPrefix = "\(repoURL.path)-worktrees/"
        #expect(task.worktreePath.hasPrefix(expectedPrefix))
        let slug = String(task.worktreePath.dropFirst(expectedPrefix.count))
        let parts = slug.split(separator: "-").map(String.init)
        #expect(parts.count == 3)
        #expect(TaskWorktreeService.slugAdjectives.contains(parts[0]))
        #expect(TaskWorktreeService.slugNouns.contains(parts[1]))
        #expect(parts[2].count == 4 && parts[2].allSatisfy { $0.isHexDigit })
        #expect(task.branchName == "task/\(slug)")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test("applyAutoRename with a degenerate prompt clears the flag and leaves the placeholder name")
    func degeneratePromptLeavesPlaceholderName() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let database = try AppDatabase.openInMemory()
        let project = Project(path: repoURL.path, displayName: "repo", baseRef: "main")
        let insertedProject = try await database.dbQueue.write { db -> Project in
            var project = project
            try project.insert(db)
            return project
        }

        let store = await ProjectsStore(database: database)
        await MainActor.run { store.titleGenerator = { _ in nil } }
        let task = try await store.createTask(project: insertedProject, name: "")

        await store.applyAutoRename(task: task, project: insertedProject, prompt: "```")

        let refetched = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: task.id!)
        }
        #expect(refetched?.name == "New Task")
        #expect(refetched?.awaitingAutoRename == false)
    }

    @Test("applyAutoRename falls back to the heuristic title when the injected generator returns nil")
    func fallsBackToHeuristicWhenGeneratorReturnsNil() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let database = try AppDatabase.openInMemory()
        let project = Project(path: repoURL.path, displayName: "repo", baseRef: "main")
        let insertedProject = try await database.dbQueue.write { db -> Project in
            var project = project
            try project.insert(db)
            return project
        }

        let store = await ProjectsStore(database: database)
        await MainActor.run { store.titleGenerator = { _ in nil } }
        let task = try await store.createTask(project: insertedProject, name: "")

        await store.applyAutoRename(task: task, project: insertedProject, prompt: "fix the login bug")

        let refetched = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: task.id!)
        }
        #expect(refetched?.name == "fix the login bug")
        #expect(refetched?.branchName == "task/fix-the-login-bug")
        #expect(refetched?.awaitingAutoRename == false)
    }

    @Test("applyAutoRename uses the injected generator's title for both the task name and the branch slug")
    func usesModelTitleForNameAndBranchSlug() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let database = try AppDatabase.openInMemory()
        let project = Project(path: repoURL.path, displayName: "repo", baseRef: "main")
        let insertedProject = try await database.dbQueue.write { db -> Project in
            var project = project
            try project.insert(db)
            return project
        }

        let store = await ProjectsStore(database: database)
        await MainActor.run { store.titleGenerator = { _ in "Fix Login Bug" } }
        let task = try await store.createTask(project: insertedProject, name: "")

        await store.applyAutoRename(task: task, project: insertedProject, prompt: "the login page throws a 500, please fix")

        let refetched = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: task.id!)
        }
        #expect(refetched?.name == "Fix Login Bug")
        #expect(refetched?.branchName == "task/fix-login-bug")
        #expect(refetched?.awaitingAutoRename == false)
    }
}

@Suite("Resuming a task whose worktree was already moved by an older build")
struct AutoRenameSessionResumeTests {
    @Test("resuming a task whose worktree was moved by a pre-fix auto-rename still repairs the transcript's header cwd")
    func resumeStillTargetsSameTranscriptAfterLegacyMove() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let setupResult = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "New Task",
            baseRef: "main"
        )
        let task = TaskRecord(
            id: 1,
            projectId: 1,
            name: "New Task",
            branchName: setupResult.branchName,
            branchCreatedByApp: setupResult.branchCreatedByApp,
            worktreePath: setupResult.worktreePath,
            harness: "claude",
            permissionLevel: "default",
            awaitingAutoRename: true
        )

        // Transcript as pi wrote it before the rename: header cwd and sessions subdirectory use the old path.
        let sessionID = PiSessionService.newSessionID()
        let resolvedOldWorktreePath = URL(fileURLWithPath: task.worktreePath).resolvingSymlinksInPath().path
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"\(sessionID)\"," +
            "\"timestamp\":\"2026-09-22T18:47:13.521Z\",\"cwd\":\"\(resolvedOldWorktreePath)\"}"
        let bodyLine = "{\"type\":\"message\",\"id\":\"e\",\"parentId\":\"d\"," +
            "\"timestamp\":\"2026-09-22T18:47:14Z\",\"message\":{\"role\":\"user\",\"content\":\"fix the login bug\"}}"
        let sessionsRoot = root.appendingPathComponent("sessions")
        let originalTranscriptURL = sessionsRoot.appendingPathComponent("--some-old-slug--/20260101_abc.jsonl")
        try FileManager.default.createDirectory(
            at: originalTranscriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(header)\n\(bodyLine)\n".write(to: originalTranscriptURL, atomically: true, encoding: .utf8)

        let conversation = Conversation(taskId: 1, sessionId: sessionID, transcriptPath: originalTranscriptURL.path)
        let locations = PiSessionService.Locations(
            bundledBinaryPath: "/usr/local/bin/pi",
            sessionsRoot: sessionsRoot,
            pathBinaryFinder: { nil }
        )

        // A worktree already relocated by an older build's auto-rename must still resume.
        let movedWorktreePath = "\(repoURL.path)-worktrees/fix-the-login-bug"
        try await GitCLI.moveWorktree(
            from: URL(fileURLWithPath: task.worktreePath),
            to: URL(fileURLWithPath: movedWorktreePath),
            in: repoURL
        )

        #expect(try Data(contentsOf: originalTranscriptURL) == "\(header)\n\(bodyLine)\n".data(using: .utf8))

        let repairedPath = PiSessionService.repairTranscriptForResume(
            transcriptPath: conversation.transcriptPath,
            currentWorkingDirectory: movedWorktreePath,
            locations: locations
        )
        let resolvedNewWorktreePath = URL(fileURLWithPath: movedWorktreePath).resolvingSymlinksInPath().path

        let repairedPathValue = try #require(repairedPath)
        let repairedContents = try String(contentsOf: URL(fileURLWithPath: repairedPathValue), encoding: .utf8)
        let repairedLines = repairedContents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let repairedHeaderData = try #require(repairedLines[0].data(using: .utf8))
        let repairedHeader = try #require(JSONSerialization.jsonObject(with: repairedHeaderData) as? [String: Any])

        #expect(repairedHeader["cwd"] as? String == resolvedNewWorktreePath)
        #expect(repairedHeader["id"] as? String == sessionID)
        #expect(repairedHeader["version"] as? Int == 3)
        #expect(Array(repairedLines.dropFirst()) == [bodyLine, ""])

        let afterRenameCommand = PiSessionService.launchCommand(
            locations: locations,
            sessionID: conversation.sessionId,
            transcriptPath: repairedPathValue,
            taskName: task.name
        )
        #expect(afterRenameCommand.contains("--session '\(repairedPathValue)'"))
    }
}
