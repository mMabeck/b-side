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
}
