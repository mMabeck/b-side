import Foundation
import Testing

@testable import BSideKit

@Suite("TaskTitleGenerator output cleanup/validation")
struct TaskTitleGeneratorCleanupTests {
    @Test("strips the [end of text] marker and trailing blank lines")
    func stripsEndOfTextMarker() {
        let raw = "Fix login bug [end of text]\n\n\n"
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == "Fix login bug")
    }

    @Test("strips surrounding quotes")
    func stripsSurroundingQuotes() {
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "\"Fix login bug\" [end of text]") == "Fix login bug")
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "'Fix login bug'") == "Fix login bug")
    }

    @Test("strips trailing punctuation")
    func stripsTrailingPunctuation() {
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "Fix login bug.") == "Fix login bug")
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "Fix login bug!") == "Fix login bug")
    }

    @Test("takes only the first non-empty line of multiline output")
    func takesFirstNonEmptyLine() {
        let raw = "\nFix login bug\nSome extra rambling second line\n[end of text]"
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == "Fix login bug")
    }

    @Test("rejects output with more than the allowed word count")
    func rejectsOverlongWordCount() {
        let raw = "This is a way way way way too long generated title for a task"
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == nil)
    }

    @Test("rejects output over the allowed character length")
    func rejectsOverlongCharacterLength() {
        let raw = String(repeating: "a", count: 61)
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == nil)
    }

    @Test("rejects output that is empty or all punctuation")
    func rejectsEmptyOutput() {
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "") == nil)
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "   \n\n") == nil)
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "\"\"") == nil)
    }
}

@Suite("TaskTitleGenerator against the real model", .enabled(if: TaskTitleGeneratorRealModelAvailability.isAvailable))
struct TaskTitleGeneratorRealModelTests {
    @Test("generates a short usable title from a real prompt")
    func generatesATitleFromARealPrompt() async throws {
        let title = await TaskTitleGenerator.generate(fromPrompt: "the login page throws a 500 error, please fix it")
        let unwrapped = try #require(title)
        #expect(!unwrapped.isEmpty)
        #expect(unwrapped.split(separator: " ").count <= 8)
    }
}

/// Whether the real title-gen binary and model file this task's tests were
/// written against are installed on the machine running the suite \u2014 gates
/// `TaskTitleGeneratorRealModelTests` so CI machines without them just skip
/// it instead of failing.
enum TaskTitleGeneratorRealModelAvailability {
    static var isAvailable: Bool {
        let binaryCandidates = ["/opt/homebrew/bin/llama-completion", "/usr/local/bin/llama-completion"]
        guard binaryCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let modelPath = ("~/Claude/title-gen/models/gguf/qwen3-0.6b-title-Q8_0.gguf" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: modelPath)
    }
}

/// Exercises `TaskTitleGenerator.generateResult`'s process-handling with
/// fake `#!/bin/sh` scripts standing in for `llama-completion`, so these run
/// on any machine regardless of whether the real model is installed.
@Suite("TaskTitleGenerator process handling")
struct TaskTitleGeneratorProcessTests {
    private static let fakeModelPath = "/dev/null"

    private func makeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-gen-fake-\(UUID().uuidString)")
        let script = "#!/bin/sh\n" + body + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("returns the cleaned title on success")
    func success() async throws {
        let script = try makeScript(#"echo "Fix Login Bug [end of text]""#)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: Self.fakeModelPath,
            timeout: 5,
            gracePeriod: 1
        )

        switch result {
        case .success(let title):
            #expect(title == "Fix Login Bug")
        case .failure(let failure):
            Issue.record("expected success, got \(failure)")
        }
    }

