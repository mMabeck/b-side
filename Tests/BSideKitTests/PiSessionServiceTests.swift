import Foundation
import GRDB
import Testing

@testable import BSideKit

@Suite("PiSessionService")
struct PiSessionServiceTests {
    private func writeTranscript(id: String, cwd: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "{\"type\":\"session\",\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}"
        let body = "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}"
        try "\(header)\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeLocations(sessionsRoot: URL, binaryPath: String? = "/usr/local/bin/pi") -> PiSessionService.Locations {
        PiSessionService.Locations(
            bundledBinaryPath: binaryPath,
            sessionsRoot: sessionsRoot,
            pathBinaryFinder: { nil }
        )
    }

    @Test("first launch for a task with no conversation targets a fresh session id")
    func firstLaunchUsesSessionID() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let locations = makeLocations(sessionsRoot: root.appendingPathComponent("sessions"))
        let sessionID = PiSessionService.newSessionID()

        let command = PiSessionService.launchCommand(
            locations: locations,
            sessionID: sessionID,
            transcriptPath: nil,
            taskName: "Fix the thing"
        )

        #expect(command == "'/usr/local/bin/pi' --session-id '\(sessionID)' --name 'Fix the thing'")
    }

    @Test("relaunch with a known transcript path resumes the same session via --session")
    func relaunchResumesSameSession() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let locations = makeLocations(sessionsRoot: root.appendingPathComponent("sessions"))
        let sessionID = PiSessionService.newSessionID()

        let firstCommand = PiSessionService.launchCommand(
            locations: locations,
            sessionID: sessionID,
            transcriptPath: nil,
            taskName: "Fix the thing"
        )

        let transcriptPath = root.appendingPathComponent("sessions/proj/20260101_abc.jsonl").path
        let secondCommand = PiSessionService.launchCommand(
            locations: locations,
            sessionID: sessionID,
            transcriptPath: transcriptPath,
            taskName: "Fix the thing"
        )

        // Same session id underlies both commands...
        #expect(firstCommand.contains(sessionID))
        // ...but the second, once the transcript is known, targets that exact
        // file rather than re-deriving the session id, and is a different
        // command shape from the first launch.
        #expect(secondCommand == "'/usr/local/bin/pi' --session '\(transcriptPath)' --name 'Fix the thing'")
        #expect(secondCommand != firstCommand)
    }

    @Test("transcript lookup finds the file whose header id matches among several sessions")
    func locatesMatchingTranscriptAmongMany() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let targetID = "target-session-id"

        try writeTranscript(
            id: "other-session-1",
            cwd: "/tmp/other1",
            at: sessionsRoot.appendingPathComponent("proj-a/20260101_000000_aaa.jsonl")
        )
        try writeTranscript(
            id: targetID,
            cwd: "/tmp/target",
            at: sessionsRoot.appendingPathComponent("proj-b/20260101_000001_bbb.jsonl")
        )
        try writeTranscript(
            id: "other-session-2",
            cwd: "/tmp/other2",
            at: sessionsRoot.appendingPathComponent("proj-b/20260101_000002_ccc.jsonl")
        )

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let found = PiSessionService.locateTranscript(sessionID: targetID, locations: locations)

        #expect(
            found?.resolvingSymlinksInPath().path
                == sessionsRoot.appendingPathComponent("proj-b/20260101_000001_bbb.jsonl").resolvingSymlinksInPath().path
        )
    }

    @Test("transcript lookup returns nil when no file's header matches")
    func locateTranscriptReturnsNilWithoutAMatch() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        try writeTranscript(
            id: "some-other-id",
            cwd: "/tmp/x",
            at: sessionsRoot.appendingPathComponent("proj/20260101_000000_aaa.jsonl")
        )

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let found = PiSessionService.locateTranscript(sessionID: "missing-id", locations: locations)

        #expect(found == nil)
    }

    @Test("falls back to a plain login shell when no pi binary can be found")
    func fallsBackToLoginShellWithoutPiBinary() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let locations = PiSessionService.Locations(
            bundledBinaryPath: nil,
            sessionsRoot: root.appendingPathComponent("sessions"),
            pathBinaryFinder: { nil }
        )

        let command = PiSessionService.launchCommand(
            locations: locations,
            sessionID: PiSessionService.newSessionID(),
            transcriptPath: nil,
            taskName: "Fix the thing",
            loginShell: "/bin/zsh"
        )

        #expect(command == "/bin/zsh -l")
    }

    @Test("launchEnvironment always sets BSIDE_TASK_ID, and BSIDE_SUBAGENT_ENDPOINT only when an endpoint is given")
    func launchEnvironmentSetsTaskIdAndOptionalEndpoint() throws {
        let withEndpoint = PiSessionService.launchEnvironment(taskId: 42, subagentEndpoint: "127.0.0.1:53123")
        #expect(withEndpoint == ["BSIDE_TASK_ID": "42", "BSIDE_SUBAGENT_ENDPOINT": "127.0.0.1:53123"])

        let withoutEndpoint = PiSessionService.launchEnvironment(taskId: 42, subagentEndpoint: nil)
        #expect(withoutEndpoint == ["BSIDE_TASK_ID": "42"])

        let withEmptyEndpoint = PiSessionService.launchEnvironment(taskId: 7, subagentEndpoint: "")
        #expect(withEmptyEndpoint == ["BSIDE_TASK_ID": "7"])
    }

    @Test("resolveBinary prefers the bundled binary over $PATH, but falls back when there's none", arguments: [
        (bundled: "/opt/pi/bin/pi", expected: "/opt/pi/bin/pi"),
        (bundled: nil, expected: "/usr/bin/pi"),
    ])
    func resolveBinaryPrecedence(bundled: String?, expected: String) throws {
        let locations = PiSessionService.Locations(
            bundledBinaryPath: bundled,
            sessionsRoot: FileManager.default.temporaryDirectory,
            pathBinaryFinder: { "/usr/bin/pi" }
        )
        #expect(PiSessionService.resolveBinary(locations: locations) == expected)
    }

    @Test("sessions subdirectory naming collapses non-alphanumerics and wraps in --")
    func sessionsSubdirectoryNamingMatchesObservedRule() throws {
        #expect(
            PiSessionService.sessionsSubdirectoryName(forCWD: "/Users/magnusmabeck/Claude/worktrees/new-task-078")
                == "--Users-magnusmabeck-Claude-worktrees-new-task-078--"
        )
    }

    @Test("repair is a no-op when the header cwd already matches the current working directory")
    func repairIsNoOpWhenCWDAlreadyMatches() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let cwd = root.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let transcriptURL = sessionsRoot.appendingPathComponent("--slug--/20260101_000000_aaa.jsonl")
        try writeTranscript(id: "s1", cwd: cwd, at: transcriptURL)
        let originalContents = try Data(contentsOf: transcriptURL)

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let repaired = PiSessionService.repairTranscriptForResume(
            transcriptPath: transcriptURL.path,
            currentWorkingDirectory: cwd,
            locations: locations
        )

        #expect(repaired == transcriptURL.path)
        #expect(try Data(contentsOf: transcriptURL) == originalContents)
    }

    @Test("repair returns nil and leaves the file untouched for a malformed header")
    func repairReturnsNilForMalformedHeader() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let transcriptURL = sessionsRoot.appendingPathComponent("proj/20260101_000000_aaa.jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not json at all\nsome body line\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let originalContents = try Data(contentsOf: transcriptURL)

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let repaired = PiSessionService.repairTranscriptForResume(
            transcriptPath: transcriptURL.path,
            currentWorkingDirectory: root.appendingPathComponent("elsewhere").path,
            locations: locations
        )

        #expect(repaired == nil)
        #expect(try Data(contentsOf: transcriptURL) == originalContents)
    }

    @Test("repair returns nil for a transcript file that doesn't exist")
    func repairReturnsNilForMissingFile() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let locations = makeLocations(sessionsRoot: sessionsRoot)

        let repaired = PiSessionService.repairTranscriptForResume(
            transcriptPath: sessionsRoot.appendingPathComponent("proj/missing.jsonl").path,
            currentWorkingDirectory: root.path,
            locations: locations
        )

        #expect(repaired == nil)
    }

    @Test("repair rewrites only the header cwd, relocates the file, and leaves every other line untouched")
    func repairRewritesHeaderCWDAndRelocates() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let oldCWD = root.appendingPathComponent("old-worktree").path
        let newCWDURL = root.appendingPathComponent("new-worktree")
        try FileManager.default.createDirectory(atPath: newCWDURL.path, withIntermediateDirectories: true)

        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"s1\",\"timestamp\":\"2026-09-22T18:47:13.521Z\",\"cwd\":\"\(oldCWD)\"}"
        let bodyLines = [
            "{\"type\":\"session_info\",\"id\":\"a\",\"parentId\":null,\"timestamp\":\"2026-09-22T18:47:13Z\",\"name\":null}",
            "{\"type\":\"message\",\"id\":\"e\",\"parentId\":\"d\",\"timestamp\":\"2026-09-22T18:47:14Z\",\"message\":{\"role\":\"user\",\"content\":\"fix the login bug\"}}",
        ]
        let originalPath = sessionsRoot.appendingPathComponent("--old-slug--/20260101_000000_aaa.jsonl")
        try FileManager.default.createDirectory(
            at: originalPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (([header] + bodyLines).joined(separator: "\n") + "\n")
            .write(to: originalPath, atomically: true, encoding: .utf8)

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let repaired = PiSessionService.repairTranscriptForResume(
            transcriptPath: originalPath.path,
            currentWorkingDirectory: newCWDURL.path,
            locations: locations
        )

        let resolvedNewCWD = newCWDURL.resolvingSymlinksInPath().path
        let expectedSubdirectory = PiSessionService.sessionsSubdirectoryName(forCWD: resolvedNewCWD)
        let expectedPath = sessionsRoot
            .appendingPathComponent(expectedSubdirectory)
            .appendingPathComponent(originalPath.lastPathComponent)
            .path

        #expect(repaired == expectedPath)
        #expect(FileManager.default.fileExists(atPath: originalPath.path) == false)

        let rewrittenContents = try String(contentsOf: URL(fileURLWithPath: repaired!), encoding: .utf8)
        let rewrittenLines = rewrittenContents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let headerData = try #require(rewrittenLines[0].data(using: .utf8))
        let rewrittenHeader = try #require(JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        #expect(rewrittenHeader["cwd"] as? String == resolvedNewCWD)
        #expect(rewrittenHeader["id"] as? String == "s1")
        #expect(rewrittenHeader["version"] as? Int == 3)
        #expect(rewrittenHeader["timestamp"] as? String == "2026-09-22T18:47:13.521Z")

        // Every line after the header survives the rewrite byte-for-byte.
        #expect(Array(rewrittenLines.dropFirst()) == bodyLines + [""])
    }
}

