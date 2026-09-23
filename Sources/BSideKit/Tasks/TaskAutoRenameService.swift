import Foundation
import OSLog

/// Automatic task renaming from a task's first pi prompt: a task created
/// with a blank name (`TaskRecord.awaitingAutoRename`) is renamed once its
/// user types their first prompt into its agent terminal, and its worktree
/// directory and app-created branch are renamed to match.
///
/// The transcript parsing and title derivation below are pure and call no
/// model; only `applyRename` touches git or the filesystem.
public enum TaskAutoRenameService {
    static let logger = Logger(subsystem: "ai.syv.bside", category: "task-auto-rename")

    // MARK: - Transcript parsing

    /// One line of a pi transcript, as much of it as this parser cares
    /// about. Every other line type (`session`, `session_info`,
    /// `model_change`, `thinking_level_change`, ...) fails to decode
    /// `message` and is skipped.
    private struct TranscriptLine: Decodable {
        let type: String
        let message: TranscriptMessage?
    }

    private struct TranscriptMessage: Decodable {
        let role: String
        let content: TranscriptContent
    }

    /// A message's `content` is either a plain string or an array of typed
    /// blocks (text, tool calls, tool results, thinking, ...) \u2014 pi uses both
    /// shapes depending on role and harness.
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

    /// The text of the first *user* prompt in a transcript's lines, or `nil`
    /// if none has been sent yet. Ignores the session header, model/thinking
    /// metadata lines, assistant messages, and tool results \u2014 only a
    /// `{"type":"message","message":{"role":"user",...}}` line counts, and
    /// its content is read as a plain string or the first `"text"` block.
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

    /// Derives a task title from a raw prompt: collapsed to one line,
    /// stripped of markdown emphasis/code/heading markers and leading
    /// punctuation, whitespace collapsed, then truncated at a word boundary
    /// to roughly `maxLength` characters. Returns `nil` for empty or
    /// all-punctuation input, so callers can leave the task named
    /// "New Task" instead of renaming it to nothing.
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

    /// Renames `task` to `newName`, and \u2014 when it has its own worktree on a
    /// branch the app created \u2014 renames that branch and moves the worktree
    /// directory to match, deduping against any existing branch/directory the
    /// same way `TaskWorktreeService.createWorktree` does. Always clears
    /// `awaitingAutoRename` on the returned record, so a caller persisting it
    /// never re-fires this for the same task.
    ///
    /// Runs in place (task name only, no git/filesystem calls) when the task
    /// has no worktree of its own or its branch predates the app. The branch
    /// rename and worktree move are applied \u2014 and persisted to the returned
    /// record \u2014 independently: a git failure is logged, and if it happens
    /// after the branch rename already succeeded, the returned record's
    /// `branchName` still reflects that so it never names a branch that no
    /// longer exists on disk.
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
            currentWorktreePath: task.worktreePath,
            currentBranchName: task.branchName
        )
        let newBranchName = "task/\(newSlug)"
        let newWorktreePath = TaskWorktreeService.worktreePath(forProjectAt: project.path, slug: newSlug)

        guard newBranchName != task.branchName || newWorktreePath != task.worktreePath else {
            return updated
        }

        let projectURL = URL(fileURLWithPath: project.path)

        do {
            try await GitCLI.renameBranch(task.branchName, to: newBranchName, at: projectURL)
            // Persisted immediately: the branch has already been renamed on
            // disk, so the record must say so even if the worktree move below fails.
            updated.branchName = newBranchName
        } catch {
            logger.error(
                "Auto-rename branch rename failed for task \(task.id ?? -1, privacy: .public): \(error, privacy: .public)"
            )
            return updated
        }

        do {
            try await GitCLI.moveWorktree(
                from: URL(fileURLWithPath: task.worktreePath),
                to: URL(fileURLWithPath: newWorktreePath),
                in: projectURL
            )
            updated.worktreePath = newWorktreePath
        } catch {
            logger.error(
                "Auto-rename worktree move failed for task \(task.id ?? -1, privacy: .public): \(error, privacy: .public)"
            )
        }

        return updated
    }

    /// A slug derived from `baseSlug` whose worktree directory and branch
    /// name are both free, suffixing with `-2`, `-3`, \u2026 like
    /// `TaskWorktreeService.uniqueSlug` \u2014 except a candidate that matches the
    /// task's own current path/branch doesn't count as taken, since that's
    /// exactly what's being renamed away from.
    private static func uniqueSlug(
        baseSlug: String,
        projectPath: String,
        currentWorktreePath: String,
        currentBranchName: String
    ) async -> String {
        let projectURL = URL(fileURLWithPath: projectPath)
        var candidate = baseSlug
        var suffix = 2
        for _ in 0..<TaskWorktreeService.maxUniqueSlugAttempts {
            let candidatePath = TaskWorktreeService.worktreePath(forProjectAt: projectPath, slug: candidate)
            let candidateBranch = "task/\(candidate)"

            let pathTaken = candidatePath != currentWorktreePath && FileManager.default.fileExists(atPath: candidatePath)
            let branchTaken: Bool
            if candidateBranch == currentBranchName {
                branchTaken = false
            } else {
                branchTaken = (try? await GitCLI.branchExists(candidateBranch, at: projectURL)) ?? false
            }

            if !pathTaken && !branchTaken { return candidate }
            candidate = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
