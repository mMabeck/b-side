import Foundation

extension GitCLI {
    /// Ignored paths outside wholly-ignored directories: porcelain v2 collapses e.g. `node_modules/` into one `/` entry, so filtering those leaves loose files like `.env`.
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

    public static func isWorkingTreeDirty(at path: URL) async throws -> Bool {
        let data = try await run(["status", "--porcelain", "-z"], in: path)
        return !data.isEmpty
    }
}
