import Foundation
import OSLog

/// Generates a short task title from a user's first pi prompt, for
/// `ProjectsStore.applyAutoRename` to prefer over
/// `TaskAutoRenameService.deriveTitle`'s heuristic. The backend (a local
/// llama.cpp model, or the Claude/Codex CLI) comes from
/// `TitleGenerationSettings`. Every failure is logged as a distinct
/// `TitleGenerationFailure` and then collapsed to `nil` so the caller can
/// fall back unconditionally.
public enum TaskTitleGenerator {
    fileprivate static let logger = Logger(subsystem: "dev.mabeck.bside", category: "task-title-generator")

    /// A GUI app's `PATH` typically excludes Homebrew and user-local
    /// installs, so these are probed before whatever `PATH` the process has.
    private static var binaryDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
        ]
    }

    private static let localTimeout: TimeInterval = 15
    private static let cliTimeout: TimeInterval = 30
    /// How long a SIGTERM'd (or cancelled) child is given to exit on its own
    /// before escalating to SIGKILL.
    private static let terminationGracePeriod: TimeInterval = 1
    private static let maxTitleWords = 8
    private static let maxTitleLength = 60
    private static let endOfTextMarker = "[end of text]"
    private static let maxQuestionLength = 1000

    public static func generate(fromPrompt prompt: String) async -> String? {
        switch await generateResult(fromPrompt: prompt, settings: .load()) {
        case .success(let title):
            return title
        case .failure(let failure):
            log(failure)
            return nil
        }
    }

    /// Runs the configured backend and reports why it failed, for the
    /// Settings "Test" button. `.firstWords` always fails with `.disabled`.
    public static func generateResult(
        fromPrompt prompt: String,
        settings: TitleGenerationSettings,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async -> Result<String, TitleGenerationFailure> {
        switch settings.mode {
        case .firstWords:
            return .failure(.disabled)
        case .localModel:
            let modelURL = settings.localModelURL
            return await generateResult(
                fromPrompt: prompt,
                binaryPath: resolveBinary(named: "llama-completion"),
                modelPath: FileManager.default.fileExists(atPath: modelURL.path) ? modelURL.path : nil,
                template: settings.promptTemplate,
                timeout: localTimeout,
                gracePeriod: terminationGracePeriod,
                onLaunch: onLaunch
            )
        case .openAICompatible:
            return await requestTitle(settings: settings, prompt: prompt)
        case .claude, .codex:
            let binaryName = settings.mode == .claude ? "claude" : "codex"
            guard let binaryPath = resolveBinary(named: binaryName) else {
                return .failure(.binaryNotFound(binaryName))
            }
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("bside-title-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: outputFile) }
            let arguments = cliArguments(for: settings, prompt: prompt, outputFile: outputFile)
            return await runProcess(
                binaryPath: binaryPath,
                arguments: arguments,
                outputFile: settings.mode == .codex ? outputFile : nil,
                timeout: cliTimeout,
                gracePeriod: terminationGracePeriod,
                onLaunch: onLaunch
            )
        }
    }

    /// Testable core for the local model: takes already-resolved paths and
    /// explicit timing, so tests can point it at fake `#!/bin/sh` scripts
    /// and short timeouts. `onLaunch` is called once with the child's pid
    /// right after a successful `Process.run()`.
    static func generateResult(
        fromPrompt prompt: String,
        binaryPath: String?,
        modelPath: String?,
        template: String = TitleGenerationSettings.defaultPromptTemplate,
        timeout: TimeInterval,
        gracePeriod: TimeInterval,
        onLaunch: (@Sendable (pid_t) -> Void)? = nil
    ) async -> Result<String, TitleGenerationFailure> {
        guard let binaryPath else { return .failure(.binaryNotFound("llama-completion")) }
        guard let modelPath else { return .failure(.modelNotFound) }
        let fullPrompt = chatFormatted(instruction(template: template, prompt: prompt))

        let arguments = [
            "-m", modelPath,
            "-no-cnv",
            "--no-display-prompt",
            "--no-warmup",
            "-ngl", "99",
            "-c", "512",
            "-fa", "on",
            "--temp", "0",
            "-n", "16",
            "-p", fullPrompt,
        ]

        return await runProcess(
            binaryPath: binaryPath,
            arguments: arguments,
            outputFile: nil,
            timeout: timeout,
            gracePeriod: gracePeriod,
            onLaunch: onLaunch
        )
    }

    static func cliArguments(for settings: TitleGenerationSettings, prompt: String, outputFile: URL) -> [String] {
        let instruction = instruction(template: settings.promptTemplate, prompt: prompt)
        switch settings.mode {
        case .claude:
            // No tools, MCP servers, skills, settings files or saved session:
            // a bare one-shot completion.
            return [
                "-p",
                "--model", settings.claudeModel,
                "--tools", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--setting-sources", "",
                "--no-session-persistence",
                instruction,
            ]
        case .codex:
            var arguments = [
                "exec",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--color", "never",
                "--output-last-message", outputFile.path,
            ]
            if !settings.codexModel.isEmpty { arguments += ["--model", settings.codexModel] }
            return arguments + [instruction]
        case .firstWords, .localModel, .openAICompatible:
            return []
        }
    }

    /// Substitutes the first `maxQuestionLength` characters of `prompt` for
    /// `{prompt}`, or appends them when the template lacks the placeholder.
    public static func instruction(template: String, prompt: String) -> String {
        let question = String(prompt.prefix(maxQuestionLength))
        guard template.contains(TitleGenerationSettings.promptPlaceholder) else {
            return template + "\n\n" + question
        }
        return template.replacingOccurrences(of: TitleGenerationSettings.promptPlaceholder, with: question)
    }

    /// The exact text the configured backend receives.
    public static func modelInput(for settings: TitleGenerationSettings, prompt: String) -> String {
        let instruction = instruction(template: settings.promptTemplate, prompt: prompt)
        return settings.mode == .localModel ? chatFormatted(instruction) : instruction
    }

    /// The Qwen chat format with an empty think block, as the title models
    /// were fine-tuned on.
    private static func chatFormatted(_ instruction: String) -> String {
        """
        <|im_start|>user
        \(instruction)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
    }

    public static func resolveBinary(named name: String) -> String? {
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (binaryDirectories + pathDirectories).lazy
            .map { "\($0)/\(name)" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // MARK: - OpenAI-compatible endpoint

    /// Accepts the `/v1` base, with or without a trailing slash, or a pasted
    /// full `.../chat/completions` URL.
    static func chatCompletionsURL(baseURL: String) -> URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.hasSuffix("/chat/completions") { text += "/chat/completions" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    static func chatRequest(settings: TitleGenerationSettings, prompt: String) -> Result<URLRequest, TitleGenerationFailure> {
        guard let url = chatCompletionsURL(baseURL: settings.openAIBaseURL) else {
            return .failure(.invalidURL(settings.openAIBaseURL))
        }
        let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return .failure(.disabled) }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": instruction(template: settings.promptTemplate, prompt: prompt)]],
            "temperature": 0,
            "max_tokens": 32,
            "stream": false,
        ]
        var request = URLRequest(url: url, timeoutInterval: cliTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return .success(request)
    }

    /// Extracts `choices[0].message.content`, drops `<think>` blocks, and
    /// cleans the rest like the other backends' output.
    static func parseChatResponse(_ data: Data) -> Result<String, TitleGenerationFailure> {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choice = (root["choices"] as? [[String: Any]])?.first,
            let content = (choice["message"] as? [String: Any])?["content"] as? String
        else { return .failure(.unparseableResponse) }
        let visible = content.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        guard let title = cleanTitle(fromRawOutput: visible) else { return .failure(.rejectedOutput(raw: content)) }
        return .success(title)
    }

    private static func requestTitle(settings: TitleGenerationSettings, prompt: String) async -> Result<String, TitleGenerationFailure> {
        let request: URLRequest
        switch chatRequest(settings: settings, prompt: prompt) {
        case .success(let built): request = built
        case .failure(let failure): return .failure(failure)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                return .failure(.httpStatus(http.statusCode, body: snippet))
            }
            return parseChatResponse(data)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - Failure logging

    /// Missing binaries/models are expected on machines without them
    /// installed, so they log at `.notice`; everything else is `.error`.
    private static func log(_ failure: TitleGenerationFailure) {
        switch failure {
        case .disabled, .binaryNotFound, .modelNotFound, .cancelled:
            logger.notice("title generation skipped: \(failure.description, privacy: .public)")
        case .nonZeroExit(let status, let stderrTail):
            logger.error(
                "title generator exited with status \(status, privacy: .public), stderr: \(stderrTail, privacy: .private)"
            )
        case .rejectedOutput(let raw):
            logger.error("title generator output failed validation: \(raw, privacy: .private)")
        case .launchFailed, .timedOut, .signaled, .undecodableOutput, .invalidURL, .httpStatus,
            .unparseableResponse, .network:
            logger.error("title generation failed: \(failure.description, privacy: .public)")
        }
    }

    // MARK: - Output cleanup/validation

    /// Cleans the generator's output into a single-line title, or
    /// `nil` if the result doesn't look like one: everything from the
    /// `[end of text]` marker onward is dropped, the first non-empty line
    /// is trimmed of surrounding quotes and trailing punctuation, and the
    /// result is rejected if it's empty, over `maxTitleLength` characters,
    /// or more than `maxTitleWords` words.
    static func cleanTitle(fromRawOutput raw: String) -> String? {
        var text = raw
        if let markerRange = text.range(of: endOfTextMarker) {
            text = String(text[..<markerRange.lowerBound])
        }

        guard
            let firstLine = text
                .components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
        else {
            return nil
        }

        var cleaned = firstLine
        let quoteCharacters: Set<Character> = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        while let first = cleaned.first, quoteCharacters.contains(first) {
            cleaned.removeFirst()
        }
        while let last = cleaned.last, quoteCharacters.contains(last) {
            cleaned.removeLast()
        }
        while let last = cleaned.last, ".,!?;:".contains(last) {
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        guard !cleaned.isEmpty, cleaned.count <= maxTitleLength else { return nil }
        guard cleaned.split(separator: " ").count <= maxTitleWords else { return nil }
        return cleaned
    }

    // MARK: - Process execution

    /// Runs `binaryPath` with `arguments` (no shell) via `ProcessRunner`,
    /// which owns the SIGTERM→SIGKILL escalation on timeout/cancellation and
    /// guarantees the continuation resumes exactly once, only after the
    /// child has actually exited (or been killed and reaped) or failed to
    /// launch.
    static func runProcess(
        binaryPath: String,
        arguments: [String],
        outputFile: URL?,
        timeout: TimeInterval,
        gracePeriod: TimeInterval,
        onLaunch: (@Sendable (pid_t) -> Void)?
    ) async -> Result<String, TitleGenerationFailure> {
        let runner = ProcessRunner(binaryPath: binaryPath, arguments: arguments, outputFile: outputFile)
        return await withTaskCancellationHandler {
            await runner.run(timeout: timeout, gracePeriod: gracePeriod, onLaunch: onLaunch)
        } onCancel: {
            runner.cancel(gracePeriod: gracePeriod)
        }
    }
}

/// Every distinguishable way title generation can fail. `Error` reasons are
/// captured as their description rather than the `Error` itself so this
/// stays `Sendable`.
public enum TitleGenerationFailure: Error, Sendable, CustomStringConvertible {
    case disabled
    case binaryNotFound(String)
    case modelNotFound
    case launchFailed(String)
    case cancelled
    case timedOut
    case nonZeroExit(status: Int32, stderrTail: String)
    case signaled(signal: Int32)
    case undecodableOutput
    case rejectedOutput(raw: String)
    case invalidURL(String)
    case httpStatus(Int, body: String)
    case unparseableResponse
    case network(String)

    public var description: String {
        switch self {
        case .disabled: "No model is configured."
        case .binaryNotFound(let name): "`\(name)` was not found."
        case .modelNotFound: "The model file does not exist."
        case .launchFailed(let reason): "Failed to launch: \(reason)"
        case .cancelled: "Cancelled."
        case .timedOut: "Timed out."
        case .nonZeroExit(let status, let stderrTail):
            "Exited with status \(status). \(stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        case .signaled(let signal): "Killed by signal \(signal)."
        case .undecodableOutput: "Output was not valid UTF-8."
        case .rejectedOutput(let raw): "Output didn't look like a title: \(raw.prefix(120))"
        case .invalidURL(let url): "Not a valid endpoint URL: \(url)"
        case .httpStatus(let status, let body): "HTTP \(status). \(body)"
        case .unparseableResponse: "The response had no choices[0].message.content."
        case .network(let reason): "Network error: \(reason)"
        }
    }
}

/// Accumulates a process's output bytes across reads on a background
/// dispatch source, mirroring `LineBuffer`'s lock pattern since closures
/// crossing into `Process`'s callback queues aren't `Sendable` under Swift 6
/// strict concurrency.
private final class OutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func decodedString() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}

/// Runs a single child process to completion, separating stdout from a
/// drained (never `nullDevice`) stderr pipe so a chatty child can't block on
/// a full stderr buffer, and resuming its continuation exactly once: on a
/// launch failure, on the process actually terminating, or — after a
/// timeout or the awaiting `Task` being cancelled — once the SIGTERM→SIGKILL
/// escalation has actually reaped it. `Process.terminate()`/`kill()` are
/// only ever called after a successful `run()`, since calling them before
/// launch is undefined behavior.
private final class ProcessRunner: @unchecked Sendable {
    /// How long to wait, once the child has terminated (or been SIGKILLed),
    /// for both output pipes to hit EOF before forcing completion anyway. A
    /// grandchild that inherited stdout/stderr (e.g. a leaked background
    /// process) keeps the write end of a pipe open long after the child we
    /// actually launched has exited; without this bound `run()` would wait
    /// on that grandchild indefinitely.
    private static let drainDeadline: TimeInterval = 0.75

    private let process = Process()
    private let stdoutBox = OutputBox()
    private let stderrBox = OutputBox()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let group = DispatchGroup()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Result<String, TitleGenerationFailure>, Never>?
    private var hasLaunched = false
    private var abandoned = false
    private var cancelRequested = false
    private var terminatedEarly = false
    private var reaped = false
    private var drainScheduled = false
    private var stdoutLeft = false
    private var stderrLeft = false
    private var terminationLeft = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var killWorkItem: DispatchWorkItem?
    private var drainWorkItem: DispatchWorkItem?

    private let outputFile: URL?

    init(binaryPath: String, arguments: [String], outputFile: URL?) {
        self.outputFile = outputFile
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        // A neutral cwd keeps the CLIs from picking up a project's
        // CLAUDE.md/AGENTS.md; the PATH lets npm-installed `#!/usr/bin/env node`
        // shims find node from a GUI launch.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        let binaryDirectory = (binaryPath as NSString).deletingLastPathComponent
        environment["PATH"] = [binaryDirectory, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        process.environment = environment
    }

    func run(
        timeout: TimeInterval,
        gracePeriod: TimeInterval,
        onLaunch: (@Sendable (pid_t) -> Void)?
    ) async -> Result<String, TitleGenerationFailure> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, TitleGenerationFailure>, Never>) in
            lock.lock()
            self.continuation = continuation
            let cancelledAtStart = cancelRequested
            lock.unlock()

            if cancelledAtStart {
                resume(.failure(.cancelled))
                return
            }

            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // See GitCLI.run/StreamingProcessRunner: don't resolve until both
            // pipes have hit EOF and the process has terminated, or the
            // final chunk of output can race process exit. Each leave is
            // guarded so a forced drain (see scheduleDrain) and a genuine
            // EOF/termination racing each other can't double-leave the group.
            group.enter()  // stdout EOF
            group.enter()  // stderr EOF
            group.enter()  // termination

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, stdoutBox] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.leaveStdout()
                } else {
                    stdoutBox.append(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, stderrBox] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.leaveStderr()
                } else {
                    stderrBox.append(data)
                }
            }

            process.terminationHandler = { [weak self] _ in
                self?.markReaped()
                self?.leaveTermination()
                self?.scheduleDrain()
            }

            group.notify(queue: .global()) { [weak self] in
                self?.finish()
            }

            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.handleEarlyTermination(gracePeriod: gracePeriod, reason: "timed out")
            }
            lock.lock()
            timeoutWorkItem = timeoutItem
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            // Checked again right before actually spawning: `cancel()` may
            // have run concurrently with the setup above. If so, the
            // process never launches, so none of stdout EOF, stderr EOF or
            // termination will ever leave the group; `abandonUnlaunchedProcess`
            // balances it.
            lock.lock()
            let cancelledBeforeRun = cancelRequested
            lock.unlock()
            guard !cancelledBeforeRun else {
                timeoutItem.cancel()
                abandonUnlaunchedProcess()
                resume(.failure(.cancelled))
                return
            }

            do {
                try process.run()
                lock.lock()
                hasLaunched = true
                let cancelledDuringLaunch = cancelRequested
                lock.unlock()
                onLaunch?(process.processIdentifier)
                if cancelledDuringLaunch {
                    handleEarlyTermination(gracePeriod: gracePeriod, reason: "was cancelled")
                }
            } catch {
                timeoutItem.cancel()
                abandonUnlaunchedProcess()
                resume(.failure(.launchFailed("\(error)")))
            }
        }
    }

    /// Tears down pipes/handlers for a process that was set up but never
    /// actually `run()` (launch failure or cancellation before launch), and
    /// balances the `DispatchGroup`'s three outstanding `enter()`s — none of
    /// stdout EOF, stderr EOF, or termination will ever fire naturally since
    /// the process never started.
    private func abandonUnlaunchedProcess() {
        lock.lock()
        abandoned = true
        lock.unlock()

        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        leaveStdout()
        leaveStderr()
        leaveTermination()
    }

    /// Terminates the child if the awaiting `Task` is cancelled, escalating
    /// the same way a timeout does. Safe to call before the process has
    /// launched (`run()` then completes with `.cancelled` without spawning
    /// anything) or after it has already finished.
    func cancel(gracePeriod: TimeInterval) {
        lock.lock()
        cancelRequested = true
        let launched = hasLaunched
        lock.unlock()
        if launched {
            handleEarlyTermination(gracePeriod: gracePeriod, reason: "was cancelled")
        }
    }

    private func handleEarlyTermination(gracePeriod: TimeInterval, reason: String) {
        lock.lock()
        guard hasLaunched, process.isRunning, !terminatedEarly else {
            lock.unlock()
            return
        }
        terminatedEarly = true
        lock.unlock()

        let pid = process.processIdentifier
        TaskTitleGenerator.logger.error(
            "title generator \(reason, privacy: .public); sending SIGTERM (pid \(pid, privacy: .public))"
        )
        process.terminate()

        let killItem = DispatchWorkItem { [weak self] in
            self?.escalateToKill()
        }
        lock.lock()
        killWorkItem = killItem
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod, execute: killItem)
    }

    private func escalateToKill() {
        lock.lock()
        guard !reaped, process.isRunning else {
            lock.unlock()
            return
        }
        lock.unlock()

        let pid = process.processIdentifier
        TaskTitleGenerator.logger.error(
            "title generator still running after grace period; sending SIGKILL (pid \(pid, privacy: .public))"
        )
        kill(pid, SIGKILL)
        scheduleDrain()
    }

    private func markReaped() {
        lock.lock()
        reaped = true
        lock.unlock()
    }

    /// Starts the drain deadline the first time the child has terminated or
    /// been SIGKILLed. If a grandchild is still holding either pipe open by
    /// the time it fires, `forceDrain` cuts the wait short instead of
    /// blocking on EOF that may never come.
    private func scheduleDrain() {
        lock.lock()
        guard !drainScheduled else {
            lock.unlock()
            return
        }
        drainScheduled = true
        lock.unlock()

        let item = DispatchWorkItem { [weak self] in
            self?.forceDrain()
        }
        lock.lock()
        drainWorkItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainDeadline, execute: item)
    }

    private func forceDrain() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        leaveStdout()
        leaveStderr()
    }

    private func leaveStdout() {
        lock.lock()
        guard !stdoutLeft else {
            lock.unlock()
            return
        }
        stdoutLeft = true
        lock.unlock()
        group.leave()
    }

    private func leaveStderr() {
        lock.lock()
        guard !stderrLeft else {
            lock.unlock()
            return
        }
        stderrLeft = true
        lock.unlock()
        group.leave()
    }

    private func leaveTermination() {
        lock.lock()
        guard !terminationLeft else {
            lock.unlock()
            return
        }
        terminationLeft = true
        lock.unlock()
        group.leave()
    }

    private func finish() {
        lock.lock()
        let isAbandoned = abandoned
        let wasTerminatedEarly = terminatedEarly
        timeoutWorkItem?.cancel()
        killWorkItem?.cancel()
        drainWorkItem?.cancel()
        lock.unlock()

        // The process was never actually run (cancelled before launch, or
        // failed to launch): `abandonUnlaunchedProcess` already tore things
        // down; `run()` resumes with the right failure itself. `terminationReason`/
        // `terminationStatus` are undefined on a `Process` that never ran.
        // Guarding on `abandoned` (set synchronously before `run()` even
        // leaves the group) rather than `hasLaunched` (set only after
        // `process.run()` returns) closes a race: if the child terminates
        // and both pipes hit EOF before `hasLaunched` is flipped, `finish()`
        // must still proceed — by the time `group.notify` fires here, the
        // termination handler has already run, so reading
        // `terminationStatus`/`terminationReason` is safe regardless.
        guard !isAbandoned else { return }

        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        let result: Result<String, TitleGenerationFailure>
        if wasTerminatedEarly {
            result = .failure(.timedOut)
        } else if process.terminationReason == .uncaughtSignal {
            result = .failure(.signaled(signal: process.terminationStatus))
        } else if process.terminationStatus != 0 {
            let stderrTail = String((stderrBox.decodedString() ?? "").suffix(500))
            result = .failure(.nonZeroExit(status: process.terminationStatus, stderrTail: stderrTail))
        } else if let rawOutput = outputFile.map({ try? String(contentsOf: $0, encoding: .utf8) }) ?? stdoutBox.decodedString() {
            if let title = TaskTitleGenerator.cleanTitle(fromRawOutput: rawOutput) {
                result = .success(title)
            } else {
                result = .failure(.rejectedOutput(raw: rawOutput))
            }
        } else {
            result = .failure(.undecodableOutput)
        }

        resume(result)
    }

    private func resume(_ result: Result<String, TitleGenerationFailure>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
