import Foundation
import Testing

@testable import BSideKit

@Suite("ToolCallLineFormatter")
struct ToolCallLineFormatterTests {
    @Test("Each tool name formats its own args into a distinct one-line summary", arguments: [
        (toolName: "bash", args: ["command": JSONValue.string("ls -la")], expected: "$ ls -la"),
        (toolName: "bash", args: ["command": JSONValue.string(String(repeating: "a", count: 80))], expected: "$ \(String(repeating: "a", count: 60))..."),
        (toolName: "read", args: ["path": JSONValue.string("/tmp/x.swift"), "symbol": JSONValue.string("Foo.bar")], expected: "read /tmp/x.swift::Foo.bar"),
        (toolName: "read", args: ["path": JSONValue.string("/tmp/x.swift"), "offset": JSONValue.number(10), "limit": JSONValue.number(5)], expected: "read /tmp/x.swift:10-14"),
        (toolName: "read", args: ["path": JSONValue.string("\(NSHomeDirectory())/project/file.swift")], expected: "read ~/project/file.swift"),
        (toolName: "search", args: ["query": JSONValue.string("cacheKey"), "kind": JSONValue.string("def")], expected: "search /cacheKey/ [def]"),
        (toolName: "search", args: ["query": JSONValue.string("cacheKey"), "kind": JSONValue.string("any")], expected: "search /cacheKey/"),
        (toolName: "code_tree", args: ["path": JSONValue.string("src"), "depth": JSONValue.number(2)], expected: "code_tree src depth=2"),
        (toolName: "write", args: ["path": JSONValue.string("out.txt"), "content": JSONValue.string("a\nb\nc")], expected: "write out.txt (3 lines)"),
        (toolName: "write", args: ["path": JSONValue.string("out.txt"), "content": JSONValue.string("a")], expected: "write out.txt"),
        (toolName: "edit", args: ["path": JSONValue.string("out.txt")], expected: "edit out.txt"),
        (toolName: "subagent", args: ["agent": JSONValue.string("explorer"), "taskName": JSONValue.string("Map cache callers")], expected: "subagent explorer: Map cache callers"),
        (toolName: "web_search", args: ["query": JSONValue.string("swift testing")], expected: "web_search \"swift testing\""),
        (toolName: "mystery", args: ["foo": JSONValue.string("bar")], expected: "mystery {\"foo\":\"bar\"}"),
    ])
    func formatsToolCall(toolName: String, args: [String: JSONValue], expected: String) {
        #expect(ToolCallLineFormatter.format(toolName: toolName, args: args) == expected)
    }
}
