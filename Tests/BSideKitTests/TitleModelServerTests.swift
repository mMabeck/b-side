import Darwin
import Foundation
import Testing

@testable import BSideKit

@Suite("TitleModelServer response parsing and port selection")
struct TitleModelServerUnitTests {
    @Test("parses content from a completion response")
    func parsesContent() {
        let json = Data(#"{"content": "Fix login bug", "stop": true}"#.utf8)
        #expect(TitleModelServer.parseCompletionContent(fromResponseData: json) == "Fix login bug")
    }

    @Test("returns nil when the response has no content field")
    func rejectsMissingContent() {
        let json = Data(#"{"stop": true}"#.utf8)
        #expect(TitleModelServer.parseCompletionContent(fromResponseData: json) == nil)
    }

    @Test("returns nil for non-JSON data")
    func rejectsNonJSON() {
        #expect(TitleModelServer.parseCompletionContent(fromResponseData: Data("not json".utf8)) == nil)
    }

    @Test("picks a nonzero free port")
    func picksNonzeroPort() throws {
        let port = try #require(TitleModelServer.pickAvailablePort())
        #expect(port != 0)
    }
}

@Suite(
    "TitleModelServer against a real resident server",
    .enabled(if: TitleModelServerRealServerAvailability.isAvailable)
)
struct TitleModelServerRealServerTests {
    @Test("prewarms, generates a title over HTTP, and shuts down cleanly")
    func prewarmGenerateShutdown() async throws {
        await TitleModelServer.shared.prewarm()

        let start = Date()
        let title = await TitleModelServer.shared.generate(
            prompt: "Write a short English title (2-5 words) for: the login page throws a 500 error, please fix it"
        )
        let elapsed = Date().timeIntervalSince(start)
        print("TitleModelServer warm generate latency: \(elapsed)s")

        let unwrapped = try #require(title)
        #expect(!unwrapped.isEmpty)

        let pid = await TitleModelServer.shared.debugProcessIdentifier
        let unwrappedPid = try #require(pid)

        await TitleModelServer.shared.shutdown()

        #expect(kill(unwrappedPid, 0) != 0, "server process should have exited after shutdown()")
        let stillTracked = await TitleModelServer.shared.debugProcessIdentifier
        #expect(stillTracked == nil)
    }
}

/// Whether the real `llama-server` binary and title-gen model file this
/// suite was written against are installed on the machine running the
/// tests — gates `TitleModelServerRealServerTests` so CI machines without
/// them just skip it instead of failing.
enum TitleModelServerRealServerAvailability {
    static var isAvailable: Bool {
        let binaryCandidates = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        guard binaryCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        return TaskTitleGenerator.resolveModelPath() != nil
    }
}