@Suite("PiSessionService.resolveTranscriptForResume")
struct PiSessionServiceResolveTranscriptForResumeTests {
    private func writeTranscript(id: String, cwd: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "{\"type\":\"session\",\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}"
        let body = "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}"
        try "\(header)\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeLocations(sessionsRoot: URL) -> PiSessionService.Locations {
        PiSessionService.Locations(
            bundledBinaryPath: "/usr/local/bin/pi",
            sessionsRoot: sessionsRoot,
            pathBinaryFinder: { nil }
        )
    }

    @Test("an empty stored transcriptPath is still resolved by scanning for the session id on disk")
    func emptyStoredPathIsResolvedByScanning() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let cwd = root.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let sessionID = PiSessionService.newSessionID()
        let transcriptURL = sessionsRoot.appendingPathComponent("--slug--/20260101_000000_aaa.jsonl")
        try writeTranscript(id: sessionID, cwd: cwd, at: transcriptURL)

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let conversation = Conversation(taskId: 1, sessionId: sessionID, transcriptPath: "")

        let resolved = PiSessionService.resolveTranscriptForResume(
            conversation: conversation,
            currentWorkingDirectory: cwd,
            locations: locations
        )

        let locatedPath = try #require(PiSessionService.locateTranscript(sessionID: sessionID, locations: locations)?.path)
        #expect(resolved.transcriptPathForLaunch == locatedPath)
        #expect(resolved.transcriptPathToPersist == locatedPath)
    }

    @Test("a transcript whose stored cwd no longer exists is repaired and resumed by path")
    func staleStoredCWDIsRepairedAndResumed() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let oldCWD = root.appendingPathComponent("old-worktree").path
        let newCWD = root.appendingPathComponent("new-worktree")
        try FileManager.default.createDirectory(atPath: newCWD.path, withIntermediateDirectories: true)

        let sessionID = PiSessionService.newSessionID()
        let transcriptURL = sessionsRoot.appendingPathComponent("--old-slug--/20260101_000000_aaa.jsonl")
        try writeTranscript(id: sessionID, cwd: oldCWD, at: transcriptURL)

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let conversation = Conversation(taskId: 1, sessionId: sessionID, transcriptPath: transcriptURL.path)

        let resolved = PiSessionService.resolveTranscriptForResume(
            conversation: conversation,
            currentWorkingDirectory: newCWD.path,
            locations: locations
        )

        let resolvedNewCWD = newCWD.resolvingSymlinksInPath().path
        let expectedSubdirectory = PiSessionService.sessionsSubdirectoryName(forCWD: resolvedNewCWD)
        let expectedPath = sessionsRoot
            .appendingPathComponent(expectedSubdirectory)
            .appendingPathComponent(transcriptURL.lastPathComponent)
            .path

        #expect(resolved.transcriptPathForLaunch == expectedPath)
        #expect(resolved.transcriptPathToPersist == expectedPath)
        #expect(FileManager.default.fileExists(atPath: transcriptURL.path) == false)
    }

    @Test("a stored cwd that still exists is left untouched and nothing is re-persisted")
    func stillExistingStoredCWDIsANoOp() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let cwd = root.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let sessionID = PiSessionService.newSessionID()
        let transcriptURL = sessionsRoot.appendingPathComponent("--slug--/20260101_000000_aaa.jsonl")
        try writeTranscript(id: sessionID, cwd: cwd, at: transcriptURL)
        let originalContents = try Data(contentsOf: transcriptURL)

        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let conversation = Conversation(taskId: 1, sessionId: sessionID, transcriptPath: transcriptURL.path)

        let resolved = PiSessionService.resolveTranscriptForResume(
            conversation: conversation,
            currentWorkingDirectory: cwd,
            locations: locations
        )

        #expect(resolved.transcriptPathForLaunch == transcriptURL.path)
        #expect(resolved.transcriptPathToPersist == nil)
        #expect(try Data(contentsOf: transcriptURL) == originalContents)
    }

    @Test("no transcript anywhere for the session id falls back to --session-id via a nil launch path")
    func noTranscriptFallsBackToSessionID() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let conversation = Conversation(taskId: 1, sessionId: PiSessionService.newSessionID(), transcriptPath: "")

        let resolved = PiSessionService.resolveTranscriptForResume(
            conversation: conversation,
            currentWorkingDirectory: root.appendingPathComponent("worktree").path,
            locations: locations
        )

        #expect(resolved.transcriptPathForLaunch == nil)
        #expect(resolved.transcriptPathToPersist == nil)
    }

    @Test("a stored transcriptPath pointing at a deleted file falls back to scanning, not --session-id")
    func deletedStoredPathFallsBackToScanning() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        let cwd = root.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let sessionID = PiSessionService.newSessionID()
        let realTranscriptURL = sessionsRoot.appendingPathComponent("--slug--/20260101_000000_aaa.jsonl")
        try writeTranscript(id: sessionID, cwd: cwd, at: realTranscriptURL)

        // The stored path is stale: it names a file that no longer exists
        // (e.g. a repair relocated the transcript but crashed before
        // persisting the new path), while a transcript for this session id
        // genuinely exists elsewhere under the sessions root.
        let staleStoredPath = sessionsRoot.appendingPathComponent("--gone--/20260101_000000_aaa.jsonl").path
        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let conversation = Conversation(taskId: 1, sessionId: sessionID, transcriptPath: staleStoredPath)

        let resolved = PiSessionService.resolveTranscriptForResume(
            conversation: conversation,
            currentWorkingDirectory: cwd,
            locations: locations
        )

        let locatedPath = try #require(PiSessionService.locateTranscript(sessionID: sessionID, locations: locations)?.path)
        #expect(resolved.transcriptPathForLaunch == locatedPath)
        #expect(resolved.transcriptPathToPersist == locatedPath)
    }

    @Test("a stored transcriptPath pointing at a deleted file with nothing found elsewhere falls back to --session-id")
    func deletedStoredPathWithNothingElseFallsBackToSessionID() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let sessionsRoot = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let cwd = root.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let sessionID = PiSessionService.newSessionID()
        let staleStoredPath = sessionsRoot.appendingPathComponent("--gone--/20260101_000000_aaa.jsonl").path
        let locations = makeLocations(sessionsRoot: sessionsRoot)
        let conversation = Conversation(taskId: 1, sessionId: sessionID, transcriptPath: staleStoredPath)

        let resolved = PiSessionService.resolveTranscriptForResume(
            conversation: conversation,
            currentWorkingDirectory: cwd,
            locations: locations
        )

        #expect(resolved.transcriptPathForLaunch == nil)
        #expect(resolved.transcriptPathToPersist == nil)
    }
}

