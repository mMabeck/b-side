import Foundation

/// Working-tree/index status and diffs for the Source Control sidebar.
///
/// Status and line counts are separate calls (`changedFiles` / `lineCounts`) so the
/// UI can render file kinds immediately and fill in +/- counts once numstat comes
/// back, rather than blocking the first paint on a second diff pass.
extension GitCLI {
    public struct FileChange: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case added
            case modified
            case deleted
            case renamed
            case typeChanged
            case untracked
            case conflicted
        }

        public enum Area: Sendable, Equatable {
            case staged
            case unstaged
        }

        public var path: String
        public var origPath: String?
        public var kind: Kind
        public var area: Area
        public var linesAdded: Int?
        public var linesRemoved: Int?
        public var isBinary: Bool

        public init(
            path: String,
            origPath: String? = nil,
            kind: Kind,
            area: Area,
            linesAdded: Int? = nil,
            linesRemoved: Int? = nil,
            isBinary: Bool = false
        ) {
            self.path = path
            self.origPath = origPath
            self.kind = kind
            self.area = area
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
            self.isBinary = isBinary
        }

        // A file with both staged and unstaged changes produces two `FileChange`
        // values with the same `path`; `area` is what keeps them distinct.
        public var id: String {
            "\(area == .staged ? "staged" : "unstaged"):\(path)"
        }
    }

    public struct LineCount: Sendable, Equatable {
        public let added: Int
        public let removed: Int
        public let isBinary: Bool
    }

    /// A file change committed on a branch, independent of staged/unstaged state
    /// (see `branchChanges`).
    public struct BranchFileChange: Sendable, Equatable, Identifiable {
        public var path: String
        public var origPath: String?
        public var kind: FileChange.Kind
        public var linesAdded: Int?
        public var linesRemoved: Int?
        public var isBinary: Bool

        public var id: String { path }
    }

    /// A diff's text, capped for the UI: full diffs beyond `diffSizeLimit` are
    /// truncated rather than handed whole to a text view, and binary files never
    /// get diff text at all.
    public struct DiffText: Sendable, Equatable {
        public let text: String
        public let isBinary: Bool
        public let isTruncated: Bool

        public static let binary = DiffText(text: "", isBinary: true, isTruncated: false)
    }

    static let diffSizeLimit = 512 * 1024

    // MARK: - Status

    /// Changed files, split into staged and unstaged `FileChange`s. A file with
    /// both staged and unstaged changes appears twice, once per area.
    public static func changedFiles(at path: URL) async throws -> [FileChange] {
        let data = try await run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            in: path
        )
        return parseStatusRecords(data)
    }

    static func parseStatusRecords(_ data: Data) -> [FileChange] {
        let tokens = splitNulDelimited(data)
        var changes: [FileChange] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard let marker = token.first else { continue }
            switch marker {
            case "1":
                changes.append(contentsOf: parseOrdinaryStatusRecord(token))
            case "2":
                // The rename/copy record is followed by an extra NUL-separated
                // origPath token that isn't part of the space-separated fields.
                guard index < tokens.count else { continue }
                let origPath = tokens[index]
                index += 1
                changes.append(contentsOf: parseRenamedStatusRecord(token, origPath: origPath))
            case "u":
                if let change = parseUnmergedStatusRecord(token) {
                    changes.append(change)
                }
            case "?":
                if let change = parseUntrackedStatusRecord(token) {
                    changes.append(change)
                }
            default:
                continue
            }
        }
        return changes
    }

    private static func statusKind(_ letter: Character) -> FileChange.Kind? {
        switch letter {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R", "C": return .renamed
        case "T": return .typeChanged
        default: return nil  // '.' (unchanged in this half)
        }
    }

    // `1 XY sub mH mI mW hH hI path` — 8 space-separated fields before path.
    private static func parseOrdinaryStatusRecord(_ token: String) -> [FileChange] {
        let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9 else { return [] }
        let xy = Array(fields[1])
        guard xy.count == 2 else { return [] }
        let path = fields[8]
        var changes: [FileChange] = []
        if let kind = statusKind(xy[0]) {
            changes.append(FileChange(path: path, kind: kind, area: .staged))
        }
        if let kind = statusKind(xy[1]) {
            changes.append(FileChange(path: path, kind: kind, area: .unstaged))
        }
        return changes
    }

    // `2 XY sub mH mI mW hH hI X<score> path` — 9 space-separated fields before path;
    // origPath arrives as a separate NUL token handled by the caller.
    private static func parseRenamedStatusRecord(_ token: String, origPath: String) -> [FileChange] {
        let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10 else { return [] }
        let xy = Array(fields[1])
        guard xy.count == 2 else { return [] }
        let path = fields[9]
        var changes: [FileChange] = []
        if let kind = statusKind(xy[0]) {
            changes.append(FileChange(path: path, origPath: origPath, kind: kind, area: .staged))
        }
        if let kind = statusKind(xy[1]) {
            changes.append(FileChange(path: path, origPath: origPath, kind: kind, area: .unstaged))
        }
        return changes
    }

    // `u XY sub m1 m2 m3 mW h1 h2 h3 path` — 10 space-separated fields before path.
    private static func parseUnmergedStatusRecord(_ token: String) -> FileChange? {
        let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 11 else { return nil }
        return FileChange(path: fields[10], kind: .conflicted, area: .unstaged)
    }

    // `? path`
    private static func parseUntrackedStatusRecord(_ token: String) -> FileChange? {
        let fields = token.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2 else { return nil }
        return FileChange(path: fields[1], kind: .untracked, area: .unstaged)
    }

    // MARK: - Line counts

    /// Added/removed line counts, keyed by path, loaded separately from
    /// `changedFiles` so the sidebar can show file kinds before diff stats land.
    public static func lineCounts(at path: URL) async throws -> (staged: [String: LineCount], unstaged: [String: LineCount]) {
        async let stagedData = run(["diff", "--cached", "--numstat", "-z"], in: path)
        async let unstagedData = run(["diff", "--numstat", "-z"], in: path)
        let staged = parseNumstat(try await stagedData)
        let unstaged = parseNumstat(try await unstagedData)
        return (staged, unstaged)
    }

    /// Line counts for a single untracked file, via `diff --no-index` against
    /// `/dev/null`. `--no-index` exits 1 when the compared files differ, which is
    /// the success case here, so it's in `allowedExitStatuses`.
    public static func lineCount(forUntracked filePath: String, at path: URL) async throws -> LineCount {
        let data = try await run(
            ["diff", "--no-index", "--numstat", "-z", "/dev/null", filePath],
            in: path,
            allowedExitStatuses: [1]
        )
        let counts = parseNumstat(data)
        return counts[filePath] ?? LineCount(added: 0, removed: 0, isBinary: false)
    }

    // `--numstat -z` prints `added\tremoved\tpath\0` per file, except for renames
    // (and the /dev/null-vs-file untracked comparison, which looks like a rename
    // from git's point of view): those print `added\tremoved\t\0` with an empty
    // path field, followed by the old and new paths as their own NUL tokens.
    // `-\t-` marks a binary file. Renames are keyed on the new path.
    static func parseNumstat(_ data: Data) -> [String: LineCount] {
        let tokens = splitNulDelimited(data)
        var result: [String: LineCount] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let isBinary = fields[0] == "-" || fields[1] == "-"
            let added = Int(fields[0]) ?? 0
            let removed = Int(fields[1]) ?? 0
            let path: String
            if fields[2].isEmpty {
                guard index + 1 < tokens.count else { continue }
                index += 1  // old path, unused
                path = tokens[index]
                index += 1
            } else {
                path = fields[2]
            }
            result[path] = LineCount(added: added, removed: removed, isBinary: isBinary)
        }
        return result
    }

    // MARK: - Stage / unstage / discard

    public static func stage(_ paths: [String], at path: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths, in: path)
    }

    public static func stageAll(at path: URL) async throws {
        _ = try await run(["add", "-A"], in: path)
    }

    /// Unstages `paths`. Falls back to `rm --cached` when the repo has no commits
    /// yet, since `restore --staged` needs a HEAD to restore from.
    public static func unstage(_ paths: [String], at path: URL) async throws {
        guard !paths.isEmpty else { return }
        do {
            _ = try await run(["restore", "--staged", "--"] + paths, in: path)
        } catch is CommandError {
            _ = try await run(["rm", "--cached", "--"] + paths, in: path)
        }
    }

    public static func unstageAll(at path: URL) async throws {
        do {
            _ = try await run(["restore", "--staged", "."], in: path)
        } catch is CommandError {
            _ = try await run(["rm", "-r", "--cached", "."], in: path)
        }
    }

    /// Reverts `paths` to their `HEAD` content, in both the index and the working
    /// tree, in one atomic `restore` so neither side lands out of sync with the
    /// other if the process is interrupted.
    ///
    /// Every path must already exist in `HEAD` — for a path with no `HEAD` entry
    /// (a file staged as newly added, or a rename's new name), `restore
    /// --source=HEAD` doesn't revert it, it deletes it outright, since there's
    /// nothing at that path in `HEAD` to restore. Callers must route those
    /// through `unstage` + Trash instead; see `SourceControlStore.discard`.
    ///
    /// Untracked files aren't handled here — the UI discards those via Trash.
    public static func discardTracked(_ paths: [String], at path: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths, in: path)
    }

    /// Reverts `paths` in the working tree only, from the index (`restore`'s
    /// default source when `--source` is omitted) — the index/staged state is
    /// left untouched. This is "Discard Changes" for an unstaged row: undo the
    /// edits on disk without touching whatever's staged for the same path.
    public static func discardWorktree(_ paths: [String], at path: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["restore", "--worktree", "--"] + paths, in: path)
    }

    /// Appends `filePath` to the worktree-root `.gitignore`, creating it if
    /// needed and skipping the append if the path is already listed. The
    /// pattern is anchored to the worktree root with a leading `/` and has its
    /// glob metacharacters, a leading `#`/`!`, and trailing spaces escaped, so
    /// an arbitrary tracked path can't be misread as a glob, a comment, a
    /// negation, or have trailing whitespace silently stripped.
    public static func addToGitignore(_ filePath: String, at path: URL) throws {
        let gitignoreURL = path.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        let existingLines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let pattern = gitignorePattern(for: filePath)
        guard !existingLines.contains(pattern) else { return }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += pattern + "\n"
        try updated.write(to: gitignoreURL, atomically: true, encoding: .utf8)
    }

    static func gitignorePattern(for filePath: String) -> String {
        // Trailing spaces are split off first and each re-added escaped, so a
        // path ending in a backslash and then a space keeps its space.
        let body = String(filePath.reversed().drop(while: { $0 == " " }).reversed())
        let trailingSpaces = filePath.count - body.count
        var escaped = ""
        for char in body {
            switch char {
            case "*", "?", "[", "\\":
                escaped.append("\\")
                escaped.append(char)
            default:
                escaped.append(char)
            }
        }
        escaped += String(repeating: "\\ ", count: trailingSpaces)
        if escaped.hasPrefix("#") || escaped.hasPrefix("!") {
            escaped = "\\" + escaped
        }
        return "/" + escaped
    }

    // MARK: - Diffs

    /// The diff for a single file, staged or unstaged against the working tree.
    public static func diff(for filePath: String, staged: Bool, at path: URL) async throws -> DiffText {
        var arguments = ["diff"]
        if staged { arguments.append("--cached") }
        arguments.append(contentsOf: ["--", filePath])
        let data = try await run(arguments, in: path)
        return makeDiffText(from: data)
    }

    /// The diff for an untracked file, shown as a full addition against `/dev/null`.
    public static func diffForUntracked(_ filePath: String, at path: URL) async throws -> DiffText {
        let data = try await run(
            ["diff", "--no-index", "/dev/null", filePath],
            in: path,
            allowedExitStatuses: [1]
        )
        return makeDiffText(from: data)
    }

    /// Everything committed on the current branch since `baseline`, i.e. `git diff
    /// baseline..HEAD` — committed work only, never against the dirty working tree.
    public static func branchChanges(since baseline: String, at path: URL) async throws -> [BranchFileChange] {
        let range = "\(baseline)..HEAD"
        async let nameStatusData = run(["diff", "--name-status", "-z", range], in: path)
        async let numstatData = run(["diff", "--numstat", "-z", range], in: path)
        let counts = parseNumstat(try await numstatData)
        return parseNameStatusRecords(try await nameStatusData, counts: counts)
    }

    /// The diff for a single file's committed changes since `baseline`.
    public static func branchDiff(for filePath: String, since baseline: String, at path: URL) async throws -> DiffText {
        let data = try await run(["diff", "\(baseline)..HEAD", "--", filePath], in: path)
        return makeDiffText(from: data)
    }

    private static func branchStatusKind(_ letter: Character) -> FileChange.Kind? {
        switch letter {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R", "C": return .renamed
        case "T": return .typeChanged
        default: return nil
        }
    }

    // `--name-status -z` prints `status\0path\0` per file, or `R<score>\0old\0new\0`
    // for a rename/copy.
    static func parseNameStatusRecords(_ data: Data, counts: [String: LineCount]) -> [BranchFileChange] {
        let tokens = splitNulDelimited(data)
        var changes: [BranchFileChange] = []
        var index = 0
        while index < tokens.count {
            let statusToken = tokens[index]
            index += 1
            guard let letter = statusToken.first, let kind = branchStatusKind(letter) else { continue }

            let path: String
            let origPath: String?
            if letter == "R" || letter == "C" {
                guard index + 1 < tokens.count else { break }
                origPath = tokens[index]
                index += 1
                path = tokens[index]
                index += 1
            } else {
                guard index < tokens.count else { break }
                origPath = nil
                path = tokens[index]
                index += 1
            }

            let count = counts[path]
            changes.append(
                BranchFileChange(
                    path: path,
                    origPath: origPath,
                    kind: kind,
                    linesAdded: count?.added,
                    linesRemoved: count?.removed,
                    isBinary: count?.isBinary ?? false
                )
            )
        }
        return changes
    }

    /// `detectBinary` is `false` for `showCommit`: a multi-file commit's patch
    /// can mix binary and text files, and flagging the whole thing binary (and
    /// discarding its text) because one file in it is would hide every other
    /// file's diff.
    static func makeDiffText(from data: Data, detectBinary: Bool = true) -> DiffText {
        // Cap before scanning for the binary marker, so a huge diff is never
        // decoded in full; a binary file's marker line is near the top anyway.
        let isTruncated = data.count > diffSizeLimit
        let capped = isTruncated ? data.prefix(diffSizeLimit) : data
        if detectBinary, containsBinaryMarker(capped) {
            return .binary
        }
        return DiffText(text: String(decoding: capped, as: UTF8.self), isBinary: false, isTruncated: isTruncated)
    }

    private static let binaryMarkerRegex = try! NSRegularExpression(pattern: #"(?m)^Binary files .* differ$"#)

    // `git diff` marks binary files with a "Binary files ... differ" line
    // instead of hunks. Matched as a whole line, not a substring anywhere in
    // the output, so a text diff that merely contains that phrase in its
    // content isn't misread as a binary file.
    private static func containsBinaryMarker(_ data: Data) -> Bool {
        // Lossy decoding: the cap can split a multi-byte character at the end.
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        return binaryMarkerRegex.firstMatch(in: text, range: range) != nil
    }
}
