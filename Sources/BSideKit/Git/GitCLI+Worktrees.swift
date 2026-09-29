import Foundation

extension GitCLI {
    public struct Worktree: Sendable, Equatable {
        public let path: String
        public let headSHA: String?
        public let branch: String?
        public let isBare: Bool
        public let isDetached: Bool
    }

    /// Parses `git worktree list --porcelain -z`: records separated by two consecutive NULs, each line `key value`.
    public static func worktrees(at path: URL) async throws -> [Worktree] {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], in: path)
        let text = String(data: data, encoding: .utf8) ?? ""
        let records = text.components(separatedBy: "\0\0")

        var result: [Worktree] = []
        for record in records {
            let lines = record.split(separator: "\0").map(String.init)
            guard !lines.isEmpty else { continue }

            var worktreePath: String?
            var headSHA: String?
            var branch: String?
            var isBare = false
            var isDetached = false

            for line in lines {
                if line == "bare" {
                    isBare = true
                } else if line == "detached" {
                    isDetached = true
                } else if let value = line.stripping(prefix: "worktree ") {
                    worktreePath = value
                } else if let value = line.stripping(prefix: "HEAD ") {
                    headSHA = value
                } else if let value = line.stripping(prefix: "branch ") {
                    branch = value.stripping(prefix: "refs/heads/") ?? value
                }
            }

            guard let worktreePath else { continue }
            result.append(
                Worktree(path: worktreePath, headSHA: headSHA, branch: branch, isBare: isBare, isDetached: isDetached)
            )
        }
        return result
    }

    public static func addWorktree(
        at worktreePath: URL,
        newBranch: String,
        from baseRef: String,
        in repositoryPath: URL
    ) async throws {
        _ = try await run(
            ["worktree", "add", "-b", newBranch, worktreePath.path, baseRef],
            in: repositoryPath
        )
    }

    public static func addWorktree(
        at worktreePath: URL,
        existingBranch: String,
        in repositoryPath: URL
    ) async throws {
        _ = try await run(
            ["worktree", "add", worktreePath.path, existingBranch],
            in: repositoryPath
        )
    }

    /// Follows up with `worktree repair` (cheap, idempotent) since `worktree move` alone can leave gitlinks out of sync on some git versions.
    public static func moveWorktree(from oldPath: URL, to newPath: URL, in repositoryPath: URL) async throws {
        _ = try await run(["worktree", "move", oldPath.path, newPath.path], in: repositoryPath)
        _ = try? await run(["worktree", "repair"], in: repositoryPath)
    }

    public static func removeWorktree(at worktreePath: URL, in repositoryPath: URL, force: Bool = false) async throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(worktreePath.path)
        _ = try await run(arguments, in: repositoryPath)
    }

    public static func pruneWorktrees(in repositoryPath: URL) async throws {
        _ = try await run(["worktree", "prune"], in: repositoryPath)
    }
}

extension String {
    fileprivate func stripping(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