@Suite("PiSessionService + ProjectsStore conversation binding")
struct PiSessionServiceConversationBindingTests {
    private func makeStore() async throws -> (store: ProjectsStore, task: TaskRecord, database: AppDatabase) {
        let database = try AppDatabase.openInMemory()
        let project = Project(path: "/tmp/repo", displayName: "repo", baseRef: "main")
        let insertedProject = try await database.dbQueue.write { db -> Project in
            var project = project
            try project.insert(db)
            return project
        }

        let task = TaskRecord(
            projectId: insertedProject.id!,
            name: "Fix bug",
            branchName: "task/fix-bug",
            worktreePath: "/tmp/repo-worktrees/fix-bug",
            harness: "claude",
            permissionLevel: "default"
        )
        let insertedTask = try await database.dbQueue.write { db -> TaskRecord in
            var task = task
            try task.insert(db)
            return task
        }

        let store = await ProjectsStore(database: database)
        return (store, insertedTask, database)
    }

    @Test("first launch for a task with no conversation persists a new active conversation")
    func firstLaunchPersistsConversation() async throws {
        let (store, task, _) = try await makeStore()

        let existing = await store.activeConversation(forTaskId: task.id!)
        #expect(existing == nil)

        let sessionID = PiSessionService.newSessionID()
        let conversation = try await store.startConversation(for: task, sessionID: sessionID)

        #expect(conversation.sessionId == sessionID)
        #expect(conversation.transcriptPath == "")
        #expect(conversation.isActive == true)

        let refetched = await store.activeConversation(forTaskId: task.id!)
        #expect(refetched?.id == conversation.id)
        #expect(refetched?.sessionId == sessionID)
    }

