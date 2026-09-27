import Foundation
import OSLog

/// Generates a short task title from a user's first pi prompt by running a
/// fine-tuned local title model (llama.cpp's `llama-completion` binary over
/// a small Qwen3 gguf), for `ProjectsStore.applyAutoRename` to prefer over
/// `TaskAutoRenameService.deriveTitle`'s heuristic. Every failure mode —
/// missing binary, missing model file, a slow or crashed process, or output
/// that doesn't look like a title — reports `nil` rather than throwing, so
/// the caller can fall back unconditionally.
public enum TaskTitleGenerator {
    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "task-title-generator")

    /// UserDefaults key overriding the default model path below.
    public static let modelPathDefaultsKey = "settings.titleModel.path"

    private static let defaultModelPath = "~/Claude/title-gen/models/gguf/qwen3-0.6b-title-Q8_0.gguf"

    /// Probed in order: a GUI app's `PATH` typically excludes Homebrew, so
    /// the well-known install prefixes are checked before falling back to
    /// whatever `PATH` the process does have.
    private static let binaryCandidates = [
        "/opt/homebrew/bin/llama-completion",
        "/usr/local/bin/llama-completion",
    ]

    private static let timeout: TimeInterval = 15
    private static let maxTitleWords = 8
    private static let maxTitleLength = 60
    private static let endOfTextMarker = "[end of text]"
    private static let maxQuestionLength = 1000

    /// Runs the title model on the first 1000 characters of `prompt` and
    /// returns a cleaned single-line title, or `nil` if the binary or model
    /// file isn't present, the process times out or fails to launch, or its
    /// output fails validation. Runs off the main actor.
    public static func generate(fromPrompt prompt: String) async -> String? {
        guard let binaryPath = resolveBinaryPath() else {
            logger.notice("title model skipped: llama-completion binary not found")
            return nil
        }
        guard let modelPath = resolveModelPath() else {
            logger.notice("title model skipped: model file not found")
            return nil
        }

        let question = String(prompt.prefix(maxQuestionLength))
        let fullPrompt = """
            <|im_start|>user
            Write a short English title (2-5 words) for the question below. The question may be in Danish; the title is always in English. Reply with the title only.

            Question: \(question)<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """

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

        guard let rawOutput = await runProcess(binaryPath: binaryPath, arguments: arguments, timeout: timeout) else {
            logger.notice("title model skipped: process timed out or failed to launch")
            return nil
        }

        guard let title = cleanTitle(fromRawOutput: rawOutput) else {
            logger.notice("title model skipped: output failed validation")
            return nil
        }

        return title
    }

    // MARK: - Binary/model resolution

    private static func resolveBinaryPath() -> String? {
        for candidate in binaryCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/llama-completion"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func resolveModelPath() -> String? {
        let configured = UserDefaults.standard.string(forKey: modelPathDefaultsKey)
        let expanded = ((configured ?? defaultModelPath) as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return expanded
    }

    // MARK: - Output cleanup/validation

    /// Cleans `llama-completion`'s stdout into a single-line title, or
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

    /// Runs `binaryPath` with `arguments` (no shell), discarding stderr and
    /// collecting stdout, and terminates the process if it hasn't exited
    /// within `timeout`. Waits for both stdout EOF and process termination
    /// before resolving, the same way `GitCLI`/`StreamingProcessRunner` do,
    /// so the final chunk of output can't race process exit. Returns `nil`
    /// on timeout or a launch failure rather than throwing, since every
    /// caller here treats "no title" the same way regardless of cause.
    private static func runProcess(binaryPath: String, arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = arguments
            process.standardError = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe

            let outputBox = OutputBox()

            let group = DispatchGroup()
            group.enter()  // pipe EOF
            group.enter()  // termination

            let resumeBox = ResumeBox(continuation: continuation)

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    outputBox.append(data)
                }
            }

            process.terminationHandler = { _ in
                group.leave()
            }

            group.notify(queue: .global()) {
                resumeBox.resume(with: outputBox.decodedString())
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
                resumeBox.resume(with: nil)
            }

            do {
                try process.run()
            } catch {
                resumeBox.resume(with: nil)
            }
        }
    }
}

/// Accumulates a title-model process's stdout bytes across reads on a
/// background dispatch source, mirroring `LineBuffer`'s lock pattern since
/// closures crossing into `Process`'s callback queues aren't `Sendable`
/// under Swift 6 strict concurrency.
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

/// Resumes `runProcess`'s continuation exactly once, whichever of the
/// normal-completion path or the timeout path gets there first.
private final class ResumeBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<String?, Never>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
