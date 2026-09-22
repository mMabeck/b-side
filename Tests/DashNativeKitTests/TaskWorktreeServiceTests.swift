import Foundation
import Testing

@testable import DashNativeKit

@Suite("TaskWorktreeService")
struct TaskWorktreeServiceTests {
    @Test("createWorktree creates a branch named from the task and a worktree checked out on it")
    func createsBranchAndWorktree() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let result = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "Fix the thing",
            baseRef: "main"
        )

        #expect(result.branchName == "task/fix-the-thing")
        #expect(result.branchCreatedByApp == true)
        #expect(result.worktreePath == "\(repoURL.path)-worktrees/fix-the-thing")
        #expect(FileManager.default.fileExists(atPath: result.worktreePath))
        #expect(FileManager.default.fileExists(atPath: "\(result.worktreePath)/README.md"))

        let currentBranch = await GitCLI.currentBranch(at: URL(fileURLWithPath: result.worktreePath))
        #expect(currentBranch == "task/fix-the-thing")
    }

    @Test("createWorktree copies loose ignored files like .env but not ignored directories")
    func copiesIgnoredFilesUsingTheLooseRule() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try "node_modules/\n.env\n".write(
            to: repoURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
        _ = try await GitCLI.run(["add", ".gitignore"], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "gitignore"], in: repoURL)

        let nodeModules = repoURL.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "console.log(1)".write(to: nodeModules.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "SECRET=1\n".write(to: repoURL.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")
        let result = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "Add env support",
            baseRef: "main"
        )

        #expect(result.copiedIgnoredFiles == [".env"])
        #expect(FileManager.default.fileExists(atPath: "\(result.worktreePath)/.env"))
        #expect(FileManager.default.fileExists(atPath: "\(result.worktreePath)/node_modules/pkg/index.js") == false)
    }

    @Test("attaching to a branch already checked out elsewhere is surfaced as a typed error")
    func rejectsAlreadyCheckedOutBranch() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try await GitCLI.createBranch("shared", from: "main", at: repoURL)
        let firstWorktree = root.appendingPathComponent("first-wt")
        _ = try await GitCLI.run(["worktree", "add", firstWorktree.path, "shared"], in: repoURL)

        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        await #expect(throws: TaskWorktreeService.ServiceError.self) {
            try await TaskWorktreeService.createWorktree(
                for: project,
                taskName: "Second task",
                existingBranch: "shared"
            )
        }

        let branches = try await TaskWorktreeService.availableBranches(for: project)
        let shared = branches.first { $0.name == "shared" }
        #expect(shared?.isCheckedOut == true)
        #expect(shared?.checkedOutAt?.hasSuffix("/first-wt") == true)
    }

    @Test("deleteTask runs teardown before removing the worktree directory")
    func teardownRunsBeforeRemoval() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let result = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "Torn down",
            baseRef: "main"
        )

        let markerURL = root.appendingPathComponent("teardown-ran")
        let teardownCommand = "test -d '\(result.worktreePath)' && touch '\(markerURL.path)'"

        try await TaskWorktreeService.deleteTask(
            project: project,
            worktreePath: result.worktreePath,
            branchName: result.branchName,
            deleteLocalBranch: true,
            deleteRemoteBranch: false,
            teardownCommand: teardownCommand
        )

        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(FileManager.default.fileExists(atPath: result.worktreePath) == false)
        #expect(try await GitCLI.branchExists(result.branchName, at: repoURL) == false)
    }

    @Test("pruneAndDetectVanished reports worktrees whose directories disappeared and cleans git metadata")
    func detectsVanishedWorktrees() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let result = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "Vanishes",
            baseRef: "main"
        )

        try FileManager.default.removeItem(atPath: result.worktreePath)

        let vanished = try await TaskWorktreeService.pruneAndDetectVanished(
            project: project,
            worktreePaths: [result.worktreePath]
        )

        #expect(vanished == [result.worktreePath])

        let remaining = try await GitCLI.worktrees(at: repoURL)
        #expect(remaining.count == 1)
        #expect(remaining.first?.branch == "main")
    }

    @Test("syncStatus reports ahead/behind and flips merged once the branch is absorbed")
    func syncStatusReflectsMergeState() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let project = Project(id: 1, path: repoURL.path, displayName: "repo", baseRef: "main")

        let result = try await TaskWorktreeService.createWorktree(
            for: project,
            taskName: "Sync status",
            baseRef: "main"
        )
        let worktreeURL = URL(fileURLWithPath: result.worktreePath)
        try "work\n".write(to: worktreeURL.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: worktreeURL)
        _ = try await GitCLI.run(["commit", "-m", "work"], in: worktreeURL)

        let beforeMerge = try await TaskWorktreeService.syncStatus(project: project, branchName: result.branchName)
        #expect(beforeMerge.ahead == 1)
        #expect(beforeMerge.behind == 0)
        #expect(beforeMerge.merged == false)

        _ = try await GitCLI.run(["merge", "--no-ff", "-m", "merge", result.branchName], in: repoURL)

        let afterMerge = try await TaskWorktreeService.syncStatus(project: project, branchName: result.branchName)
        #expect(afterMerge.merged == true)
    }
}