    @Test("a second launch for the same task reuses the existing conversation instead of creating another")
    func secondLaunchReusesConversation() async throws {
        let (store, task, _) = try await makeStore()

        let sessionID = PiSessionService.newSessionID()
        let first = try await store.startConversation(for: task, sessionID: sessionID)
        try await store.recordTranscriptPath("/tmp/sessions/proj/session.jsonl", for: first)

        // Simulate the app restarting / the task being reopened: the second
        // "launch" looks up the active conversation rather than starting a
        // fresh one.
        let reused = await store.activeConversation(forTaskId: task.id!)
        #expect(reused?.id == first.id)
        #expect(reused?.sessionId == sessionID)
        #expect(reused?.transcriptPath == "/tmp/sessions/proj/session.jsonl")

        let command = PiSessionService.launchCommand(
            locations: PiSessionService.Locations(
                bundledBinaryPath: "/usr/local/bin/pi",
                sessionsRoot: FileManager.default.temporaryDirectory,
                pathBinaryFinder: { nil }
            ),
            sessionID: reused!.sessionId,
            transcriptPath: reused!.transcriptPath,
            taskName: task.name
        )
        #expect(command.contains("--session '/tmp/sessions/proj/session.jsonl'"))
        #expect(command.contains(sessionID) == false)
    }

    @Test("concurrent ensureConversation calls for one task yield exactly one conversation row and one resolved host")
    @MainActor
    func concurrentEnsureConversationYieldsOneConversation() async throws {
        let (store, task, database) = try await makeStore()
        let gate = ConversationLaunchGate()

        // Both calls start from the same "no conversation yet" state and
        // race through the real reuse path (`ConversationLaunchGate` wraps
        // `ProjectsStore.activeConversation`/`startConversation` exactly as
        // `MainAreaView.ensureHost` does); only the gate's claim should let
        // one of them actually resolve a conversation, mirroring how only
        // one of two racing `ensureHost` calls should ever assign a host.
        async let first = gate.ensureConversation(for: task, store: store)
        async let second = gate.ensureConversation(for: task, store: store)
        let results = await [first, second]

        let resolved = results.compactMap { $0 }
        #expect(resolved.count == 1)

        let conversations = try await database.dbQueue.read { db in
            try Conversation.filter(Conversation.Columns.taskId == task.id!).fetchAll(db)
        }
        #expect(conversations.count == 1)
        #expect(conversations.first?.sessionId == resolved.first?.sessionId)
    }
}
