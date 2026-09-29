import Foundation
import Testing

@testable import BSideKit

@Suite("GitCLI+Remote")
struct GitCLIRemoteTests {
    private static func addOriginAndPush(root: URL, repoURL: URL) async throws {
        let remoteURL = root.appendingPathComponent("origin.git")
        _ = try await GitCLI.run(["init", "--bare", remoteURL.path], in: root)
        _ = try await GitCLI.run(["remote", "add", "origin", remoteURL.path], in: repoURL)
        _ = try await GitCLI.run(["push", "-u", "origin", "main"], in: repoURL)
    }

    @Test("push reaches the bare origin and updates ahead/behind")
    func pushUpdatesRemote() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try await Self.addOriginAndPush(root: root, repoURL: repoURL)

        try "second\n".write(to: repoURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "second"], in: repoURL)

        let beforePush = await GitCLI.aheadBehind(at: repoURL)
        #expect(beforePush?.ahead == 1)
        #expect(beforePush?.behind == 0)

        try await GitCLI.push(at: repoURL) { _ in }

        let afterPush = await GitCLI.aheadBehind(at: repoURL)
        #expect(afterPush?.ahead == 0)
        #expect(afterPush?.behind == 0)
    }

    @Test("aheadBehind is nil without an upstream")
    func aheadBehindNilWithoutUpstream() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)

        #expect(await GitCLI.aheadBehind(at: repoURL) == nil)
    }

    @Test("history matches rev-list order and content")
    func historyMatchesRevList() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        for index in 1...3 {
            try "commit \(index)\n".write(
                to: repoURL.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8
            )
            _ = try await GitCLI.run(["add", "."], in: repoURL)
            _ = try await GitCLI.run(["commit", "-m", "commit \(index)"], in: repoURL)
        }

        let expectedSHAs = try await GitCLI.runText(["rev-list", "HEAD"], in: repoURL)
            .split(separator: "\n")
            .map(String.init)

        let entries = try await GitCLI.history(since: nil, limit: 10, at: repoURL)

        #expect(entries.map(\.sha) == expectedSHAs)
        #expect(entries.first?.subject == "commit 3")
        #expect(entries.last?.subject == "init")
    }

    @Test("history respects a baseline")
    func historyRespectsBaseline() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        let baseline = try await GitCLI.revParse("HEAD", at: repoURL)

        for index in 1...2 {
            try "commit \(index)\n".write(
                to: repoURL.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8
            )
            _ = try await GitCLI.run(["add", "."], in: repoURL)
            _ = try await GitCLI.run(["commit", "-m", "commit \(index)"], in: repoURL)
        }

        let entries = try await GitCLI.history(since: baseline, limit: 10, at: repoURL)

        #expect(entries.count == 2)
        #expect(entries.map(\.subject) == ["commit 2", "commit 1"])
        #expect(!entries.contains { $0.subject == "init" })
    }

    @Test("history respects the limit")
    func historyRespectsLimit() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        for index in 1...3 {
            try "commit \(index)\n".write(
                to: repoURL.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8
            )
            _ = try await GitCLI.run(["add", "."], in: repoURL)
            _ = try await GitCLI.run(["commit", "-m", "commit \(index)"], in: repoURL)
        }

        let entries = try await GitCLI.history(since: nil, limit: 2, at: repoURL)

        #expect(entries.count == 2)
        #expect(entries.map(\.subject) == ["commit 3", "commit 2"])
    }

    @Test("showCommit contains the patch")
    func showCommitContainsPatch() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try "added line\n".write(to: repoURL.appendingPathComponent("patched.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "add patched.txt"], in: repoURL)

        let sha = try await GitCLI.revParse("HEAD", at: repoURL)
        let diff = try await GitCLI.showCommit(sha, at: repoURL)

        #expect(!diff.isBinary)
        #expect(!diff.isTruncated)
        #expect(diff.text.contains("add patched.txt"))
        #expect(diff.text.contains("+added line"))
        #expect(diff.text.contains("patched.txt"))
    }

    // A local push finishes near-instantly, so this only checks that cancelling doesn't hang or crash.
    @Test("cancelling a push does not hang")
    func cancellingPushDoesNotHang() async throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let repoURL = try await TestRepo.makeRepo(in: root)
        try await Self.addOriginAndPush(root: root, repoURL: repoURL)

        try "second\n".write(to: repoURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitCLI.run(["add", "."], in: repoURL)
        _ = try await GitCLI.run(["commit", "-m", "second"], in: repoURL)

        let task = Task {
            try await GitCLI.push(at: repoURL) { _ in }
        }
        task.cancel()

        _ = try? await task.value
    }
}
