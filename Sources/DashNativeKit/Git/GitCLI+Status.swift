import Foundation

extension GitCLI {
    /// Git-ignored paths that are *not* swept into a wholly-ignored directory.
    ///
    /// `git status --porcelain=v2 --ignored=matching` collapses a directory that is
    /// entirely ignored (e.g. `node_modules/`) into a single entry ending in `/`,
    /// rather than listing every file beneath it. Filtering those out leaves loose
    /// ignored files sitting next to tracked ones — `.env`, `.npmrc`, local config
    /// overrides — without walking into dependency or build trees. That is the rule
    /// this app uses for which ignored files a fresh worktree needs copied in.
    public static func looseIgnoredFiles(at path: URL) async throws -> [String] {
        let data = try await run(
            ["status", "--porcelain=v2", "-z", "--ignored=matching"],
            in: path
        )
        let entries = splitNulDelimited(data)
        var paths: [String] = []
        for entry in entries {
            guard entry.hasPrefix("! ") else { continue }
            let relativePath = String(entry.dropFirst(2))
            guard !relativePath.hasSuffix("/") else { continue }
            paths.append(relativePath)
        }
        return paths
    }

    /// Whether `path`'s working tree has any uncommitted changes (staged,
    /// unstaged, or untracked). Cheap: a single porcelain status call, no
    /// diff computation.
    public static func isWorkingTreeDirty(at path: URL) async throws -> Bool {
        let data = try await run(["status", "--porcelain", "-z"], in: path)
        return !data.isEmpty
    }
}
