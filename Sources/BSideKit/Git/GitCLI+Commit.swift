import Foundation
import OSLog

extension GitCLI {
    private static let commitLogger = Logger(subsystem: "dev.mabeck.bside", category: "git-commit")

    /// Thrown when a streamed git invocation exits non-zero. All output was
    /// already delivered to `onOutput` before this is thrown.
    public struct StreamingCommandError: Error, Sendable, CustomStringConvertible {
        public let arguments: [String]
        public let status: Int32

        public var description: String {
            "git \(arguments.joined(separator: " ")) failed (\(status))"
        }
    }

    /// Commits staged changes with `message`, streaming combined stdout/stderr
    /// from `git commit` (including pre-commit hook output) to `onOutput` line by
    /// line as it arrives. The message is passed via `-F` and a temp file rather
    /// than `-m`, so it survives arbitrary content without shell quoting.
    ///
    /// Cancelling the enclosing `Task` interrupts the underlying process; see
    /// `runStreaming`.
    public static func commit(
        message: String,
        at path: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let messageFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-commit-\(UUID().uuidString).txt")
        try message.write(to: messageFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: messageFile) }

        try await runStreaming(
            args: ["commit", "-F", messageFile.path],
            at: path,
            env: ["GIT_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0"],
            onOutput: onOutput
        )
    }

    /// Runs a git subcommand and streams its combined stdout+stderr line by line,
    /// without blocking the caller. Distinct from `run`, which is for
    /// machine-readable output collected in full: this is for commands whose
    /// output (hook logs, progress) needs to reach the UI as it happens.
    ///
    /// Generic over arguments and environment so other long-running, user-visible
    /// git operations (e.g. a future `push -u origin HEAD`) can reuse it.
    ///
    /// Cancelling the enclosing `Task` sends `SIGINT` via `process.interrupt()`,
    /// then `SIGTERM` via `process.terminate()` if the process is still running
    /// shortly after.
    static func runStreaming(
        args: [String],
        at directory: URL,
        env: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        if !env.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env {
                environment[key] = value
            }
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lineBuffer = LineBuffer(onLine: onOutput)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // See GitCLI.run: don't resume until both the pipe has hit EOF
                // and the process has terminated, or the final chunk can race
                // process exit and truncate output.
                let group = DispatchGroup()
                group.enter()  // pipe EOF
                group.enter()  // termination

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        lineBuffer.flush()
                        group.leave()
                    } else {
                        lineBuffer.append(data)
                    }
                }

                process.terminationHandler = { _ in
                    group.leave()
                }

                group.notify(queue: .global()) {
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        commitLogger.error(
                            "git \(args.joined(separator: " "), privacy: .public) failed: \(process.terminationStatus)"
                        )
                        continuation.resume(throwing: StreamingCommandError(arguments: args, status: process.terminationStatus))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
