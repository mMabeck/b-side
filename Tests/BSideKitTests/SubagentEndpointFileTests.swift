import Foundation
import Testing

@testable import BSideKit

@MainActor
@Suite("Subagent endpoint file")
struct SubagentEndpointFileTests {
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
