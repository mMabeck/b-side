import Foundation
import Testing

@testable import BSideKit

/// Exercises `ProjectsStore`'s address hand-off file for the Pi-side
/// spawner: `startSubagentServer()` writes it once the server is listening,
/// `stop()` removes it. Isolated to a temp directory rather than the real
/// `~/Library/Application Support/B-Side`.
@MainActor
@Suite("Subagent endpoint file")
struct SubagentEndpointFileTests {
    @Test("standard location is B-Side/subagent-endpoint under Application Support")
    func standardLocation() throws {
        let url = try #require(ProjectsStore.subagentEndpointFileURL())
        #expect(url.lastPathComponent == "subagent-endpoint")
        #expect(url.deletingLastPathComponent().lastPathComponent == "B-Side")
    }

    @Test("writes the address with no trailing newline, and remove deletes it")
    func writeThenRemove() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }
        let fileURL = root.appendingPathComponent("B-Side/subagent-endpoint")

        ProjectsStore.writeSubagentEndpointFile(address: "127.0.0.1:54321", to: fileURL)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents == "127.0.0.1:54321")

        ProjectsStore.removeSubagentEndpointFile(at: fileURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
