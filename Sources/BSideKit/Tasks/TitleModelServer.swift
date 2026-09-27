import Darwin
import Foundation
import OSLog

/// Keeps a resident `llama-server` process warm on 127.0.0.1 so repeated
/// auto-rename title requests skip llama.cpp's cold-start model load (which
/// `TaskTitleGenerator`'s per-call `llama-completion` process pays every
/// time). `TaskTitleGenerator.generate` tries this server first and falls
/// back to a cold `llama-completion` process if it never comes up.
///
/// A single shared instance owns at most one server process, launched lazily
/// on first `prewarm`/`generate` call, torn down after `idleShutdownDelay`
/// of inactivity or by an explicit `shutdown()`. `MainAreaView` calls
/// `prewarm()` as soon as a task starts waiting for its auto-rename title,
/// so the model is loaded by the time the user's first prompt lands.
public actor TitleModelServer {
    public static let shared = TitleModelServer()

    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "title-model-server")

    /// Same install-prefix probing rationale as `TaskTitleGenerator`'s
    /// `llama-completion` lookup: a GUI app's `PATH` typically excludes
    /// Homebrew.
    private static let binaryCandidates = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
    ]

    private static let healthPollInterval: TimeInterval = 0.05
    private static let healthPollTimeout: TimeInterval = 10
    private static let requestTimeout: TimeInterval = 5

    /// How long the server stays resident with no `prewarm`/`generate`
    /// activity before it's torn down, so an app left open overnight
    /// doesn't keep ~800 MB pinned for a feature nobody's using.
    private static let idleShutdownDelay: TimeInterval = 3 * 60

    private var process: Process?
    private var port: UInt16?
    private var isReady = false
    private var isLaunching = false
    private var readyContinuations: [CheckedContinuation<Bool, Never>] = []
    private var idleShutdownTask: Task<Void, Never>?

    private init() {}

    /// The current server process's pid, if one is running — for tests to
    /// confirm the process is actually gone after `shutdown()`.
    var debugProcessIdentifier: Int32? {
        process?.processIdentifier
    }

    /// Launches the server if it isn't already running or launching, and
    /// waits for `/health` to report ready. Idempotent and safe to call
    /// concurrently: a call that arrives mid-launch waits on the same
    /// readiness signal instead of starting a second process.
    public func prewarm() async {
        _ = await ensureRunning()
    }

    /// Prewarms if needed, then POSTs `prompt` to the resident server's
    /// `/completion` endpoint and returns a cleaned title, or `nil` on any
    /// failure — server didn't come up, request failed or timed out, or the
    /// response's `content` failed the same validation
    /// `TaskTitleGenerator.cleanTitle` applies to `llama-completion`'s
    /// output — so the caller can fall back to a cold process.
    public func generate(prompt: String) async -> String? {
        guard await ensureRunning(), let port else { return nil }
        noteActivity()

        let body: [String: Any] = [
            "prompt": prompt,
            "n_predict": 16,
            "temperature": 0,
            "cache_prompt": false,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/completion")!)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeout

        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
            let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200
        else {
            Self.logger.notice("title server request failed or timed out")
            return nil
        }

        guard let content = Self.parseCompletionContent(fromResponseData: data) else {
            Self.logger.notice("title server response had no usable content")
            return nil
        }

        return TaskTitleGenerator.cleanTitle(fromRawOutput: content)
    }

    /// Terminates the resident server, if any, and resets state so the next
    /// `prewarm`/`generate` call launches a fresh one. Waits for the process
    /// to actually exit rather than just signalling it, so callers (idle
    /// shutdown, app termination, tests) can rely on the server being gone
    /// once this returns.
    public func shutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil

        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        port = nil
        isReady = false
        clearPidfile()

        let wasLaunching = isLaunching
        isLaunching = false
        if wasLaunching {
            failPendingReadiness()
        }
    }

    // MARK: - Launch

    @discardableResult
    private func ensureRunning() async -> Bool {
        if isReady {
            noteActivity()
            return true
        }
        if isLaunching {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                readyContinuations.append(continuation)
            }
        }

        isLaunching = true
        killOrphanFromPidfileIfAny()

        guard let binaryPath = Self.resolveBinaryPath() else {
            Self.logger.notice("title server skipped: llama-server binary not found")
            finishLaunch(success: false)
            return false
        }
        guard let modelPath = TaskTitleGenerator.resolveModelPath() else {
            Self.logger.notice("title server skipped: model file not found")
            finishLaunch(success: false)
            return false
        }
        guard let port = Self.pickAvailablePort() else {
            Self.logger.notice("title server skipped: no free port available")
            finishLaunch(success: false)
            return false
        }

        let process = Self.makeProcess(binaryPath: binaryPath, modelPath: modelPath, port: port)
        do {
            try process.run()
        } catch {
            Self.logger.notice("title server failed to launch: \(error, privacy: .public)")
            finishLaunch(success: false)
            return false
        }

        self.process = process
        self.port = port
        writePidfile(pid: process.processIdentifier)

        guard await waitForHealthy(port: port) else {
            Self.logger.notice("title server did not become healthy in time")
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            self.process = nil
            self.port = nil
            clearPidfile()
            finishLaunch(success: false)
            return false
        }

        Self.logger.notice("title server ready on port \(port)")
        isReady = true
        scheduleIdleShutdown()
        finishLaunch(success: true)
        return true
    }

    private func finishLaunch(success: Bool) {
        isLaunching = false
        failPendingReadiness(with: success)
    }

    private func failPendingReadiness(with value: Bool = false) {
        let pending = readyContinuations
        readyContinuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }

    private static func makeProcess(binaryPath: String, modelPath: String, port: UInt16) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-m", modelPath,
            "-ngl", "99",
            "-c", "512",
            "-fa", "on",
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        // Discarded outright rather than piped: nothing here reads
        // `llama-server`'s stdout/stderr, and a piped `Pipe` nobody drains
        // fills up and blocks the server once its buffer is full.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func waitForHealthy(port: UInt16) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.healthPollTimeout)
        let session = URLSession(configuration: .ephemeral)
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }

        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (data, response) = try? await session.data(for: request),
                let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (json["status"] as? String) == "ok"
            {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.healthPollInterval * 1_000_000_000))
        }
        return false
    }

    // MARK: - Idle shutdown

    private func noteActivity() {
        scheduleIdleShutdown()
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleShutdownDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.shutdown()
        }
    }

    // MARK: - Binary resolution

    private static func resolveBinaryPath() -> String? {
        for candidate in binaryCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/llama-server"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Port selection

    /// Picks a free TCP port by binding a socket to port 0 (the kernel
    /// assigns an ephemeral one), reading it back, then closing the socket
    /// so `llama-server` can bind it itself moments later.
    static func pickAvailablePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard getNameResult == 0 else { return nil }
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    // MARK: - Response parsing

    static func parseCompletionContent(fromResponseData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["content"] as? String
    }

    // MARK: - Pidfile / orphan safety

    private static func appSupportDirectory() -> URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }
        let directory = base.appendingPathComponent("B-Side", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pidfileURL() -> URL? {
        appSupportDirectory()?.appendingPathComponent("title-server.pid")
    }

    private func writePidfile(pid: Int32) {
        guard let url = Self.pidfileURL() else { return }
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    private func clearPidfile() {
        guard let url = Self.pidfileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Kills a previous run's leaked server, if the pidfile from a
    /// crashed/killed launch of B-Side names a still-live process whose
    /// executable really is `llama-server` — so a pid the OS has since
    /// reused for an unrelated process is never touched.
    private func killOrphanFromPidfileIfAny() {
        guard let url = Self.pidfileURL(),
            let contents = try? String(contentsOf: url, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        if Self.isProcessLlamaServer(pid: pid) {
            kill(pid, SIGTERM)
            Self.logger.notice("killed orphaned title server pid \(pid)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isProcessLlamaServer(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let comm = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return comm.hasSuffix("llama-server")
    }
}
