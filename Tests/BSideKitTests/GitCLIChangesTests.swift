import Foundation
import Testing

@testable import BSideKit

/// Thread-safe accumulator for lines delivered by a `@Sendable` streaming
/// callback from a test's perspective, matching `DataAccumulator` in `GitCLI.swift`.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

@Suite struct GitCLIChangesTests {
    @Test func statusReportsEachChangeKind() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "to-delete\n".write(to: repoURL.appendingPathComponent("to-delete.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "to-delete.txt"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "add to-delete"], in: repoURL)

        try "renamed\n".write(to: repoURL.appendingPathComponent("orig-name.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "orig-name.txt"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "add orig-name"], in: repoURL)

        // Everything below is uncommitted, staged in whatever order it's applied.
        try FileManager.default.removeItem(at: repoURL.appendingPathComponent("to-delete.txt"))
        _ = try await GitCLI.run(["mv", "orig-name.txt", "new-name.txt"], in: repoURL)

        try "modified\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try "added\n".write(to: repoURL.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "added.txt"], in: repoURL)

        try "untracked\n".write(to: repoURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let changes = try await GitCLI.changedFiles(at: repoURL)

        #expect(changes.contains { $0.path == "added.txt" && $0.kind == .added && $0.area == .staged })
        #expect(changes.contains { $0.path == "README.md" && $0.kind == .modified && $0.area == .unstaged })
        #expect(changes.contains { $0.path == "to-delete.txt" && $0.kind == .deleted && $0.area == .unstaged })
        #expect(
            changes.contains {
                $0.path == "new-name.txt" && $0.origPath == "orig-name.txt" && $0.kind == .renamed && $0.area == .staged
            }
        )
        #expect(changes.contains { $0.path == "untracked.txt" && $0.kind == .untracked && $0.area == .unstaged })
    }

    @Test func statusReportsMergeConflict() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "base\n".write(to: repoURL.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "conflict.txt"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "base"], in: repoURL)

        _ = try await GitCLI.run(["checkout", "-b", "feature"], in: repoURL)
        try "feature\n".write(to: repoURL.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["commit", "-am", "feature change"], in: repoURL)

        _ = try await GitCLI.run(["checkout", "main"], in: repoURL)
        try "main\n".write(to: repoURL.appendingPathComponent("conflict.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["commit", "-am", "main change"], in: repoURL)

        _ = try? await GitCLI.run(["merge", "feature"], in: repoURL)

        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == "conflict.txt" && $0.kind == .conflicted })
    }

    @Test func fileCanBeBothStagedAndUnstaged() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let fileURL = repoURL.appendingPathComponent("README.md")
        try "staged change\n".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "README.md"], in: repoURL)
        try "staged change\nunstaged too\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == "README.md" && $0.area == .staged && $0.kind == .modified })
        #expect(changes.contains { $0.path == "README.md" && $0.area == .unstaged && $0.kind == .modified })
        #expect(changes.filter { $0.path == "README.md" }.count == 2)
    }

    @Test func pathsWithSpacesAndUnicode() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let name = "spécial file 名前.txt"
        try "hello\n".write(to: repoURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "--", name], in: repoURL)

        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == name && $0.area == .staged })

        let counts = try await GitCLI.lineCounts(at: repoURL)
        #expect(counts.staged[name]?.added == 1)
        #expect(counts.staged[name]?.removed == 0)
    }

    @Test func stageUnstageDiscardRoundTrip() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        let fileURL = repoURL.appendingPathComponent("README.md")
        try "changed\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try await GitCLI.stage(["README.md"], at: repoURL)
        var changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == "README.md" && $0.area == .staged })

        try await GitCLI.unstage(["README.md"], at: repoURL)
        changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(!changes.contains { $0.path == "README.md" && $0.area == .staged })
        #expect(changes.contains { $0.path == "README.md" && $0.area == .unstaged })

        try await GitCLI.discardTracked(["README.md"], at: repoURL)
        changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(!changes.contains { $0.path == "README.md" })
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content == "hello\n")
    }

    @Test func unstageFallsBackWithoutCommits() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try await GitCLI.initRepository(at: repoURL)
        _ = try await GitCLI.run(["config", "user.email", "test@example.com"], in: repoURL)
        _ = try await GitCLI.run(["config", "user.name", "Test"], in: repoURL)

        try "hi\n".write(to: repoURL.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["f.txt"], at: repoURL)

        try await GitCLI.unstage(["f.txt"], at: repoURL)
        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == "f.txt" && $0.kind == .untracked })
    }

    @Test func addToGitignoreAppendsWithoutDuplicating() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try GitCLI.addToGitignore("build/", at: repoURL)
        try GitCLI.addToGitignore("build/", at: repoURL)
        try GitCLI.addToGitignore("*.log", at: repoURL)

        let content = try String(contentsOf: repoURL.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = content.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0 == "build/" }.count == 1)
        #expect(lines.contains("*.log"))
    }

    @Test func commitStreamsPreCommitHookOutput() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        try writeHook(at: repoURL, script: "#!/bin/sh\necho hook-line-one\necho hook-line-two\nexit 0\n")

        try "change\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)

        let collector = LineCollector()
        try await GitCLI.commit(message: "test commit", at: repoURL) { collector.append($0) }

        #expect(collector.all.contains("hook-line-one"))
        #expect(collector.all.contains("hook-line-two"))

        let log = try await GitCLI.runText(["log", "-1", "--format=%s"], in: repoURL)
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "test commit")
    }

    @Test func failingHookThrows() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        try writeHook(at: repoURL, script: "#!/bin/sh\necho about to fail\nexit 1\n")

        try "change\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)

        await #expect(throws: GitCLI.StreamingCommandError.self) {
            try await GitCLI.commit(message: "test commit", at: repoURL) { _ in }
        }
    }

    @Test func cancelStopsASleepingHook() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        try writeHook(at: repoURL, script: "#!/bin/sh\nsleep 30\n")

        try "change\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)

        let task = Task {
            try await GitCLI.commit(message: "test commit", at: repoURL) { _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        let start = Date()
        var threw = false
        do {
            try await task.value
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func branchChangesIgnoresWorkingTreeDirt() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let base = try await GitCLI.revParse("HEAD", at: repoURL)

        try "committed change\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["commit", "-am", "committed change"], in: repoURL)

        try "dirty worktree edit\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "brand new untracked\n".write(to: repoURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let changes = try await GitCLI.branchChanges(since: base, at: repoURL)
        #expect(changes.count == 1)
        #expect(changes.first?.path == "README.md")
        #expect(changes.first?.kind == .modified)
        #expect(!changes.contains { $0.path == "untracked.txt" })
    }

    private func writeHook(at repoURL: URL, script: String) throws {
        let hookURL = repoURL.appendingPathComponent(".git/hooks/pre-commit")
        try script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }
}
