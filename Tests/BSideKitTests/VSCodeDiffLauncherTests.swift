import Foundation
import Testing

@testable import BSideKit

struct VSCodeDiffLauncherTests {
    @Test("Resolves `code` from the first PATH directory that has it")
    func resolvesFromPath() {
        let launcher = VSCodeDiffLauncher(
            environment: { ["PATH": "/usr/bin:/opt/homebrew/bin:/usr/local/bin"] },
            fileExists: { $0 == "/opt/homebrew/bin/code" }
        )
        #expect(launcher.resolveCodePath() == "/opt/homebrew/bin/code")
    }

    @Test("Falls back to /usr/local/bin/code when PATH has no match")
    func fallsBackToUsrLocalBin() {
        let launcher = VSCodeDiffLauncher(
            environment: { ["PATH": "/usr/bin"] },
            fileExists: { $0 == "/usr/local/bin/code" }
        )
        #expect(launcher.resolveCodePath() == "/usr/local/bin/code")
    }

    @Test("Falls back to the VS Code app bundle's CLI when nothing else matches")
    func fallsBackToAppBundle() {
        let launcher = VSCodeDiffLauncher(
            environment: { ["PATH": "/usr/bin"] },
            fileExists: { $0 == "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" }
        )
        #expect(launcher.resolveCodePath() == "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    }

    @Test("Returns nil when `code` isn't found anywhere")
    func returnsNilWhenNotFound() {
        let launcher = VSCodeDiffLauncher(environment: { ["PATH": "/usr/bin"] }, fileExists: { _ in false })
        #expect(launcher.resolveCodePath() == nil)
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
}
