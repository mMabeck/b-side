import Foundation

/// Resolves and launches `pi` CLI sessions for a task's agent terminal, so
/// reopening a task or restarting the app resumes the same pi session
/// instead of starting a fresh one.
///
/// Every filesystem lookup goes through `Locations`, which is injectable so
/// tests can point it at a temp directory instead of the real
/// `~/.pi/agent`.
public enum PiSessionService {
    /// Where `pi` keeps its own state on disk, plus how to find its binary.
    /// Rooted at `$HOME` by `standard(homeDirectory:)`, but every field is a
    /// plain value/closure so tests can substitute a temp directory and a
    /// fake "is pi on PATH" answer without touching the real filesystem or
    /// environment.
    public struct Locations: Sendable {
        /// `~/.pi/agent/bin/pi`, if that file exists; `nil` otherwise.
        public var bundledBinaryPath: String?
        /// `~/.pi/agent/sessions`, where transcript JSONL files live.
        public var sessionsRoot: URL
        /// Resolves `pi` on `$PATH`. Overridable so tests can simulate "pi
        /// is/isn't on PATH" without depending on the real PATH.
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

        /// The real `~/.pi/agent`, resolved against `homeDirectory`
        /// (`$HOME` by default).
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

    /// Searches `$PATH` for an executable, non-directory file named `pi`.
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

    /// The bundled `pi` binary if present, else whatever `pi` resolves to on
    /// `$PATH`, else `nil` when neither exists.
    public static func resolveBinary(locations: Locations) -> String? {
        locations.bundledBinaryPath ?? locations.pathBinaryFinder()
    }

    /// A fresh session id for a task's first agent-terminal launch.
    public static func newSessionID() -> String {
        UUID().uuidString
    }

    /// The command to launch a task's agent terminal, handed straight to the
    /// terminal surface's shell. Resumes `transcriptPath` when it's already
    /// known on disk — a specific file that stays valid even if the task's
    /// working directory later changes — otherwise targets `sessionID` via
    /// `--session-id`, which `pi` creates if it doesn't exist yet. The two
    /// cases collapse into one function because they differ only in which
    /// session-selecting flag is used: a first launch is simply a "resume"
    /// with no transcript resolved yet.
    ///
    /// Falls back to a plain login shell when `locations` has no `pi`
    /// binary at all, so the terminal still opens instead of staying dead.
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

    /// The bottom drawer's scratch terminal keeps this as its default
    /// command; the task agent terminal uses it only as `launchCommand`'s
    /// fallback when no `pi` binary can be found.
    public static func loginShellFallbackCommand(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) -> String {
        "\(shell) -l"
    }

    /// POSIX single-quote escaping: wraps `value` in single quotes, escaping
    /// any embedded single quote as `'\''`. Safe for any path handed to a
    /// shell, regardless of spaces or other shell metacharacters.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Transcript lookup

    /// Finds the transcript JSONL file under `locations.sessionsRoot` whose
    /// header line's `"id"` matches `sessionID`. Pi lays transcripts out as
    /// `<sessionsRoot>/<slugified-cwd>/<timestamp>_<uuid>.jsonl`, so this
    /// walks every subdirectory rather than reimplementing pi's own cwd
    /// slugifier to predict one exact path.
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

