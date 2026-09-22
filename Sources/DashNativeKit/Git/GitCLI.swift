import Foundation
import OSLog

/// Minimal, provisional shell-out helper for the few git facts the skeleton needs
/// (remote, current branch, `git init`). This is deliberately small: the real git
/// layer (status parsing, worktrees, diffs) is a later stage and will replace it.
public enum GitCLI {
    private static let logger = Logger(subsystem: "ai.syv.dash-native", category: "git")

    public struct CommandError: Error {
        public let status: Int32
        public let output: String
    }

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
        guard let output = try? await run(["branch", "--show-current"], in: path) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The URL of the `origin` remote, if any.
    public static func originRemote(at path: URL) async -> String? {
        guard let output = try? await run(["remote", "get-url", "origin"], in: path) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""
                let errOutput = String(data: errData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    logger.error(
                        "git \(arguments.joined(separator: " "), privacy: .public) failed: \(errOutput, privacy: .public)"
                    )
                    continuation.resume(
                        throwing: CommandError(status: process.terminationStatus, output: errOutput)
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
}
