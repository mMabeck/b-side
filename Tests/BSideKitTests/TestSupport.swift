import Foundation

@testable import BSideKit

/// Helpers for building real, throwaway git repositories for the git-layer and
/// task/worktree tests. Every test that uses these owns cleaning its temp
/// directory up in a `defer`.
enum TestRepo {
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a git repo at `<root>/repo` on branch `main` with one commit.
    static func makeRepo(in root: URL, name: String = "repo") async throws -> URL {
        let repoURL = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try await GitCLI.initRepository(at: repoURL)
        _ = try await GitCLI.run(["config", "user.email", "test@example.com"], in: repoURL)
        _ = try await GitCLI.run(["config", "user.name", "Test"], in: repoURL)
        if await GitCLI.currentBranch(at: repoURL) != "main" {
            _ = try await GitCLI.run(["checkout", "-b", "main"], in: repoURL)
        }
        try "hello\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "init"], in: repoURL)
        return repoURL
    }

    static func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
