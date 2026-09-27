import Foundation

/// Resolves and launches `pi` CLI sessions for a task's agent terminal, so
/// reopening a task resumes the same pi session instead of a fresh one.
public enum PiSessionService {
    /// Every field is a plain value/closure so tests can substitute a temp directory/PATH answer.
    public struct Locations: Sendable {
        /// `~/.pi/agent/bin/pi`, if that file exists.
        public var bundledBinaryPath: String?
        /// `~/.pi/agent/sessions`, where transcript JSONL files live.
        public var sessionsRoot: URL
        public var pathBinaryFinder: @Sendable () -> String?

        public init(
            bundledBinaryPath: String?,
            sessionsRoot: URL,
            pathBinaryFinder: @escaping @Sendable () -> String? = { PiSessionService.findBinaryOnPath() }
        ) {
            self.bundledBinaryPath = bundledBinaryPath
            self.sessionsRoot = sessionsRoot
            self.pathBinaryFinder = pathBinaryFinder
        }

        public static func standard(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> Locations {
            let agentRoot = homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
            let bundledBinary = agentRoot.appendingPathComponent("bin/pi")
            let bundledBinaryPath = FileManager.default.fileExists(atPath: bundledBinary.path)
                ? bundledBinary.path
                : nil
            return Locations(
                bundledBinaryPath: bundledBinaryPath,
                sessionsRoot: agentRoot.appendingPathComponent("sessions", isDirectory: true)
            )
        }
    }

