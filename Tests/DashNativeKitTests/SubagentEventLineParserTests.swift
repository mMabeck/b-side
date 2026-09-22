import Foundation
import Testing

@testable import DashNativeKit

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

    @Test("A partial trailing line without a newline is held back until it arrives")
    func partialTrailingLine() {
        var parser = SubagentEventLineParser()
        let complete = #"{"type":"tool_execution_end","toolCallId":"1","toolName":"bash"}"# + "\n"
        let partial = #"{"type":"tool_execution_end","toolCallId":"2","toolNam"#

        let firstBatch = parser.consume(Data((complete + partial).utf8))
        #expect(firstBatch.count == 1)

        let rest = #"e":"read"}"# + "\n"
        let secondBatch = parser.consume(Data(rest.utf8))
        #expect(secondBatch.count == 1)
        if case let .toolExecutionEnd(id, name) = secondBatch[0] {
            #expect(id == "2")
            #expect(name == "read")
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

    @Test("An unrecognised event type is skipped")
    func unrecognisedTypeIsSkipped() {
        var parser = SubagentEventLineParser()
        let line = #"{"type":"some_future_event","foo":"bar"}"# + "\n"
        let events = parser.consume(Data(line.utf8))
        #expect(events.isEmpty)
    }

    @Test("message_end decodes role, stopReason and errorMessage")
    func messageEndDecoding() {
        var parser = SubagentEventLineParser()
        let line = #"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"boom"}}"# + "\n"
        let events = parser.consume(Data(line.utf8))
        #expect(events.count == 1)
        if case let .messageEnd(role, stopReason, errorMessage, toolCalls, text) = events[0] {
            #expect(role == "assistant")
            #expect(stopReason == "error")
            #expect(errorMessage == "boom")
            #expect(toolCalls.isEmpty)
            #expect(text == nil)
        } else {
            Issue.record("Expected messageEnd")
        }
    }

    @Test("message_end decodes an assistant toolCall content part's id, name and arguments")
    func messageEndDecodesToolCallPart() {
        var parser = SubagentEventLineParser()
        let line = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Looking now."},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"ls"}}]}}"# + "\n"
        let events = parser.consume(Data(line.utf8))
        #expect(events.count == 1)
        if case let .messageEnd(role, _, _, toolCalls, text) = events[0] {
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

    @Test("message_end with a toolResult role decodes toolCallId and isError")
    func messageEndDecodesToolResult() {
        var parser = SubagentEventLineParser()
        let line = #"{"type":"message_end","message":{"role":"toolResult","toolCallId":"call_1","isError":true}}"# + "\n"
        let events = parser.consume(Data(line.utf8))
        #expect(events.count == 1)
        if case let .toolResult(toolCallId, isError) = events[0] {
            #expect(toolCallId == "call_1")
            #expect(isError == true)
        } else {
            Issue.record("Expected toolResult")
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
