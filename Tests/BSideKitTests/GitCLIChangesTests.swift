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

    @Test func discardWorktreeLeavesTheIndexAlone() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let fileURL = repoURL.appendingPathComponent("README.md")

        try "staged\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)
        try "staged\nunstaged too\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try await GitCLI.discardWorktree(["README.md"], at: repoURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content == "staged\n")
        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == "README.md" && $0.area == .staged && $0.kind == .modified })
        #expect(!changes.contains { $0.path == "README.md" && $0.area == .unstaged })
    }

    // A staged-new file has no `HEAD` entry. `restore --source=HEAD` on such a
    // path deletes it outright rather than reverting it; regression for the
    // bug this guards against, at the level `discardTracked` itself can be
    // tested (`SourceControlStoreTests` covers the store-level fallback that
    // avoids ever calling it this way).
    @Test func discardTrackedDeletesAPathWithNoHeadEntry() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "brand new\n".write(to: repoURL.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["new.txt"], at: repoURL)

        try await GitCLI.discardTracked(["new.txt"], at: repoURL)

        #expect(!FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("new.txt").path))
        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(!changes.contains { $0.path == "new.txt" })
    }

    // Discarding only a rename's new name via `restore --source=HEAD` (or
    // `restore --staged`) leaves the old name's deletion staged (`D old`);
    // both the new and the old path must be passed together.
    @Test func discardTrackedOnBothRenamePathsFullyRevertsTheRename() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "content\n".write(to: repoURL.appendingPathComponent("orig.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "orig.txt"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "add orig"], in: repoURL)
        _ = try await GitCLI.run(["mv", "orig.txt", "new.txt"], in: repoURL)

        try await GitCLI.discardTracked(["orig.txt"], at: repoURL)
        try await GitCLI.unstage(["new.txt"], at: repoURL)

        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(!changes.contains { $0.path == "orig.txt" })
        #expect(changes.contains { $0.path == "new.txt" && $0.kind == .untracked })
        #expect(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("orig.txt").path))
        #expect(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("new.txt").path))
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
        try GitCLI.addToGitignore("file.log", at: repoURL)

        let content = try String(contentsOf: repoURL.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = content.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0 == "/build/" }.count == 1)
        #expect(lines.contains("/file.log"))
    }

    @Test func addToGitignoreAnchorsAndEscapesSpecialPaths() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "unrelated\n".write(to: repoURL.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
        try "star\n".write(to: repoURL.appendingPathComponent("star*name.txt"), atomically: true, encoding: .utf8)
        try "bang\n".write(to: repoURL.appendingPathComponent("!important.txt"), atomically: true, encoding: .utf8)
        try "trailing\n".write(to: repoURL.appendingPathComponent("trailing "), atomically: true, encoding: .utf8)

        try GitCLI.addToGitignore("star*name.txt", at: repoURL)
        try GitCLI.addToGitignore("!important.txt", at: repoURL)
        try GitCLI.addToGitignore("trailing ", at: repoURL)
        try "slash\n".write(to: repoURL.appendingPathComponent("slash\\ "), atomically: true, encoding: .utf8)
        try GitCLI.addToGitignore("slash\\ ", at: repoURL)

        let content = try String(contentsOf: repoURL.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.contains(#"/star\*name.txt"#))
        #expect(lines.contains(#"/\!important.txt"#))
        #expect(lines.contains(#"/trailing\ "#))

        let changes = try await GitCLI.changedFiles(at: repoURL)
        #expect(changes.contains { $0.path == "unrelated.txt" })
        #expect(!changes.contains { $0.path == "star*name.txt" })
        #expect(!changes.contains { $0.path == "!important.txt" })
        #expect(!changes.contains { $0.path == "trailing " })
        #expect(lines.contains(#"/slash\\\ "#))
        #expect(!changes.contains { $0.path == #"slash\ "# })
    }

    @Test func diffTextCapsBeforeDetectingBinary() {
        let binary = Data("diff --git a/x b/x\nBinary files a/x and b/x differ\n".utf8)
        #expect(GitCLI.makeDiffText(from: binary).isBinary)

        // A marker past the cap is never scanned, and a multi-byte character
        // split by the cap doesn't stop detection within it.
        let filler = String(repeating: "+æ\n", count: GitCLI.diffSizeLimit)
        let huge = GitCLI.makeDiffText(from: Data((filler + "Binary files a/y and b/y differ\n").utf8))
        #expect(!huge.isBinary)
        #expect(huge.isTruncated)

        var split = Data("Binary files a/z and b/z differ\n".utf8)
        split.append(Data(String(repeating: "æ", count: GitCLI.diffSizeLimit).utf8))
        #expect(GitCLI.makeDiffText(from: split).isBinary)
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

    @Test func binaryDetectionMatchesOnlyTheWholeMarkerLine() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        // The literal phrase appears inside tracked *text* content, not as
        // git's own binary-file marker line — must not be misread as binary.
        try "Binary files can differ from text files.\nsecond line\n".write(
            to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )

        let diff = try await GitCLI.diff(for: "README.md", staged: false, at: repoURL)
        #expect(!diff.isBinary)
        #expect(diff.text.contains("Binary files can differ from text files."))
    }

    @Test func showCommitNeverMarksAMixedCommitWhollyBinary() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try Data([0x00, 0x01, 0x02, 0xff]).write(to: repoURL.appendingPathComponent("image.bin"))
        try "text change\n".write(to: repoURL.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "-A"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "mixed binary and text"], in: repoURL)

        let sha = try await GitCLI.revParse("HEAD", at: repoURL)
        let diff = try await GitCLI.showCommit(sha, at: repoURL)

        #expect(!diff.isBinary)
        #expect(diff.text.contains("text.txt"))
        #expect(diff.text.contains("+text change"))
        #expect(diff.text.contains("Binary files"))
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
