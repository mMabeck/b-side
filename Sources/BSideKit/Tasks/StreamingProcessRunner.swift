import Foundation
import OSLog

/// Runs an arbitrary shell command (setup/teardown, dependency installs) and
/// streams its combined stdout+stderr line by line, without blocking the caller's
/// actor. Distinct from `GitCLI.run`, which is for git subcommands with
/// machine-readable output — this is for opaque project commands whose only
/// useful output is "show it to the user".
enum StreamingProcessRunner {
    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "process")

    /// Thrown when the command exits non-zero. All output was already delivered to
    /// `onOutput` before this is thrown.
    struct NonZeroExit: Error, Sendable {
        let command: String
        let status: Int32
    }

    /// Runs `command` through `/bin/zsh -lc` in `directory`, invoking `onOutput` for
    /// each line of combined output as it arrives.
    static func run(
        command: String,
        in directory: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = directory

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let lineBuffer = LineBuffer(onLine: onOutput)

            // See GitCLI.run: don't resume until both the pipe has hit EOF and the
            // process has terminated, or the final chunk can race process exit.
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
                    logger.error(
                        "command failed (\(process.terminationStatus)): \(command, privacy: .public)"
                    )
                    continuation.resume(throwing: NonZeroExit(command: command, status: process.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Accumulates raw bytes and emits complete lines as they appear, buffering a
/// trailing partial line across reads. Not thread-safe on its own — callers must
/// serialize access, which `readabilityHandler`'s single dispatch source already does.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            pending.removeSubrange(pending.startIndex...newlineIndex)
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    func flush() {
        lock.lock()
        let remaining = pending
        pending.removeAll()
        lock.unlock()
        if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8), !line.isEmpty {
            onLine(line)
        }
    }
}
