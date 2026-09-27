import Foundation

/// Push and commit history for the Source Control sidebar.
extension GitCLI {
    /// Every credential path that could block on a prompt the UI can't answer
    /// is disabled, so a missing/misconfigured credential just fails the push:
    /// `GIT_TERMINAL_PROMPT=0`, batch-mode `GIT_SSH_COMMAND` (unless already
    /// set), `GCM_INTERACTIVE=never`, and an empty `SSH_ASKPASS`.
    public static func push(
        at path: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        var env: [String: String] = [
            "GIT_TERMINAL_PROMPT": "0",
            "GCM_INTERACTIVE": "never",
            "SSH_ASKPASS": "",
        ]
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        try await runStreaming(
            args: ["push", "-u", "origin", "HEAD"],
            at: path,
            env: env,
            onOutput: onOutput
        )
    }

    /// `nil` if the branch has no upstream configured.
    public static func aheadBehind(at path: URL) async -> (ahead: Int, behind: Int)? {
        guard let output = try? await runText(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: path) else {
            return nil
        }
        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return nil
        }
        return (ahead: ahead, behind: behind)
    }

    /// A single commit's summary for the History list.
    public struct CommitSummary: Sendable, Equatable, Identifiable {
        public let sha: String
        public let shortSha: String
        public let subject: String
        public let author: String
        public let date: Date

        public var id: String { sha }
    }

    // Neither can appear in a commit subject/author name, so no escaping is needed.
    private static let historyFieldSeparator = "\u{1f}"
    private static let historyRecordSeparator = "\u{1e}"

    /// `baseline` given: only `baseline..HEAD`. `nil`: the whole branch history.
    public static func history(since baseline: String?, limit: Int, at path: URL) async throws -> [CommitSummary] {
        var arguments = [
            "log",
            "--max-count=\(limit)",
            "--format=%H\(historyFieldSeparator)%h\(historyFieldSeparator)%s\(historyFieldSeparator)%an\(historyFieldSeparator)%aI\(historyRecordSeparator)",
        ]
        if let baseline {
            arguments.append("\(baseline)..HEAD")
        }
        let output = try await runText(arguments, in: path)
        return parseHistory(output)
    }

    static func parseHistory(_ output: String) -> [CommitSummary] {
        let formatter = ISO8601DateFormatter()
        return output
            .components(separatedBy: historyRecordSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { record -> CommitSummary? in
                let fields = record.components(separatedBy: historyFieldSeparator)
                guard fields.count == 5, let date = formatter.date(from: fields[4]) else { return nil }
                return CommitSummary(sha: fields[0], shortSha: fields[1], subject: fields[2], author: fields[3], date: date)
            }
    }

    /// Capped the same way as working-tree diffs (see `DiffText`).
    public static func showCommit(_ sha: String, at path: URL) async throws -> DiffText {
        let data = try await run(
            ["show", "--format=%H%n%an <%ae>%n%aI%n%n%s%n%n%b", "--patch", sha],
            in: path
        )
        return makeDiffText(from: data, detectBinary: false)
    }
}
