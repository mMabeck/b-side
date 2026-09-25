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

    /// The commit `ref` currently resolves to.
    public static func revParse(_ ref: String, at path: URL) async throws -> String {
        try await runText(["rev-parse", ref], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The commit `branch` pointed at when it was created — its reflog's oldest
    /// entry — or `nil` if the branch has no reflog (e.g. it was deleted, or
    /// reflogs are disabled). Used as a fallback baseline for `isMerged` when
    /// no `baseCommit` was recorded at task-creation time.
    public static func reflogCreationCommit(forBranch branch: String, at path: URL) async -> String? {
        guard let output = try? await runText(["reflog", "show", "--format=%H", branch], in: path) else {
            return nil
        }
        let lines = output.split(separator: "\n").map(String.init)
        return lines.last
    }

    /// Whether `branch` has been merged into `baseRef` since `baseCommit`: it has
    /// picked up at least one commit of its own beyond `baseCommit`, and its
    /// current tip is now reachable from `baseRef`. A branch that is only
    /// behind `baseRef` (no commits of its own) reads as not merged even
    /// though every commit it has is trivially an ancestor of `baseRef` — that
    /// is "hasn't diverged yet", not "was merged". `baseCommit` of `nil` (no
    /// baseline known at all) is treated as not merged.
    public static func isMerged(branch: String, into baseRef: String, since baseCommit: String?, at path: URL) async throws -> Bool {
        guard let baseCommit else { return false }
        guard let tip = try? await revParse(branch, at: path), tip != baseCommit else { return false }
        do {
            _ = try await run(["merge-base", "--is-ancestor", branch, baseRef], in: path)
            return true
        } catch let error as CommandError where error.status == 1 {
            return false
        }
    }
}
