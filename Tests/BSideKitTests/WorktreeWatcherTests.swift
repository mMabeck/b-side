import Foundation
import Testing

@testable import BSideKit

/// FSEvents streams aren't exercised (too flaky under CI timing); this covers git-dir resolution.
@MainActor
@Suite("WorktreeWatcher")
struct WorktreeWatcherTests {
    @Test("resolveCommonGitDir finds the shared .git for a linked worktree, not the worktree's private one")
    func resolveCommonGitDirFindsTheSharedDirForALinkedWorktree() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let mainRepo = try await TestRepo.makeRepo(in: root, name: "main")

        let linkedWorktree = root.appendingPathComponent("linked", isDirectory: true)
        _ = try await GitCLI.run(
            ["worktree", "add", "-b", "feature", linkedWorktree.path], in: mainRepo
        )

        let privateGitDir = try #require(WorktreeWatcher.resolveGitDir(forWorktree: linkedWorktree))
        #expect(privateGitDir.path != mainRepo.appendingPathComponent(".git").standardizedFileURL.path)

        let commonGitDir = try #require(WorktreeWatcher.resolveCommonGitDir(forGitDir: privateGitDir))
        #expect(commonGitDir.standardizedFileURL.path == mainRepo.appendingPathComponent(".git").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: commonGitDir.appendingPathComponent("refs/heads/main").path))
    }

    @Test("resolveCommonGitDir returns the git dir itself for a non-linked repository")
    func resolveCommonGitDirIsIdentityForAPlainRepository() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let gitDir = try #require(WorktreeWatcher.resolveGitDir(forWorktree: repoURL))
        let commonGitDir = try #require(WorktreeWatcher.resolveCommonGitDir(forGitDir: gitDir))
        #expect(commonGitDir.standardizedFileURL.path == gitDir.standardizedFileURL.path)
    }
}
