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

    @Test("finds the first user message's plain-string content")
    func findsFirstUserPromptAsPlainString() {
        let userMessage = #"{"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"user","content":"fix the login bug","timestamp":123}}"#
        let lines = [header, sessionInfo, modelChange, thinkingChange, systemMessage, userMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == "fix the login bug")
    }

    @Test("finds the first user message's text block among a content array")
    func findsFirstUserPromptFromContentBlocks() {
        let userMessage = #"""
        {"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"user","content":[{"type":"text","text":"fix the login bug"}],"timestamp":123}}
        """#
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

    @Test("skips a tool result line that precedes the first user message, ignoring it as noise")
    func skipsToolResultPrecedingNothing() {
        let toolResult = #"""
        {"type":"message","id":"z","parentId":"y","timestamp":"2026-09-22T18:47:13Z","message":{"role":"toolResult","toolCallId":"t1","toolName":"bash","content":[{"type":"text","text":"stray output"}]}}
        """#
        let userMessage = #"{"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"user","content":"real prompt"}}"#
        let lines = [header, toolResult, userMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == "real prompt")
    }

    @Test("ignores assistant messages and returns the first user message that follows them")
    func ignoresAssistantMessagesBeforeFirstUser() {
        let assistantMessage = #"""
        {"type":"message","id":"x","parentId":"w","timestamp":"2026-09-22T18:47:13Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"planning..."},{"type":"text","text":"Working on it."}]}}
        """#
        let userMessage = #"{"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"user","content":"add dark mode"}}"#
        let lines = [header, assistantMessage, userMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == "add dark mode")
    }

    @Test("empty lines and blank lines between records are skipped without error")
    func toleratesBlankLines() {
        let userMessage = #"{"type":"message","id":"e","parentId":"d","timestamp":"2026-09-22T18:47:14Z","message":{"role":"user","content":"add dark mode"}}"#
        let lines = [header, "", "   ", userMessage]

        #expect(TaskAutoRenameService.firstUserPromptText(inTranscriptLines: lines) == "add dark mode")
    }
}

@Suite("TaskAutoRenameService title derivation")
struct TaskAutoRenameServiceTitleTests {
    @Test("strips markdown emphasis, code, and heading markers")
    func stripsMarkdown() {
        let title = TaskAutoRenameService.deriveTitle(fromPrompt: "fix the `login()` **bug** in #urgent module")
        #expect(title == "fix the login() bug in urgent module")
    }

    @Test("strips leading punctuation like list markers and quotes")
    func stripsLeadingPunctuation() {
        let title = TaskAutoRenameService.deriveTitle(fromPrompt: "- fix the bug")
        #expect(title == "fix the bug")
    }

    @Test("collapses internal whitespace, including newlines and tabs, into single spaces")
    func collapsesWhitespace() {
        let title = TaskAutoRenameService.deriveTitle(fromPrompt: "fix   the\n\nlogin\tbug")
        #expect(title == "fix the login bug")
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

        // The worktree directory must never move — doing so out from under a
        // live pi process breaks its tools and its session transcript lookup.
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

        // An unrelated existing task already occupies the branch the rename would target.
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
        // The worktree directory never moves, dedupe or not.
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

        // Calling it again must not re-fire: the flag is already clear, so a
        // caller guarding on it (as `MainAreaView`'s watcher does) will stop.
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

    @Test("a blank-name task gets a stable new-task-<hex> worktree directory, not one derived from the placeholder title")
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

        let expectedPrefix = "\(repoURL.path)-worktrees/new-task-"
        #expect(task.worktreePath.hasPrefix(expectedPrefix))
        let slug = String(task.worktreePath.dropFirst(expectedPrefix.count))
        #expect(slug.count == 4)
        #expect(slug.allSatisfy { $0.isHexDigit })
        #expect(task.branchName == "task/new-task-\(slug)")
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
        let task = try await store.createTask(project: insertedProject, name: "")

        await store.applyAutoRename(task: task, project: insertedProject, prompt: "```")

        let refetched = try await database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, key: task.id!)
        }
        #expect(refetched?.name == "New Task")
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

        // A real transcript, as pi would have written it while the task's
        // worktree was still at its pre-rename path: the header `cwd` names
        // that original worktree, and the file itself sits under a sessions
        // subdirectory keyed by that same (now stale) path.
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

        // Simulate a task whose worktree was already relocated by an older
        // build's auto-rename, before it stopped moving worktree
        // directories — `TaskAutoRenameService.applyRename` no longer does
        // this itself, but tasks already moved by a prior version still need
        // to resume correctly.
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
        // Every remaining line survives the rewrite byte-for-byte.
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
