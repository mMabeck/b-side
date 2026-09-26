import Foundation
import Testing

@testable import BSideKit

/// Covers `GitCLI.workingTreeChanges`/`workingTreeDiff`, the Changes
/// overlay's `.all` and `.uncommitted` modes (`branchChanges`/`branchDiff`,
/// the `.committed` mode, already have coverage in `GitCLIChangesTests`).
@Suite struct GitCLIWorkingTreeChangesTests {
    @Test func uncommittedCombinesStagedAndUnstagedAgainstHead() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        // A second tracked file, committed clean so it can be modified
        // without touching README.md's own history.
        try "second\n".write(to: repoURL.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        try await GitCLI.run(["add", "second.txt"], in: repoURL)
        try await GitCLI.run(["commit", "-m", "add second"], in: repoURL)

        // Staged: a modified tracked file.
        try "staged change\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await GitCLI.stage(["README.md"], at: repoURL)

        // Unstaged: the other tracked file, modified but not staged.
        try "unstaged change\n".write(to: repoURL.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)

        // Untracked file.
        try "brand new\n".write(to: repoURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let changes = try await GitCLI.workingTreeChanges(against: "HEAD", at: repoURL)

        #expect(changes.contains { $0.path == "README.md" && $0.kind == .modified })
        #expect(changes.contains { $0.path == "second.txt" && $0.kind == .modified })
        #expect(changes.contains { $0.path == "untracked.txt" && $0.kind == .untracked })
    }

    @Test func allCombinesCommittedAndUncommittedAgainstBaseline() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)
        let baseline = try await GitCLI.revParse("HEAD", at: repoURL)

        // Committed since baseline.
        try "committed change\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await GitCLI.run(["commit", "-am", "committed change"], in: repoURL)

        // Uncommitted on top of that.
        try "dirty worktree edit\n".write(to: repoURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let changes = try await GitCLI.workingTreeChanges(against: baseline, at: repoURL)

        #expect(changes.contains { $0.path == "README.md" && $0.kind == .modified })
        #expect(changes.contains { $0.path == "untracked.txt" && $0.kind == .untracked })
    }

    @Test func deletedAndRenamedFilesAreReported() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "to delete\n".write(to: repoURL.appendingPathComponent("to-delete.txt"), atomically: true, encoding: .utf8)
        try "renamed\n".write(to: repoURL.appendingPathComponent("orig-name.txt"), atomically: true, encoding: .utf8)
        try await GitCLI.run(["add", "to-delete.txt", "orig-name.txt"], in: repoURL)
        try await GitCLI.run(["commit", "-m", "seed"], in: repoURL)

        try FileManager.default.removeItem(at: repoURL.appendingPathComponent("to-delete.txt"))
        try await GitCLI.run(["mv", "orig-name.txt", "new-name.txt"], in: repoURL)

        let changes = try await GitCLI.workingTreeChanges(against: "HEAD", at: repoURL)

        #expect(changes.contains { $0.path == "to-delete.txt" && $0.kind == .deleted })
        #expect(
            changes.contains {
                $0.path == "new-name.txt" && $0.origPath == "orig-name.txt" && $0.kind == .renamed
            }
        )
    }

    @Test func workingTreeDiffShowsATrackedFilesChange() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "changed content\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let diff = try await GitCLI.workingTreeDiff(for: "README.md", against: "HEAD", at: repoURL)

        #expect(!diff.isBinary)
        #expect(diff.text.contains("+changed content"))
    }

    @Test func untrackedPathsListsOnlyUntrackedFiles() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let repoURL = try await TestRepo.makeRepo(in: root)

        try "modified\n".write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repoURL.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let untracked = try await GitCLI.untrackedPaths(at: repoURL)

        #expect(untracked == ["new.txt"])
    }
}