    public static func findBinaryOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let pathVariable = environment["PATH"] else { return nil }
        let fileManager = FileManager.default
        for directory in pathVariable.split(separator: ":") {
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("pi")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate.path)
            {
                return candidate.path
            }
        }
        return nil
    }

    public static func resolveBinary(locations: Locations) -> String? {
        locations.bundledBinaryPath ?? locations.pathBinaryFinder()
    }

    public static func newSessionID() -> String {
        UUID().uuidString
    }

    /// Resumes `transcriptPath` when known, else targets `sessionID` via
    /// `--session-id` (which `pi` creates if absent). Falls back to a plain
    /// login shell when no `pi` binary is found, so the terminal still opens.
    public static func launchCommand(
        locations: Locations,
        sessionID: String,
        transcriptPath: String?,
        taskName: String,
        loginShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) -> String {
        guard let binary = resolveBinary(locations: locations) else {
            return loginShellFallbackCommand(shell: loginShell)
        }

        let sessionFlag: String
        if let transcriptPath, !transcriptPath.isEmpty {
            sessionFlag = "--session \(shellQuote(transcriptPath))"
        } else {
            sessionFlag = "--session-id \(shellQuote(sessionID))"
        }
        return "\(shellQuote(binary)) \(sessionFlag) --name \(shellQuote(taskName))"
    }

    /// `BSIDE_SUBAGENT_ENDPOINT` is set only if the server is already
    /// listening; the Pi-side spawner otherwise reads `ProjectsStore`'s address file.
    public static func launchEnvironment(taskId: Int64, subagentEndpoint: String?) -> [String: String] {
        var environment = ["BSIDE_TASK_ID": String(taskId)]
        if let subagentEndpoint, !subagentEndpoint.isEmpty {
            environment["BSIDE_SUBAGENT_ENDPOINT"] = subagentEndpoint
        }
        return environment
    }

    /// The drawer's default command; also `launchCommand`'s fallback when no `pi` binary is found.
    public static func loginShellFallbackCommand(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) -> String {
        "\(shell) -l"
    }

    /// POSIX single-quote escaping, safe for any path regardless of shell metacharacters.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Transcript lookup

    /// Pi lays transcripts out as `<sessionsRoot>/<slugified-cwd>/<ts>_<uuid>.jsonl`,
    /// so this walks every subdirectory rather than reimplementing pi's slugifier.
    public static func locateTranscript(sessionID: String, locations: Locations) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: locations.sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let headerID = parseSessionID(atFirstLineOf: url) else { continue }
            if headerID == sessionID { return url }
        }
        return nil
    }

    static func parseSessionID(atFirstLineOf url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        // 64 KiB is generous headroom without reading an entire (potentially long-running) transcript.
        let data = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        return parseSessionID(fromHeaderLine: String(firstLine))
    }

    private struct SessionHeader: Decodable {
        let type: String
        let id: String
    }

    static func parseSessionID(fromHeaderLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let header = try? JSONDecoder().decode(SessionHeader.self, from: data),
              header.type == "session"
        else {
            return nil
        }
        return header.id
    }

    // MARK: - Resume-time transcript repair

    /// `pi` refuses to resume a transcript whose header `cwd` no longer
    /// exists ("Stored session working directory does not exist", exit 1).
    /// Only fires for tasks renamed before `TaskAutoRenameService.applyRename`
    /// stopped moving worktrees, kept so resuming those older tasks still works.
    ///
    /// Compares paths with symlinks resolved (macOS reports `/tmp/x` as
    /// `/private/tmp/x`, pi stores the resolved form). No-op if the header
    /// already matches, or its stored `cwd` differs but still exists on disk
    /// (a genuinely different, valid directory — not the moved-worktree case).
    /// Otherwise rewrites only the header's `cwd` field and relocates the
    /// file (see `sessionsSubdirectoryName(forCWD:)`).
    ///
    /// `nil` means no usable transcript (missing, unreadable, or unparseable
    /// header) — callers should fall back to a fresh session.
    public static func repairTranscriptForResume(
        transcriptPath: String,
        currentWorkingDirectory: String,
        locations: Locations
    ) -> String? {
        let fileManager = FileManager.default
        let originalURL = URL(fileURLWithPath: transcriptPath)
        guard fileManager.fileExists(atPath: originalURL.path),
              let data = try? Data(contentsOf: originalURL),
              !data.isEmpty
        else {
            return nil
        }

        let headerData: Data
        let restData: Data
        if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
            headerData = data[data.startIndex..<newlineIndex]
            restData = data[data.index(after: newlineIndex)...]
        } else {
            headerData = data
            restData = Data()
        }

        guard var header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              header["type"] as? String == "session",
              let existingCWD = header["cwd"] as? String
        else {
            return nil
        }

        let resolvedExisting = URL(fileURLWithPath: existingCWD).resolvingSymlinksInPath().path
        let resolvedCurrent = URL(fileURLWithPath: currentWorkingDirectory).resolvingSymlinksInPath().path
        guard resolvedExisting != resolvedCurrent else { return transcriptPath }
        // Only repair when the stored directory has genuinely vanished; a
        // still-real directory means this isn't the moved-worktree case, and
        // rewriting a healthy transcript would wrongly relocate it.
        guard !fileManager.fileExists(atPath: resolvedExisting) else { return transcriptPath }

        header["cwd"] = resolvedCurrent
        guard let newHeaderData = try? JSONSerialization.data(withJSONObject: header) else { return nil }

        var newFileData = newHeaderData
        newFileData.append(UInt8(ascii: "\n"))
        newFileData.append(restData)

        let destinationDirectory = locations.sessionsRoot.appendingPathComponent(
            sessionsSubdirectoryName(forCWD: resolvedCurrent),
            isDirectory: true
        )
        let destinationURL = destinationDirectory.appendingPathComponent(originalURL.lastPathComponent)

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try newFileData.write(to: destinationURL, options: .atomic)
            if destinationURL.path != originalURL.path {
                try? fileManager.removeItem(at: originalURL)
            }
        } catch {
            return nil
        }

        return destinationURL.path
    }

    // MARK: - Resume-time transcript resolution

    public struct ResolvedTranscript: Equatable, Sendable {
        /// `nil` means launch with `--session-id` instead.
        public let transcriptPathForLaunch: String?
        /// The path to persist via `ProjectsStore.recordTranscriptPath`. `nil` if unchanged.
        public let transcriptPathToPersist: String?
    }

    /// Resolves which transcript to resume `conversation` from, repairing a
    /// stale stored `cwd` along the way. Always falls back to a full
    /// `locateTranscript` scan — by session id, ignoring a stored
    /// `transcriptPath` that's empty or fails to repair — rather than
    /// trusting `resolveTranscriptPath`'s best-effort polling loop (bounded
    /// to ~10s, easily outlived by a reopened task).
    ///
    /// `transcriptPathForLaunch: nil` (i.e. `--session-id`) is the last
    /// resort, not a safe default: `pi --session-id <id>` run from a
    /// different directory than the session was created in does not find it
    /// by id, and silently starts a brand-new *empty* session (exit 0),
    /// discarding the whole prior conversation. Do not "simplify" this back
    /// to always using `--session-id` — it fails silently.
    public static func resolveTranscriptForResume(
        conversation: Conversation,
        currentWorkingDirectory: String,
        locations: Locations
    ) -> ResolvedTranscript {
        func repaired(from candidatePath: String) -> ResolvedTranscript? {
            guard let repairedPath = repairTranscriptForResume(
                transcriptPath: candidatePath,
                currentWorkingDirectory: currentWorkingDirectory,
                locations: locations
            ) else {
                return nil
            }
            let pathToPersist = repairedPath != conversation.transcriptPath ? repairedPath : nil
            return ResolvedTranscript(transcriptPathForLaunch: repairedPath, transcriptPathToPersist: pathToPersist)
        }

        if !conversation.transcriptPath.isEmpty, let result = repaired(from: conversation.transcriptPath) {
            return result
        }

        if let located = locateTranscript(sessionID: conversation.sessionId, locations: locations)?.path,
           let result = repaired(from: located)
        {
            return result
        }

        return ResolvedTranscript(transcriptPathForLaunch: nil, transcriptPathToPersist: nil)
    }

    /// Pi's sessions-subdirectory naming rule, observed empirically:
    /// non-alphanumeric runs collapsed to `-`, wrapped in `--`, e.g.
    /// `/Users/me/worktrees/task-1` → `--Users-me-worktrees-task-1--`. Only
    /// used to *relocate* a repaired transcript; `locateTranscript` never trusts this to find one.
    static func sessionsSubdirectoryName(forCWD cwd: String) -> String {
        var result = ""
        var lastWasHyphen = true
        for scalar in cwd.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return "--\(result)--"
    }
}
