import Foundation
import OSLog

/// A task created with a blank name (`TaskRecord.awaitingAutoRename`) is
/// renamed once its first prompt is typed, and its app-created branch is
/// renamed to match. The worktree directory is never moved — moving it out
/// from under a live pi process breaks pi's tools (stale cwd) and transcript
/// lookup — so it stays put for the task's lifetime, like Claude Desktop/Codex.
public enum TaskAutoRenameService {
    static let logger = Logger(subsystem: "dev.mabeck.bside", category: "task-auto-rename")

    // MARK: - Transcript parsing

    /// Every other line type (`session`, `session_info`, ...) fails to decode `message` and is skipped.
    private struct TranscriptLine: Decodable {
        let type: String
        let message: TranscriptMessage?
    }

    private struct TranscriptMessage: Decodable {
        let role: String
        let content: TranscriptContent
    }

    /// Either a plain string or an array of typed blocks; pi uses both depending on role/harness.
    private enum TranscriptContent: Decodable {
        case text(String)
        case blocks([TranscriptContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .text(string)
            } else {
                self = .blocks((try? container.decode([TranscriptContentBlock].self)) ?? [])
            }
        }
    }

    private struct TranscriptContentBlock: Decodable {
        let type: String
        let text: String?
    }

    /// `nil` if none sent yet. Only a `{"type":"message","message":{"role":"user",...}}` line counts.
    public static func firstUserPromptText(inTranscriptLines lines: [String]) -> String? {
        let decoder = JSONDecoder()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let parsed = try? decoder.decode(TranscriptLine.self, from: data) else { continue }
            guard parsed.type == "message", let message = parsed.message, message.role == "user" else { continue }
            switch message.content {
            case .text(let text):
                return text
            case .blocks(let blocks):
                if let text = blocks.first(where: { $0.type == "text" })?.text {
                    return text
                }
            }
        }
        return nil
    }

    // MARK: - Title derivation

    /// Collapsed to one line, stripped of markdown markers and leading
    /// punctuation, truncated at a word boundary. `nil` for empty/all-punctuation
    /// input, so callers can leave "New Task" instead of renaming to nothing.
    public static func deriveTitle(fromPrompt prompt: String, maxLength: Int = 48) -> String? {
        var text = prompt
        text.removeAll { "`*_#".contains($0) }

        var collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        while let first = collapsed.first, !(first.isLetter || first.isNumber) {
            collapsed.removeFirst()
        }
        collapsed = collapsed.trimmingCharacters(in: .whitespaces)

        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }

        let truncated = String(collapsed.prefix(maxLength))
        if let lastSpace = truncated.range(of: " ", options: .backwards) {
            let atWordBoundary = String(truncated[..<lastSpace.lowerBound])
            if !atWordBoundary.isEmpty { return atWordBoundary }
        }
        return truncated
    }

    // MARK: - Applying the rename

    /// Renames the branch too when the task has its own app-created branch,
    /// deduping like `TaskWorktreeService.createWorktree`; never touches
    /// `task.worktreePath`. Runs name-only (no git calls) otherwise.
    public static func applyRename(task: TaskRecord, project: Project, newName: String) async -> TaskRecord {
        var updated = task
        updated.name = newName
        updated.awaitingAutoRename = false

        guard task.worktreePath != project.path, task.branchCreatedByApp else {
            return updated
        }

        let baseSlug = TaskWorktreeService.slug(forTaskName: newName)
        let newSlug = await uniqueSlug(
            baseSlug: baseSlug,
            projectPath: project.path,
            currentBranchName: task.branchName
        )
        let newBranchName = "task/\(newSlug)"

        guard newBranchName != task.branchName else {
            return updated
        }

        let projectURL = URL(fileURLWithPath: project.path)

        do {
            try await GitCLI.renameBranch(task.branchName, to: newBranchName, at: projectURL)
            updated.branchName = newBranchName
        } catch {
            logger.error(
                "Auto-rename branch rename failed for task \(task.id ?? -1, privacy: .public): \(error, privacy: .public)"
            )
        }

        return updated
    }

    /// Like `TaskWorktreeService.uniqueSlug`, except the task's own current branch doesn't count as taken.
    private static func uniqueSlug(
        baseSlug: String,
        projectPath: String,
        currentBranchName: String
    ) async -> String {
        let projectURL = URL(fileURLWithPath: projectPath)
        var candidate = baseSlug
        var suffix = 2
        for _ in 0..<TaskWorktreeService.maxUniqueSlugAttempts {
            let candidateBranch = "task/\(candidate)"

            let branchTaken: Bool
            if candidateBranch == currentBranchName {
                branchTaken = false
            } else {
                branchTaken = (try? await GitCLI.branchExists(candidateBranch, at: projectURL)) ?? false
            }

            if !branchTaken { return candidate }
            candidate = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
