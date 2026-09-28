import Foundation
import Testing

@testable import BSideKit

struct VSCodeDiffLauncherTests {
    @Test(
        "Resolves `code` from PATH, then known fallback install locations, else nil",
        arguments: [
            ("/opt/homebrew/bin/code", "/opt/homebrew/bin/code"),
            ("/usr/local/bin/code", "/usr/local/bin/code"),
            ("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            ("nonexistent", nil),
        ] as [(String, String?)]
    )
    func resolvesCodePath(existingPath: String, expected: String?) {
        let launcher = VSCodeDiffLauncher(
            environment: { ["PATH": "/usr/bin:/opt/homebrew/bin:/usr/local/bin"] },
            fileExists: { $0 == existingPath }
        )
        #expect(launcher.resolveCodePath() == expected)
    }

    @Test("Writes base/current temp files named after the original file, empty for a nil side")
    func writesDiffTempFiles() throws {
        let launcher = VSCodeDiffLauncher()
        let tempRoot = FileManager.default.temporaryDirectory
        let before = Set(
            (try? FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
        )

        // "/usr/bin/true" exits immediately without touching the file arguments, so this
        // exercises real file writing without depending on a `code` install being present.
        try launcher.openDiff(fileName: "Example.swift", baseContent: nil, currentContent: Data("hello".utf8), codePath: "/usr/bin/true")

        let after = try FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
        let created = after.first { !before.contains($0.lastPathComponent) && $0.lastPathComponent.hasPrefix("bside-vscode-diff-") }
        let dir = try #require(created)
        defer { try? FileManager.default.removeItem(at: dir) }

        let baseURL = dir.appendingPathComponent("base/Example.swift")
        let currentURL = dir.appendingPathComponent("current/Example.swift")
        #expect(try Data(contentsOf: baseURL).isEmpty)
        #expect(try Data(contentsOf: currentURL) == Data("hello".utf8))
    }

    @Test(
        "Current side reads HEAD in Committed mode, the worktree file otherwise, none when deleted",
        arguments: [
            (ChangesOverlayStore.Mode.all, GitCLI.FileChange.Kind.modified, VSCodeDiffLauncher.CurrentSideSource.worktreeFile),
            (.uncommitted, .modified, .worktreeFile),
            (.committed, .modified, .gitRef("HEAD")),
            (.all, .deleted, .none),
            (.uncommitted, .deleted, .none),
            (.committed, .deleted, .none),
        ] as [(ChangesOverlayStore.Mode, GitCLI.FileChange.Kind, VSCodeDiffLauncher.CurrentSideSource)]
    )
    func currentSideSource(mode: ChangesOverlayStore.Mode, kind: GitCLI.FileChange.Kind, expected: VSCodeDiffLauncher.CurrentSideSource) {
        #expect(VSCodeDiffLauncher.currentSideSource(mode: mode, kind: kind) == expected)
    }
}
