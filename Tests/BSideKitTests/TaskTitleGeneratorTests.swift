import Foundation
import Testing

@testable import BSideKit

@Suite("TaskTitleGenerator output cleanup/validation")
struct TaskTitleGeneratorCleanupTests {
    @Test("strips the [end of text] marker and trailing blank lines")
    func stripsEndOfTextMarker() {
        let raw = "Fix login bug [end of text]\n\n\n"
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == "Fix login bug")
    }

    @Test("strips surrounding quotes")
    func stripsSurroundingQuotes() {
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "\"Fix login bug\" [end of text]") == "Fix login bug")
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "'Fix login bug'") == "Fix login bug")
    }

    @Test("strips trailing punctuation")
    func stripsTrailingPunctuation() {
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "Fix login bug.") == "Fix login bug")
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "Fix login bug!") == "Fix login bug")
    }

    @Test("takes only the first non-empty line of multiline output")
    func takesFirstNonEmptyLine() {
        let raw = "\nFix login bug\nSome extra rambling second line\n[end of text]"
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == "Fix login bug")
    }

    @Test("rejects output with more than the allowed word count")
    func rejectsOverlongWordCount() {
        let raw = "This is a way way way way too long generated title for a task"
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == nil)
    }

    @Test("rejects output over the allowed character length")
    func rejectsOverlongCharacterLength() {
        let raw = String(repeating: "a", count: 61)
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: raw) == nil)
    }

    @Test("rejects output that is empty or all punctuation")
    func rejectsEmptyOutput() {
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "") == nil)
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "   \n\n") == nil)
        #expect(TaskTitleGenerator.cleanTitle(fromRawOutput: "\"\"") == nil)
    }
}

@Suite("TaskTitleGenerator against the real model", .enabled(if: TaskTitleGeneratorRealModelAvailability.isAvailable))
struct TaskTitleGeneratorRealModelTests {
    @Test("generates a short usable title from a real prompt")
    func generatesATitleFromARealPrompt() async throws {
        let title = await TaskTitleGenerator.generate(fromPrompt: "the login page throws a 500 error, please fix it")
        // This may have gone through the resident `TitleModelServer` (if
        // `llama-server` is also installed) or the cold `llama-completion`
        // fallback; either way, tear the shared server down afterward so it
        // doesn't outlive this test process.
        await TitleModelServer.shared.shutdown()
        let unwrapped = try #require(title)
        #expect(!unwrapped.isEmpty)
        #expect(unwrapped.split(separator: " ").count <= 8)
    }
}

/// Whether the real title-gen binary and model file this task's tests were
/// written against are installed on the machine running the suite \u2014 gates
/// `TaskTitleGeneratorRealModelTests` so CI machines without them just skip
/// it instead of failing.
enum TaskTitleGeneratorRealModelAvailability {
    static var isAvailable: Bool {
        let binaryCandidates = ["/opt/homebrew/bin/llama-completion", "/usr/local/bin/llama-completion"]
        guard binaryCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let modelPath = ("~/Claude/title-gen/models/gguf/qwen3-0.6b-title-Q8_0.gguf" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: modelPath)
    }
}
