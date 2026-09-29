import Foundation

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

        // A file with staged and unstaged changes yields two `FileChange`s with the same `path`; `area` keeps them distinct.
        public var id: String {
            "\(area == .staged ? "staged" : "unstaged"):\(path)"
        }
    }

    public struct LineCount: Sendable, Equatable {
        public let added: Int
        public let removed: Int
        public let isBinary: Bool
    }

    public struct BranchFileChange: Sendable, Equatable, Identifiable {
        public var path: String
        public var origPath: String?
        public var kind: FileChange.Kind
        public var linesAdded: Int?
        public var linesRemoved: Int?
        public var isBinary: Bool

        public var id: String { path }
    }

    public struct DiffText: Sendable, Equatable {
        public let text: String
        public let isBinary: Bool
        public let isTruncated: Bool

        public static let binary = DiffText(text: "", isBinary: true, isTruncated: false)
    }

    static let diffSizeLimit = 512 * 1024

    // MARK: - Status

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
                // Rename/copy records are followed by an extra NUL-separated origPath token.
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

    // `2 XY sub mH mI mW hH hI X<score> path` — origPath arrives as a separate NUL token handled by the caller.
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

    public static func lineCounts(at path: URL) async throws -> (staged: [String: LineCount], unstaged: [String: LineCount]) {
        async let stagedData = run(["diff", "--cached", "--numstat", "-z"], in: path)
        async let unstagedData = run(["diff", "--numstat", "-z"], in: path)
        let staged = parseNumstat(try await stagedData)
        let unstaged = parseNumstat(try await unstagedData)
        return (staged, unstaged)
    }

    /// `--no-index` exits 1 when the compared files differ — the success case here.
    public static func lineCount(forUntracked filePath: String, at path: URL) async throws -> LineCount {
        let data = try await run(
            ["diff", "--no-index", "--numstat", "-z", "/dev/null", filePath],
            in: path,
            allowedExitStatuses: [1]
        )
        let counts = parseNumstat(data)
        return counts[filePath] ?? LineCount(added: 0, removed: 0, isBinary: false)
    }

    // `--numstat -z` prints an empty path for renames (and untracked /dev/null comparisons), followed by old and new paths as NUL tokens; `-\t-` marks binary.
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

    /// Falls back to `rm --cached` when the repo has no commits yet, since `restore --staged` needs a HEAD.
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

    /// One atomic `restore`. Every path must exist in `HEAD`, or `--source=HEAD` deletes instead of reverting; route new/renamed paths through `unstage` + Trash.
    public static func discardTracked(_ paths: [String], at path: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths, in: path)
    }

    public static func discardWorktree(_ paths: [String], at path: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["restore", "--worktree", "--"] + paths, in: path)
    }

    /// Escapes glob metacharacters, a leading `#`/`!`, and trailing spaces so an arbitrary path can't be misread.
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
        // Trailing spaces are split off and re-added escaped so a path ending in backslash+space keeps its space.
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

    // MARK: - Combined working-tree changes (Changes overlay)

    public static func untrackedPaths(at path: URL) async throws -> [String] {
        let data = try await run(
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            in: path
        )
        return parseStatusRecords(data).filter { $0.kind == .untracked }.map(\.path)
    }

    /// Above this many, per-file `diff --no-index` is too much process spawning for one refresh.
    public static let untrackedLineCountThreshold = 200

    public static func lineCounts(forUntracked paths: [String], at path: URL, maxConcurrent: Int = 8) async -> [String: LineCount] {
        guard !paths.isEmpty, paths.count <= untrackedLineCountThreshold else { return [:] }
        var result: [String: LineCount] = [:]
        var remaining = paths[...]
        await withTaskGroup(of: (String, LineCount?).self) { group in
            func addNext() {
                guard let next = remaining.popFirst() else { return }
                group.addTask {
                    let count = try? await lineCount(forUntracked: next, at: path)
                    return (next, count)
                }
            }
            for _ in 0..<min(maxConcurrent, paths.count) {
                addNext()
            }
            while let (next, count) = await group.next() {
                if let count {
                    result[next] = count
                }
                addNext()
            }
        }
        return result
    }

    /// `.uncommitted` mode passes `"HEAD"`; `.all` passes the task's baseline commit.
    public static func workingTreeChanges(against ref: String, at path: URL) async throws -> [BranchFileChange] {
        async let nameStatusData = run(["diff", "--name-status", "-z", ref], in: path)
        async let numstatData = run(["diff", "--numstat", "-z", ref], in: path)
        let counts = parseNumstat(try await numstatData)
        var changes = parseNameStatusRecords(try await nameStatusData, counts: counts)

        // A path deleted since `ref` and recreated untracked appears in both; keep the diff's entry so `id` stays unique.
        let existingPaths = Set(changes.map(\.path))
        let untracked = try await untrackedPaths(at: path).filter { !existingPaths.contains($0) }
        guard !untracked.isEmpty else { return changes }
        let untrackedCounts = await lineCounts(forUntracked: untracked, at: path)
        changes.append(
            contentsOf: untracked.map { untrackedPath in
                let count = untrackedCounts[untrackedPath]
                return BranchFileChange(
                    path: untrackedPath,
                    kind: .untracked,
                    linesAdded: count?.added,
                    linesRemoved: count?.removed,
                    isBinary: count?.isBinary ?? false
                )
            }
        )
        return changes
    }

    public static func fileContent(_ filePath: String, at ref: String, in path: URL) async throws -> Data {
        try await run(["show", "\(ref):\(filePath)"], in: path)
    }

    public static func workingTreeDiff(
        for filePath: String, origPath: String? = nil, against ref: String, fullFile: Bool = false, at path: URL
    ) async throws -> DiffText {
        var arguments = ["--literal-pathspecs", "diff"] + contextArguments(fullFile: fullFile) + [ref, "--"]
        if let origPath { arguments.append(origPath) }
        arguments.append(filePath)
        let data = try await run(arguments, in: path)
        return makeDiffText(from: data)
    }

    // MARK: - Diffs

    // git has no "whole file" flag; a context larger than any real file yields one hunk spanning it.
    private static func contextArguments(fullFile: Bool) -> [String] {
        fullFile ? ["--unified=\(Int32.max)"] : []
    }

    public static func diff(for filePath: String, staged: Bool, at path: URL) async throws -> DiffText {
        var arguments = ["diff"]
        if staged { arguments.append("--cached") }
        arguments.append(contentsOf: ["--", filePath])
        let data = try await run(arguments, in: path)
        return makeDiffText(from: data)
    }

    public static func diffForUntracked(_ filePath: String, at path: URL) async throws -> DiffText {
        let data = try await run(
            ["diff", "--no-index", "/dev/null", filePath],
            in: path,
            allowedExitStatuses: [1]
        )
        return makeDiffText(from: data)
    }

    public static func branchChanges(since baseline: String, at path: URL) async throws -> [BranchFileChange] {
        let range = "\(baseline)..HEAD"
        async let nameStatusData = run(["diff", "--name-status", "-z", range], in: path)
        async let numstatData = run(["diff", "--numstat", "-z", range], in: path)
        let counts = parseNumstat(try await numstatData)
        return parseNameStatusRecords(try await nameStatusData, counts: counts)
    }

    public static func branchDiff(
        for filePath: String, origPath: String? = nil, since baseline: String, fullFile: Bool = false, at path: URL
    ) async throws -> DiffText {
        var arguments = ["--literal-pathspecs", "diff"] + contextArguments(fullFile: fullFile) + ["\(baseline)..HEAD", "--"]
        if let origPath { arguments.append(origPath) }
        arguments.append(filePath)
        let data = try await run(arguments, in: path)
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

    // `--name-status -z` prints `status\0path\0`, or `R<score>\0old\0new\0` for a rename/copy.
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

    /// `detectBinary` is `false` for `showCommit`: a mixed binary/text patch would otherwise hide every file's diff.
    static func makeDiffText(from data: Data, detectBinary: Bool = true) -> DiffText {
        // Cap before scanning for the binary marker so a huge diff is never decoded in full.
        let isTruncated = data.count > diffSizeLimit
        let capped = isTruncated ? data.prefix(diffSizeLimit) : data
        if detectBinary, containsBinaryMarker(capped) {
            return .binary
        }
        return DiffText(text: String(decoding: capped, as: UTF8.self), isBinary: false, isTruncated: isTruncated)
    }

    private static let binaryMarkerRegex = try! NSRegularExpression(pattern: #"(?m)^Binary files .* differ$"#)

    // Matched as a whole line so a text diff merely containing the phrase isn't misread as binary.
    private static func containsBinaryMarker(_ data: Data) -> Bool {
        // Lossy decoding: the cap can split a multi-byte character at the end.
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        return binaryMarkerRegex.firstMatch(in: text, range: range) != nil
    }
}
