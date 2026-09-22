import Foundation

extension GitCLI {
    /// Commits `branch` has that `baseRef` doesn't (ahead), and vice versa (behind).
    public static func aheadBehind(branch: String, baseRef: String, at path: URL) async throws -> (ahead: Int, behind: Int) {
        let output = try await runText(
            ["rev-list", "--left-right", "--count", "\(baseRef)...\(branch)"],
            in: path
        )
        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return (ahead: 0, behind: 0)
        }
        return (ahead: ahead, behind: behind)
    }

    /// Whether every commit on `branch` is already reachable from `baseRef`, i.e.
    /// `branch` has been merged into it.
    public static func isMerged(branch: String, into baseRef: String, at path: URL) async throws -> Bool {
        do {
            _ = try await run(["merge-base", "--is-ancestor", branch, baseRef], in: path)
            return true
        } catch let error as CommandError where error.status == 1 {
            return false
        }
    }
}
