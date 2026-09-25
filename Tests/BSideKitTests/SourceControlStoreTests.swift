import Foundation
import Testing

@testable import BSideKit

/// Thread-safe accumulator for URLs handed to the `@Sendable` `recycle`
/// closure injected into `SourceControlStore` under test, matching
/// `LineCollector` in `GitCLIChangesTests.swift`.
private final class RecycledURLsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(contentsOf newURLs: [URL]) {
        lock.lock()
        urls.append(contentsOf: newURLs)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// Exercises `SourceControlStore` against a real throwaway git repo (via
/// `TestRepo`), never a mock git layer — the same rationale as
/// `GitCLIChangesTests`.
@MainActor
@Suite("SourceControlStore")
struct SourceControlStoreTests {
    private func makeTask(worktree: URL, branchName: String = "main", baseCommit: String? = nil) -> TaskRecord {
        TaskRecord(
            id: 1,
            projectId: 1,
            name: "T",
            branchName: branchName,
            worktreePath: worktree.path,
            harness: "claude",
            permissionLevel: "default",
            baseCommit: baseCommit
        )
    }

    @Test("An edit made on disk appears through the watcher without an explicit refresh")
    func watcherPicksUpAnEdit() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.loadState == .loaded }
        #expect(store.unstaged.isEmpty)

