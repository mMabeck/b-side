import Foundation

/// Branch listing and lifecycle. Worktree-checkout state is surfaced separately
/// by `GitCLI.worktrees(at:)` and merged in by `TaskWorktreeService`, since a
/// branch being checked out is a worktree fact, not a branch fact.
extension GitCLI {
    /// Local branch names, most-recently-committed first.
    public static func localBranches(at path: URL) async throws -> [String] {
        let output = try await runText(
            ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"],
            in: path
        )
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Remote-tracking branch names (e.g. `origin/main`), most-recently-committed
    /// first. Skips `<remote>/HEAD` symrefs, since those aren't real branches.
    public static func remoteTrackingBranches(at path: URL) async throws -> [String] {
        let output = try await runText(
            ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/remotes"],
            in: path
        )
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
    }

    /// Whether `branch` exists locally.
    public static func branchExists(_ branch: String, at path: URL) async throws -> Bool {
        do {
            _ = try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: path)
            return true
        } catch let error as CommandError where error.status == 1 {
            return false
        }
    }

    /// Creates `branch` from `baseRef` without checking it out.
    public static func createBranch(_ branch: String, from baseRef: String, at path: URL) async throws {
        _ = try await run(["branch", branch, baseRef], in: path)
    }

    /// Deletes a local branch. `force` uses `-D` instead of `-d`.
    public static func deleteLocalBranch(_ branch: String, at path: URL, force: Bool = false) async throws {
        _ = try await run(["branch", force ? "-D" : "-d", branch], in: path)
    }

    /// Deletes `branch` on `remote` (default `origin`).
    public static func deleteRemoteBranch(_ branch: String, remote: String = "origin", at path: URL) async throws {
        _ = try await run(["push", remote, "--delete", branch], in: path)
    }

    /// Whether `branch` has a corresponding `<remote>/<branch>` ref, i.e. was ever pushed.
    public static func hasRemoteBranch(_ branch: String, remote: String = "origin", at path: URL) async -> Bool {
        (try? await run(["show-ref", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], in: path)) != nil
    }
}
