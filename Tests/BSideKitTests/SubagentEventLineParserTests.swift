import Foundation
import Testing

@testable import BSideKit

@Suite("SubagentEventLineParser")
struct SubagentEventLineParserTests {
    @Test("A single complete line decodes to one event")
    func singleCompleteLine() {
        var parser = SubagentEventLineParser()
        let line = #"{"type":"tool_execution_end","toolCallId":"1","toolName":"bash"}"# + "\n"
        let events = parser.consume(Data(line.utf8))
        #expect(events.count == 1)
        if case let .toolExecutionEnd(id, name) = events[0] {
            #expect(id == "1")
            #expect(name == "bash")
        } else {
            Issue.record("Expected toolExecutionEnd")
        }
    }

    @Test("A malformed line is skipped without blocking later lines")
    func malformedLineIsSkipped() {
        var parser = SubagentEventLineParser()
        let malformed = "{not valid json\n"
        let valid = #"{"type":"tool_execution_end","toolCallId":"1","toolName":"bash"}"# + "\n"
        let events = parser.consume(Data((malformed + valid).utf8))
        #expect(events.count == 1)
    }

    @Test("message_end decodes an assistant toolCall content part's id, name and arguments")
    func messageEndDecodesToolCallPart() {
        var parser = SubagentEventLineParser()
        let line = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Looking now."},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"ls"}}]}}"# + "\n"
        let events = parser.consume(Data(line.utf8))
        #expect(events.count == 1)
        if case let .messageEnd(role, _, _, toolCalls, text, _) = events[0] {
            #expect(role == "assistant")
            #expect(text == "Looking now.")
            #expect(toolCalls.count == 1)
            #expect(toolCalls.first?.id == "call_1")
            #expect(toolCalls.first?.name == "bash")
            #expect(toolCalls.first?.arguments["command"]?.stringValue == "ls")
        } else {
            Issue.record("Expected messageEnd")
        }
    }
}

@Suite("SubagentDonePayload")
struct SubagentDonePayloadTests {
    @Test("Decodes exitCode, stopReason and errorMessage")
    func decodesDonePayload() {
        let json = #"{"exitCode":1,"stopReason":"error","errorMessage":"boom"}"#
        let payload = SubagentDonePayload.decode(from: Data(json.utf8))
        #expect(payload?.exitCode == 1)
        #expect(payload?.stopReason == "error")
        #expect(payload?.errorMessage == "boom")
    }
}
