import Foundation

extension GitCLI {
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

    public static func revParse(_ ref: String, at path: URL) async throws -> String {
        try await runText(["rev-parse", ref], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reflog's oldest entry; `nil` without a reflog. Fallback baseline for `isMerged`.
    public static func reflogCreationCommit(forBranch branch: String, at path: URL) async -> String? {
        guard let output = try? await runText(["reflog", "show", "--format=%H", branch], in: path) else {
            return nil
        }
        let lines = output.split(separator: "\n").map(String.init)
        return lines.last
    }

    /// A branch only behind `baseRef` reads as not merged (it hasn't diverged yet); a `nil` `baseCommit` is not merged.
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
