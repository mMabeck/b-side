import Foundation
import Testing

@testable import BSideKit

@Suite("GitCLI")
struct GitCLITests {
    @Test("worktrees(at:) parses the primary repo and added worktrees")
    func parsesWorktreeList() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        _ = try await GitCLI.run(["branch", "feature"], in: repoURL)
        let worktreeURL = root.appendingPathComponent("wt")
        _ = try await GitCLI.run(["worktree", "add", worktreeURL.path, "feature"], in: repoURL)

        let worktrees = try await GitCLI.worktrees(at: repoURL)

        #expect(worktrees.count == 2)
        #expect(worktrees.contains { $0.path.hasSuffix("/repo") && $0.branch == "main" })
        #expect(worktrees.contains { $0.path.hasSuffix("/wt") && $0.branch == "feature" })
    }

    @Test("remoteTrackingBranches lists remote refs and skips the HEAD symref")
    func listsRemoteTrackingBranches() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let remoteURL = root.appendingPathComponent("remote.git")
        _ = try await GitCLI.run(["init", "--bare", remoteURL.path], in: root)
        _ = try await GitCLI.run(["remote", "add", "origin", remoteURL.path], in: repoURL)
        _ = try await GitCLI.run(["push", "origin", "main"], in: repoURL)
        try await GitCLI.createBranch("feature", from: "main", at: repoURL)
        _ = try await GitCLI.run(["push", "origin", "feature"], in: repoURL)
        _ = try await GitCLI.run(["fetch", "origin"], in: repoURL)
        _ = try await GitCLI.run(["remote", "set-head", "origin", "main"], in: repoURL)

        let remoteBranches = try await GitCLI.remoteTrackingBranches(at: repoURL)

        #expect(remoteBranches.contains("origin/main"))
        #expect(remoteBranches.contains("origin/feature"))
        #expect(!remoteBranches.contains("origin/HEAD"))
    }

    @Test("branchExists reflects created and deleted branches")
    func branchExistsTracksLifecycle() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        #expect(try await GitCLI.branchExists("feature", at: repoURL) == false)

        try await GitCLI.createBranch("feature", from: "main", at: repoURL)
        #expect(try await GitCLI.branchExists("feature", at: repoURL) == true)

        try await GitCLI.deleteLocalBranch("feature", at: repoURL)
        #expect(try await GitCLI.branchExists("feature", at: repoURL) == false)
    }

    @Test("looseIgnoredFiles returns standalone ignored files, not swept-up directories")
    func looseIgnoredFilesSkipsIgnoredDirectories() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try "node_modules/\n.env\n".write(
            to: repoURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
        _ = try await GitCLI.run(["add", ".gitignore"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "gitignore"], in: repoURL)

        let nodeModules = repoURL.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "console.log(1)".write(to: nodeModules.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "SECRET=1\n".write(to: repoURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let ignored = try await GitCLI.looseIgnoredFiles(at: repoURL)

        #expect(ignored == [".env"])
    }

    @Test("aheadBehind counts commits unique to each side")
    func aheadBehindCounts() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try await GitCLI.createBranch("feature", from: "main", at: repoURL)
        _ = try await GitCLI.run(["checkout", "feature"], in: repoURL)
        try "feature work\n".write(to: repoURL.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "feature commit"], in: repoURL)

        _ = try await GitCLI.run(["checkout", "main"], in: repoURL)
        try "main work\n".write(to: repoURL.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "main commit"], in: repoURL)

        let (ahead, behind) = try await GitCLI.aheadBehind(branch: "feature", baseRef: "main", at: repoURL)
        #expect(ahead == 1)
        #expect(behind == 1)

        #expect(try await GitCLI.isMerged(branch: "feature", into: "main", at: repoURL) == false)
    }

    @Test("isMerged is true once base has absorbed the branch")
    func isMergedAfterMerge() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try await GitCLI.createBranch("feature", from: "main", at: repoURL)
        _ = try await GitCLI.run(["checkout", "feature"], in: repoURL)
        try "feature work\n".write(to: repoURL.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "feature commit"], in: repoURL)

        _ = try await GitCLI.run(["checkout", "main"], in: repoURL)
        _ = try await GitCLI.run(["merge", "--no-ff", "-m", "merge feature", "feature"], in: repoURL)

        #expect(try await GitCLI.isMerged(branch: "feature", into: "main", at: repoURL) == true)
    }
}
