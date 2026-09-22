import Foundation
import OSLog

/// Typed async interface over the `git` CLI.
///
/// Shells out to `git` rather than linking libgit2 — see the "Git implementation"
/// section of the native rewrite plan. Every subcommand that has a porcelain or
/// `-z`-delimited format uses it instead of parsing human-readable output.
public enum GitCLI {
    static let logger = Logger(subsystem: "ai.syv.bside", category: "git")

    /// A failed `git` invocation: exit status and stderr, plus the arguments that
    /// produced it, so callers and logs can tell commands apart.
    public struct CommandError: Error, Sendable, CustomStringConvertible {
        public let arguments: [String]
        public let status: Int32
        public let stderr: String

        public var description: String {
            "git \(arguments.joined(separator: " ")) failed (\(status)): \(stderr)"
        }
    }

    // MARK: - Repository basics

    /// Whether `path` is inside a git working tree.
    public static func isGitRepository(at path: URL) async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"], in: path)) != nil
    }

    /// Runs `git init` in `path`.
    public static func initRepository(at path: URL) async throws {
        _ = try await run(["init"], in: path)
    }

    /// The current branch name, or `nil` if detached or unavailable.
    public static func currentBranch(at path: URL) async -> String? {
        guard let output = try? await runText(["branch", "--show-current"], in: path) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The URL of the `origin` remote, if any.
    public static func originRemote(at path: URL) async -> String? {
        guard let output = try? await runText(["remote", "get-url", "origin"], in: path) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Process execution

    /// Runs a git subcommand and returns its raw stdout, throwing `CommandError` on
    /// a non-zero exit status. Never blocks the calling actor: the process is read
    /// via readability handlers on a background queue and the continuation resumes
    /// from the termination handler.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutAccumulator = DataAccumulator()
            let stderrAccumulator = DataAccumulator()

            // Termination can fire before a pipe's final readability callback has
            // delivered its last chunk, which would otherwise race a read against
            // process exit and truncate output. Only resume once the process has
            // terminated *and* both pipes have reached EOF.
            let group = DispatchGroup()
            group.enter()  // stdout EOF
            group.enter()  // stderr EOF
            group.enter()  // termination

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    stdoutAccumulator.append(data)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    stderrAccumulator.append(data)
                }
            }

            process.terminationHandler = { _ in
                group.leave()
            }

            group.notify(queue: .global()) {
                let outData = stdoutAccumulator.data
                let errData = stderrAccumulator.data
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    logger.error(
                        "git \(arguments.joined(separator: " "), privacy: .public) failed: \(errText, privacy: .public)"
                    )
                    continuation.resume(
                        throwing: CommandError(arguments: arguments, status: process.terminationStatus, stderr: errText)
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a git subcommand and decodes stdout as UTF-8 text.
    @discardableResult
    static func runText(_ arguments: [String], in directory: URL) async throws -> String {
        let data = try await run(arguments, in: directory)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Splits a NUL-delimited (`-z`) git output into non-empty components.
    static func splitNulDelimited(_ data: Data) -> [String] {
        data.split(separator: 0)
            .compactMap { String(data: Data($0), encoding: .utf8) }
    }
}

/// Thread-safe byte buffer for accumulating pipe reads from a `readabilityHandler`,
/// which fires on an arbitrary background queue.
final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