    @Test("non-zero exit is reported as a failure, not the partial title")
    func nonZeroExit() async throws {
        let script = try makeScript(
            """
            echo "Partial Title"
            echo "boom: something went wrong" >&2
            exit 3
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: Self.fakeModelPath,
            timeout: 5,
            gracePeriod: 1
        )

        switch result {
        case .success(let title):
            Issue.record("expected failure, got title \(title)")
        case .failure(let failure):
            guard case .nonZeroExit(let status, let stderrTail) = failure else {
                Issue.record("expected nonZeroExit, got \(failure)")
                return
            }
            #expect(status == 3)
            #expect(stderrTail.contains("boom"))
        }
    }

    @Test("a crash by signal is reported as a failure")
    func crashBySignal() async throws {
        let script = try makeScript("kill -SEGV $$")
        defer { try? FileManager.default.removeItem(at: script) }

        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: Self.fakeModelPath,
            timeout: 5,
            gracePeriod: 1
        )

        switch result {
        case .success(let title):
            Issue.record("expected failure, got title \(title)")
        case .failure:
            break
        }
    }

    @Test("a launch failure (non-executable path) fails immediately without hanging")
    func launchFailure() async throws {
        let nonExecutable = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-gen-not-executable-\(UUID().uuidString)")
        try "not a script".write(to: nonExecutable, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: nonExecutable) }

        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: nonExecutable.path,
            modelPath: Self.fakeModelPath,
            timeout: 5,
            gracePeriod: 1
        )

        switch result {
        case .success(let title):
            Issue.record("expected failure, got title \(title)")
        case .failure(let failure):
            guard case .launchFailed = failure else {
                Issue.record("expected launchFailed, got \(failure)")
                return
            }
        }
    }

    @Test("binaryNotFound is reported when no binary path is resolved")
    func binaryNotFound() async {
        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: nil,
            modelPath: Self.fakeModelPath,
            timeout: 5,
            gracePeriod: 1
        )
        guard case .failure(.binaryNotFound) = result else {
            Issue.record("expected binaryNotFound, got \(result)")
            return
        }
    }

    @Test("modelNotFound is reported when no model path is resolved")
    func modelNotFound() async throws {
        let script = try makeScript(#"echo "Fix Login Bug [end of text]""#)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: nil,
            timeout: 5,
            gracePeriod: 1
        )
        guard case .failure(.modelNotFound) = result else {
            Issue.record("expected modelNotFound, got \(result)")
            return
        }
    }

    @Test("a timed-out child is killed and reaped, and reported as timedOut")
    func timeout() async throws {
        let script = try makeScript("trap '' TERM\nsleep 30")
        defer { try? FileManager.default.removeItem(at: script) }

        let pidBox = PidBox()
        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: Self.fakeModelPath,
            timeout: 0.5,
            gracePeriod: 0.5,
            onLaunch: { pid in pidBox.set(pid) }
        )

        guard case .failure(.timedOut) = result else {
            Issue.record("expected timedOut, got \(result)")
            return
        }

        let pid = try #require(pidBox.get())
        #expect(kill(pid, 0) != 0, "child process should have been reaped after timeout")
    }

    @Test("cancelling the awaiting task kills the child")
    func cancellation() async throws {
        let script = try makeScript("trap '' TERM\nsleep 30")
        defer { try? FileManager.default.removeItem(at: script) }

        let pidBox = PidBox()
        let launched = LaunchedSignal()

        let task = Task {
            await TaskTitleGenerator.generateResult(
                fromPrompt: "prompt",
                binaryPath: script.path,
                modelPath: Self.fakeModelPath,
                timeout: 30,
                gracePeriod: 0.5,
                onLaunch: { pid in
                    pidBox.set(pid)
                    launched.signal()
                }
            )
        }

        await launched.wait()
        task.cancel()
        _ = await task.value

        let pid = try #require(pidBox.get())
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(kill(pid, 0) != 0, "child process should have been killed after cancellation")
    }
}

/// Thread-safe box for a child pid captured from an `onLaunch` hook, which
/// fires on a background dispatch queue.
private final class PidBox: @unchecked Sendable {
    private var pid: pid_t?
    private let lock = NSLock()

    func set(_ value: pid_t) {
        lock.lock()
        pid = value
        lock.unlock()
    }

    func get() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }
}

/// Signals once, from a background dispatch queue, that a value is ready —
/// used here so the cancellation test waits for the child to actually be
/// launched before cancelling it.
private final class LaunchedSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }
}
