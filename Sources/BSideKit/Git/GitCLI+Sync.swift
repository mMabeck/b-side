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
    /// `branch` has been merged into it. On its own this doesn't distinguish a
    /// branch that gained and merged commits from one that never moved off
    /// `baseRef` in the first place — see `TaskWorktreeService.syncStatus`,
    /// which additionally checks the branch against its recorded start commit.
    public static func isMerged(branch: String, into baseRef: String, at path: URL) async throws -> Bool {
        do {
            _ = try await run(["merge-base", "--is-ancestor", branch, baseRef], in: path)
            return true
        } catch let error as CommandError where error.status == 1 {
            return false
        }
    }

    /// Resolves `ref` to the SHA of the commit it points at, or `nil` if it
    /// doesn't resolve to a commit.
    public static func resolveCommit(_ ref: String, at path: URL) async -> String? {
        guard let output = try? await runText(["rev-parse", "--verify", "\(ref)^{commit}"], in: path) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The oldest reflog entry for `refs/heads/<branch>` — the commit it
    /// pointed at when first created. Fallback `startCommit` for tasks
    /// created before that column existed; `nil` if the branch has no
    /// reflog (e.g. reflogs disabled) or doesn't exist.
    public static func oldestReflogCommit(forBranch branch: String, at path: URL) async -> String? {
        guard let output = try? await runText(["reflog", "show", "--format=%H", "refs/heads/\(branch)"], in: path) else {
            return nil
        }
        let entries = output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        return entries.last
    }
}
