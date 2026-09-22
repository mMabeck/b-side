import Foundation
import Testing

@testable import BSideKit

@Suite("ToolCallLineFormatter")
struct ToolCallLineFormatterTests {
    @Test("bash clips the command to 60 characters")
    func bashFormatting() {
        let short = ToolCallLineFormatter.format(toolName: "bash", args: ["command": .string("ls -la")])
        #expect(short == "$ ls -la")

        let longCommand = String(repeating: "a", count: 80)
        let clipped = ToolCallLineFormatter.format(toolName: "bash", args: ["command": .string(longCommand)])
        #expect(clipped == "$ \(String(repeating: "a", count: 60))...")
    }

    @Test("read shows the path plus a symbol suffix")
    func readWithSymbol() {
        let line = ToolCallLineFormatter.format(
            toolName: "read",
            args: ["path": .string("/tmp/x.swift"), "symbol": .string("Foo.bar")]
        )
        #expect(line == "read /tmp/x.swift::Foo.bar")
    }

    @Test("read shows the path plus an offset-limit range")
    func readWithRange() {
        let line = ToolCallLineFormatter.format(
            toolName: "read",
            args: ["path": .string("/tmp/x.swift"), "offset": .number(10), "limit": .number(5)]
        )
        #expect(line == "read /tmp/x.swift:10-14")
    }

    @Test("read abbreviates a home-prefixed path")
    func readAbbreviatesHome() {
        let home = NSHomeDirectory()
        let line = ToolCallLineFormatter.format(toolName: "read", args: ["path": .string("\(home)/project/file.swift")])
        #expect(line == "read ~/project/file.swift")
    }

    @Test("search clips the query to 80 characters and shows a non-any kind")
    func searchFormatting() {
        let line = ToolCallLineFormatter.format(
            toolName: "search",
            args: ["query": .string("cacheKey"), "kind": .string("def")]
        )
        #expect(line == "search /cacheKey/ [def]")

        let anyKind = ToolCallLineFormatter.format(
            toolName: "search",
            args: ["query": .string("cacheKey"), "kind": .string("any")]
        )
        #expect(anyKind == "search /cacheKey/")
    }

    @Test("code_tree shows the path and an optional depth")
    func codeTreeFormatting() {
        let line = ToolCallLineFormatter.format(
            toolName: "code_tree",
            args: ["path": .string("src"), "depth": .number(2)]
        )
        #expect(line == "code_tree src depth=2")
    }

    @Test("write shows the path and a line count when there is more than one line")
    func writeFormatting() {
        let line = ToolCallLineFormatter.format(
            toolName: "write",
            args: ["path": .string("out.txt"), "content": .string("a\nb\nc")]
        )
        #expect(line == "write out.txt (3 lines)")

        let singleLine = ToolCallLineFormatter.format(
            toolName: "write",
            args: ["path": .string("out.txt"), "content": .string("a")]
        )
        #expect(singleLine == "write out.txt")
    }

    @Test("edit shows only the path")
    func editFormatting() {
        let line = ToolCallLineFormatter.format(toolName: "edit", args: ["path": .string("out.txt")])
        #expect(line == "edit out.txt")
    }

    @Test("subagent shows the agent and task name")
    func subagentFormatting() {
        let line = ToolCallLineFormatter.format(
            toolName: "subagent",
            args: ["agent": .string("explorer"), "taskName": .string("Map cache callers")]
        )
        #expect(line == "subagent explorer: Map cache callers")
    }

    @Test("web_search quotes and clips the query")
    func webSearchFormatting() {
        let line = ToolCallLineFormatter.format(toolName: "web_search", args: ["query": .string("swift testing")])
        #expect(line == "web_search \"swift testing\"")
    }

    @Test("An unknown tool falls back to name plus clipped JSON args")
    func defaultFormatting() {
        let line = ToolCallLineFormatter.format(toolName: "mystery", args: ["foo": .string("bar")])
        #expect(line == "mystery {\"foo\":\"bar\"}")
    }
}
