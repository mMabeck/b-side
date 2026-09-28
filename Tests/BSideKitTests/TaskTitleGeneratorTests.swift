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
        let modelPath = ("~/Claude/title-gen/models/gguf/qwen3.5-0.8b-title-Q8_0.gguf" as NSString).expandingTildeInPath
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
        case .failure(let failure):
            guard case .signaled = failure else {
                Issue.record("expected signaled, got \(failure)")
                return
            }
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
        let script = try makeScript("trap '' TERM\nexec sleep 30")
        defer { try? FileManager.default.removeItem(at: script) }

        let pidBox = PidBox()
        let start = Date()
        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: Self.fakeModelPath,
            timeout: 0.5,
            gracePeriod: 0.5,
            onLaunch: { pid in pidBox.set(pid) }
        )
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(.timedOut) = result else {
            Issue.record("expected timedOut, got \(result)")
            return
        }
        #expect(elapsed < 3, "expected the call to return quickly, took \(elapsed)s")

        let pid = try #require(pidBox.get())
        #expect(kill(pid, 0) != 0, "child process should have been reaped after timeout")
    }

    @Test("cancelling the awaiting task kills the child")
    func cancellation() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-gen-marker-\(UUID().uuidString)")
        let script = try makeScript(
            """
            trap '' TERM
            touch "\(marker.path)"
            exec sleep 30
            """
        )
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: marker)
        }

        let pidBox = PidBox()
        let launched = LaunchedSignal()

        let start = Date()
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
        try await waitForFile(at: marker)
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(.timedOut) = result else {
            Issue.record("expected timedOut, got \(result)")
            return
        }
        #expect(elapsed < 3, "expected the call to return quickly, took \(elapsed)s")

        let pid = try #require(pidBox.get())
        #expect(kill(pid, 0) != 0, "child process should have been killed after cancellation")
    }

    @Test("cancelling before the task starts never launches a process")
    func cancellationBeforeLaunch() async throws {
        let script = try makeScript(#"echo "Fix Login Bug [end of text]""#)
        defer { try? FileManager.default.removeItem(at: script) }

        let launchedBox = PidBox()
        // A task added to an already-cancelled group starts cancelled, so
        // `withTaskCancellationHandler` inside `generateResult` invokes its
        // `onCancel` before `run()`'s operation closure ever begins —
        // unlike `Task.cancel()` called after creation, which races the
        // task actually starting.
        let result: Result<String, TitleGenerationFailure> = await withTaskGroup(
            of: Result<String, TitleGenerationFailure>.self
        ) { group in
            group.cancelAll()
            group.addTask {
                await TaskTitleGenerator.generateResult(
                    fromPrompt: "prompt",
                    binaryPath: script.path,
                    modelPath: Self.fakeModelPath,
                    timeout: 5,
                    gracePeriod: 1,
                    onLaunch: { pid in launchedBox.set(pid) }
                )
            }
            return await group.next() ?? .failure(.launchFailed("no result"))
        }

        guard case .failure(.cancelled) = result else {
            Issue.record("expected cancelled, got \(result)")
            return
        }
        #expect(launchedBox.get() == nil, "process should not have been spawned")
    }

    @Test("a grandchild holding the pipes open doesn't block completion")
    func grandchildHoldsPipesOpen() async throws {
        let childPidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-gen-grandchild-pid-\(UUID().uuidString)")
        let script = try makeScript(
            """
            (trap '' TERM; exec sleep 30) &
            echo $! > "\(childPidFile.path)"
            trap '' TERM
            wait
            """
        )
        defer {
            try? FileManager.default.removeItem(at: script)
            // The leaked grandchild is reparented and outside the runner's
            // reach (it only signals the process it launched); clean it up
            // here so the suite doesn't leave it running. Runs even if a
            // `guard`/`#require` above exits the test early.
            if let pidText = try? String(contentsOf: childPidFile, encoding: .utf8),
                let grandchildPid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                kill(grandchildPid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: childPidFile)
        }

        let pidBox = PidBox()
        let start = Date()
        let result = await TaskTitleGenerator.generateResult(
            fromPrompt: "prompt",
            binaryPath: script.path,
            modelPath: Self.fakeModelPath,
            timeout: 0.5,
            gracePeriod: 0.5,
            onLaunch: { pid in pidBox.set(pid) }
        )
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(.timedOut) = result else {
            Issue.record("expected timedOut, got \(result)")
            return
        }
        // timeout + gracePeriod + the runner's internal drain deadline + slack.
        #expect(elapsed < 4, "expected the drain deadline to bound completion, took \(elapsed)s")

        let pid = try #require(pidBox.get())
        #expect(kill(pid, 0) != 0, "parent shell should have been killed")
    }
}

/// Polls for `url` to exist, used to confirm a fake script has installed its
/// signal trap before the test acts on the process it launched.
private func waitForFile(at url: URL, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path) {
        if Date() >= deadline {
            Issue.record("timed out waiting for \(url.path) to appear")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
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
