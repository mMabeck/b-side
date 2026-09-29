import Foundation

extension GitCLI {
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

    /// Skips `<remote>/HEAD` symrefs, which aren't real branches.
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

    public static func branchExists(_ branch: String, at path: URL) async throws -> Bool {
        do {
            _ = try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: path)
            return true
        } catch let error as CommandError where error.status == 1 {
            return false
        }
    }

    public static func createBranch(_ branch: String, from baseRef: String, at path: URL) async throws {
        _ = try await run(["branch", branch, baseRef], in: path)
    }

    public static func renameBranch(_ branch: String, to newName: String, at path: URL) async throws {
        _ = try await run(["branch", "-m", branch, newName], in: path)
    }

    public static func deleteLocalBranch(_ branch: String, at path: URL, force: Bool = false) async throws {
        _ = try await run(["branch", force ? "-D" : "-d", branch], in: path)
    }

    public static func deleteRemoteBranch(_ branch: String, remote: String = "origin", at path: URL) async throws {
        _ = try await run(["push", remote, "--delete", branch], in: path)
    }

    public static func hasRemoteBranch(_ branch: String, remote: String = "origin", at path: URL) async -> Bool {
        (try? await run(["show-ref", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], in: path)) != nil
    }
}