        try "changed\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try await waitUntil(.seconds(5)) { store.unstaged.contains { $0.path == "README.md" } }
        #expect(store.unstaged.contains { $0.path == "README.md" })
    }

    @Test("Staging a file moves it from Changes to Staged Changes")
    func stageMovesFileBetweenSections() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        try "changed\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.unstaged.contains { $0.path == "README.md" } }

        let row = try #require(store.unstaged.first { $0.path == "README.md" })
        await store.stage([row])

        try await waitUntil { store.staged.contains { $0.path == "README.md" } }
        #expect(store.staged.contains { $0.path == "README.md" })
        #expect(!store.unstaged.contains { $0.path == "README.md" })
    }

    @Test("Discarding the unstaged row of a file leaves its staged half intact")
    func discardUnstagedRowLeavesStagedIntact() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let fileURL = repoURL.appendingPathComponent("README.md")

        try "staged change\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)
        try "staged change\nunstaged too\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil {
            store.unstaged.contains { $0.path == "README.md" } && store.staged.contains { $0.path == "README.md" }
        }

        let unstagedRow = try #require(store.unstaged.first { $0.path == "README.md" })
        await store.discard([unstagedRow])

        try await waitUntil { !store.unstaged.contains { $0.path == "README.md" } }
        #expect(store.staged.contains { $0.path == "README.md" })
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content == "staged change\n")
    }

    @Test("Discarding a staged modification only unstages it, keeping its content")
    func discardStagedModificationKeepsContent() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let fileURL = repoURL.appendingPathComponent("README.md")

        try "staged change\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.staged.contains { $0.path == "README.md" } }

        let row = try #require(store.staged.first { $0.path == "README.md" })
        await store.discard([row])

        try await waitUntil { store.unstaged.contains { $0.path == "README.md" } }
        #expect(!store.staged.contains { $0.path == "README.md" })
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content == "staged change\n")
    }

    @Test("Discarding a staged-new row unstages and recycles it, rather than deleting it outright")
    func discardStagedNewRowRecyclesInsteadOfDeleting() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "brand new\n".write(to: repoURL.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["new.txt"], at: repoURL)

        let store = SourceControlStore()
        let recycled = RecycledURLsBox()
        store.recycle = { urls in recycled.append(contentsOf: urls) }
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.staged.contains { $0.path == "new.txt" } }

        let row = try #require(store.staged.first { $0.path == "new.txt" })
        await store.discard([row])

        try await waitUntil { !store.staged.contains { $0.path == "new.txt" } }
        #expect(recycled.all.map(\.lastPathComponent) == ["new.txt"])
        // `recycle` is faked to just record the call, not actually trash the
        // file — it surviving on disk here is what distinguishes this from the
        // old `restore --source=HEAD` behaviour, which deleted it outright.
        #expect(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("new.txt").path))
    }

    @Test("Discarding a staged rename fully reverts it, including the old path")
    func discardStagedRenameRevertsBothPaths() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "content\n".write(to: repoURL.appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "orig.txt"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "add orig"], in: repoURL)
        _ = try await GitCLI.run(["mv", "orig.txt", "new.txt"], in: repoURL)

        let store = SourceControlStore()
        let recycled = RecycledURLsBox()
        store.recycle = { urls in recycled.append(contentsOf: urls) }
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.staged.contains { $0.path == "new.txt" } }

        let row = try #require(store.staged.first { $0.path == "new.txt" })
        #expect(row.origPath == "orig.txt")
        await store.discard([row])

        try await waitUntil { !store.staged.contains { $0.path == "new.txt" } }
        #expect(!store.staged.contains { $0.path == "orig.txt" })
        #expect(recycled.all.map(\.lastPathComponent) == ["new.txt"])
        #expect(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("orig.txt").path))
    }

    // Regression for leaving `D orig.txt` *staged* after only the new path
    // was unstaged — not for whether an unstaged deletion shows up at all.
    // `orig.txt` no longer existing on disk (it was physically `git mv`'d to
    // `new.txt`) while the index reverts to expecting it, post-unstage, is
    // real and expected: the same thing VS Code's own "Unstage" does, since
    // unstaging never touches the working tree.
    @Test("Unstaging a rename unstages both the old and new path, leaving neither staged")
    func unstageRenameClearsBothPaths() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "content\n".write(to: repoURL.appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "orig.txt"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "add orig"], in: repoURL)
        _ = try await GitCLI.run(["mv", "orig.txt", "new.txt"], in: repoURL)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.staged.contains { $0.path == "new.txt" } }

        let row = try #require(store.staged.first { $0.path == "new.txt" })
        await store.unstage([row])

        try await waitUntil { store.unstaged.contains { $0.path == "new.txt" } }
        #expect(store.staged.isEmpty)
        #expect(store.unstaged.contains { $0.path == "new.txt" && $0.kind == .untracked })
        #expect(!store.staged.contains { $0.path == "orig.txt" })
    }

    @Test("commit() is a no-op while a push is in flight")
    func commitNoOpWhilePushing() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let remoteURL = root.appendingPathComponent("origin.git")
        _ = try await GitCLI.run(["init", "--bare", remoteURL.path], in: root)
        _ = try await GitCLI.run(["remote", "add", "origin", remoteURL.path], in: repoURL)
        _ = try await GitCLI.run(["push", "-u", "origin", "main"], in: repoURL)

        try "committed\n".write(to: repoURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "second"], in: repoURL)

        try "staged again\n".write(to: repoURL.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.hasRemote }
        try await waitUntil { store.unstaged.contains { $0.path == "file2.txt" } }
        let row = try #require(store.unstaged.first { $0.path == "file2.txt" })
        await store.stage([row])
        try await waitUntil { store.staged.contains { $0.path == "file2.txt" } }

        store.push()
        #expect(store.isPushing)

        store.commitMessage = "should not commit"
        store.commit()
        #expect(!store.isCommitting)
        #expect(!store.staged.isEmpty)

        try await waitUntil(.seconds(10)) { !store.isPushing }
    }

    @Test("Switching tasks mid-commit doesn't let the old commit's output land in the new task's state")
    func taskSwitchDuringCommitDoesNotLeakState() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoA = try await TestRepo.makeRepo(in: root, name: "repo-a")
        let repoB = try await TestRepo.makeRepo(in: root, name: "repo-b")

        let hookURL = repoA.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 1\necho slow-hook-output\nexit 0\n".write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        try "changed\n".write(to: repoA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoA))
        try await waitUntil { store.unstaged.contains { $0.path == "README.md" } }
        let row = try #require(store.unstaged.first { $0.path == "README.md" })
        await store.stage([row])
        try await waitUntil { store.staged.contains { $0.path == "README.md" } }

        store.commitMessage = "slow commit"
        store.commit()
        try await waitUntil { store.isCommitting }

        store.setTask(makeTask(worktree: repoB))
        try await waitUntil { store.loadState == .loaded }

        // Give the old (cancelled) commit's hook time to finish running.
        try await Task.sleep(for: .seconds(2))

        #expect(store.commitLog.isEmpty)
        #expect(!store.isCommitting)
        #expect(store.commitMessage.isEmpty)
    }

    @Test("More than 200 untracked files skips line counts rather than spawning one diff per file")
    func manyUntrackedFilesSkipsLineCounts() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        for index in 0..<201 {
            try "x\n".write(to: repoURL.appendingPathComponent("untracked-\(index).txt"), atomically: true, encoding: .utf8)
        }

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil(.seconds(10)) { store.unstaged.count >= 201 }

        #expect(store.unstaged.allSatisfy { $0.linesAdded == nil && $0.linesRemoved == nil })
    }

    @Test("Untracked file line counts still populate under the bounded-concurrency cap")
    func untrackedLineCountsStillPopulateUnderTheCap() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        for index in 0..<12 {
            try "line one\nline two\n".write(
                to: repoURL.appendingPathComponent("new-\(index).txt"), atomically: true, encoding: .utf8
            )
        }

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.unstaged.count >= 12 }
        try await waitUntil { store.unstaged.allSatisfy { $0.linesAdded != nil } }

        #expect(store.unstaged.allSatisfy { $0.linesAdded == 2 && $0.linesRemoved == 0 })
    }

    @Test("A successful commit clears the staged changes and the file shows up under the branch list")
    func commitClearsStagedAndShowsOnBranch() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let baseCommit = try await GitCLI.revParse("HEAD", at: repoURL)
        try "changed\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL, baseCommit: baseCommit))
        try await waitUntil { store.unstaged.contains { $0.path == "README.md" } }
        let row = try #require(store.unstaged.first { $0.path == "README.md" })
        await store.stage([row])
        try await waitUntil { store.staged.contains { $0.path == "README.md" } }

        store.commitMessage = "Update README"
        store.commit()

        try await waitUntil(.seconds(10)) { !store.isCommitting }
        #expect(store.commitMessage.isEmpty)
        #expect(store.staged.isEmpty)

        try await waitUntil { store.branchChanges.contains { $0.path == "README.md" } }
        #expect(store.branchChanges.contains { $0.path == "README.md" })
    }

    @Test("A failing pre-commit hook keeps the message and shows its output")
    func failingHookKeepsMessageAndShowsOutput() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let hooksDir = repoURL.appendingPathComponent(".git/hooks")
        let hookURL = hooksDir.appendingPathComponent("pre-commit")
        try "#!/bin/sh\necho 'hook failed on purpose'\nexit 1\n".write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        try "changed\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.unstaged.contains { $0.path == "README.md" } }
        let row = try #require(store.unstaged.first { $0.path == "README.md" })
        await store.stage([row])
        try await waitUntil { store.staged.contains { $0.path == "README.md" } }

        store.commitMessage = "Update README"
        store.commit()

        try await waitUntil(.seconds(10)) { !store.isCommitting }
        #expect(store.commitMessage == "Update README")
        #expect(!store.staged.isEmpty)
        #expect(store.commitLog.contains { $0.contains("hook failed on purpose") })
    }

    @Test("Git errors surface as an error state, never as a clean empty list")
    func gitErrorsSurfaceAsErrorState() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let notARepo = root.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: notARepo))

        try await waitUntil { store.loadState == .notARepository }
        #expect(store.loadState == .notARepository)
        #expect(store.staged.isEmpty)
        #expect(store.unstaged.isEmpty)

        // A worktree that genuinely is a repository (`rev-parse
        // --is-inside-work-tree` succeeds) but where `git status` itself
        // fails — a corrupt index, here — must surface as `.error`, not
        // `.notARepository` and never as a silently empty list.
        let brokenRepo = try await TestRepo.makeRepo(in: root, name: "broken-repo")
        try "garbage-not-an-index".write(to: brokenRepo.appendingPathComponent(".git/index"), atomically: true, encoding: .utf8)

        let brokenStore = SourceControlStore()
        brokenStore.setTask(makeTask(worktree: brokenRepo))
        try await waitUntil { brokenStore.loadState != .idle }
        guard case .error = brokenStore.loadState else {
            Issue.record("expected .error, got \(brokenStore.loadState)")
            return
        }
        #expect(brokenStore.staged.isEmpty)
        #expect(brokenStore.unstaged.isEmpty)
    }

    @Test("Pushing to a local bare origin updates ahead/behind and shows output in the log")
    func pushUpdatesAheadBehindAndLog() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let remoteURL = root.appendingPathComponent("origin.git")
        _ = try await GitCLI.run(["init", "--bare", remoteURL.path], in: root)
        _ = try await GitCLI.run(["remote", "add", "origin", remoteURL.path], in: repoURL)
        _ = try await GitCLI.run(["push", "-u", "origin", "main"], in: repoURL)

        try "changed\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "second"], in: repoURL)

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL))
        try await waitUntil { store.hasRemote }
        try await waitUntil { store.aheadBehind?.ahead == 1 }

        store.push()

        try await waitUntil(.seconds(10)) { !store.isPushing }
        #expect(!store.pushLog.isEmpty)

        try await waitUntil { store.aheadBehind?.ahead == 0 }
        #expect(store.aheadBehind?.ahead == 0)
        #expect(store.aheadBehind?.behind == 0)
    }

    @Test("History lists the commits made on the task's branch")
    func historyListsBranchCommits() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let baseCommit = try await GitCLI.revParse("HEAD", at: repoURL)

        for index in 1...2 {
            try "commit \(index)\n".write(
                to: repoURL.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8
            )
            _ = try await GitCLI.run(["add", "."], in: repoURL)
            _ = try await GitCLI.run(["commit", "-m", "commit \(index)"], in: repoURL)
        }

        let store = SourceControlStore()
        store.setTask(makeTask(worktree: repoURL, baseCommit: baseCommit))

        try await waitUntil { store.history.map(\.subject) == ["commit 2", "commit 1"] }
        #expect(store.history.map(\.subject) == ["commit 2", "commit 1"])
        #expect(!store.history.contains { $0.subject == "init" })
    }
}