    /// Reads just enough of `url` to parse its first line and, if it is a
    /// `{"type":"session","id":"...",...}` header, returns the id.
    static func parseSessionID(atFirstLineOf url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        // A session header line is small; 64 KiB is generous headroom
        // without reading an entire (potentially long-running) transcript.
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

    /// Parses a transcript's first line as a session header, returning its
    /// id only when `"type"` is `"session"`.
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

    /// Repairs `transcriptPath` so `pi --session <path>` can resume it from
    /// `currentWorkingDirectory`, and returns the path to hand to
    /// `launchCommand` afterwards.
    ///
    /// `pi` refuses to resume a transcript whose header `cwd` no longer
    /// matches where it's about to run (it prints "Stored session working
    /// directory does not exist" and exits 1) — which happens whenever
    /// `TaskAutoRenameService.applyRename` has moved the task's worktree
    /// since the transcript was created. This is deliberately called only at
    /// resume time, never during the rename itself: the rename runs moments
    /// after the user's first prompt, while `pi` is still the live writer of
    /// that file, so rewriting it then would race with pi's own appends. By
    /// resume time no process owns the file.
    ///
    /// Compares paths with symlinks resolved, since macOS reports `/tmp/x`
    /// as `/private/tmp/x` and pi stores the resolved form. A no-op (returns
    /// `transcriptPath` unchanged) both when the header already matches, and
    /// when the header's stored `cwd` is different but still exists on disk
    /// — that's a genuinely different, still-valid directory (not the
    /// worktree-got-moved case this exists for), and rewriting a healthy
    /// transcript on that basis would wrongly relocate it. Otherwise rewrites
    /// only the header line's `cwd` field — every other field and every
    /// other line is preserved byte-for-byte — and moves the file into the
    /// sessions subdirectory for the new cwd (see
    /// `sessionsSubdirectoryName(forCWD:)`).
    ///
    /// Returns `nil` when `transcriptPath` doesn't exist, can't be read, or
    /// doesn't start with a parseable `{"type":"session",...}` header —
    /// callers should treat that as "no usable transcript" and fall back to
    /// starting a fresh session rather than launching a command that's
    /// guaranteed to exit 1.
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
        // Only repair when the stored directory has genuinely vanished (the
        // actual auto-rename-moved-the-worktree case this exists for). A
        // merely-different-but-still-real directory means the caller isn't
        // resuming from a broken cwd, and rewriting a healthy transcript on
        // that basis would wrongly relocate it.
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

    /// What `ensureHost` should launch with, and what (if anything) it
    /// should persist back onto the `Conversation` afterwards.
    public struct ResolvedTranscript: Equatable, Sendable {
        /// The path to hand `launchCommand` as `transcriptPath`. `nil` means
        /// launch with `--session-id` instead — either this is the
        /// conversation's first launch, or no transcript for its session id
        /// exists anywhere under `locations.sessionsRoot`.
        public let transcriptPathForLaunch: String?
        /// The path to persist onto the `Conversation` via
        /// `ProjectsStore.recordTranscriptPath`, when it differs from what's
        /// already stored (freshly located, or relocated by a repair). `nil`
        /// when nothing changed.
        public let transcriptPathToPersist: String?
    }

    /// Resolves which transcript (if any) to resume `conversation` from,
    /// repairing a stale stored `cwd` along the way.
    ///
    /// Looks the transcript up by session id via `locateTranscript` —
    /// scanning the whole sessions tree — whenever `conversation`'s own
    /// `transcriptPath` is still empty, rather than depending on it having
    /// already been captured by `resolveTranscriptPath`'s bounded polling
    /// loop. That loop is best-effort and gives up after ~10 seconds; a
    /// reopened task can easily outlive it, and a stale `transcriptPath`
    /// must never be the reason resume falls back to `--session-id`.
    ///
    /// Once a candidate transcript is found, `repairTranscriptForResume`
    /// decides whether its stored `cwd` needs rewriting to
    /// `currentWorkingDirectory` (or is fine as-is) — this function only
    /// decides *whether there is a transcript to hand it at all*.
    ///
    /// Falls back to `transcriptPathForLaunch: nil` (i.e. `--session-id`)
    /// only when no transcript for this session id exists anywhere, or the
    /// one found is unreadable/malformed. This is deliberately the last
    /// resort, not a safe default: `pi --session-id <id>` run from a
    /// directory other than the one the session was created in does not
    /// find that session by id — lookup is scoped to the working directory
    /// — it prints "Warning: No project session found with id '<id>';
    /// creating a new session with that id" and silently starts a brand-new
    /// *empty* session, exit 0, quietly discarding the entire prior
    /// conversation. Do not "simplify" this back to always using
    /// `--session-id`: it looks safe (no crash, no error) precisely because
    /// it fails silently.
    public static func resolveTranscriptForResume(
        conversation: Conversation,
        currentWorkingDirectory: String,
        locations: Locations
    ) -> ResolvedTranscript {
        let candidatePath: String?
        if !conversation.transcriptPath.isEmpty {
            candidatePath = conversation.transcriptPath
        } else {
            candidatePath = locateTranscript(sessionID: conversation.sessionId, locations: locations)?.path
        }

        guard let candidatePath else {
            return ResolvedTranscript(transcriptPathForLaunch: nil, transcriptPathToPersist: nil)
        }

        guard let repairedPath = repairTranscriptForResume(
            transcriptPath: candidatePath,
            currentWorkingDirectory: currentWorkingDirectory,
            locations: locations
        ) else {
            return ResolvedTranscript(transcriptPathForLaunch: nil, transcriptPathToPersist: nil)
        }

        let pathToPersist = repairedPath != conversation.transcriptPath ? repairedPath : nil
        return ResolvedTranscript(transcriptPathForLaunch: repairedPath, transcriptPathToPersist: pathToPersist)
    }

    /// Pi's sessions-subdirectory naming rule for a working directory,
    /// observed empirically: `--` + `cwd` with every run of non-alphanumeric
    /// characters collapsed to a single `-` and leading/trailing `-` trimmed
    /// + `--`, e.g. `/Users/me/worktrees/task-1` →
    /// `--Users-me-worktrees-task-1--`.
    ///
    /// Only used to know where to *relocate* a repaired transcript to —
    /// `locateTranscript` never trusts this to *find* one, since an
    /// imprecise slug here must never be able to break resume.
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
