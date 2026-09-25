import Foundation
import Testing

@testable import BSideKit

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
