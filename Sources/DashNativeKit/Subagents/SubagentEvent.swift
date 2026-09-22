import Foundation

/// One event from a child's `events.jsonl` (or the HTTP transport carrying the
/// same shapes), decoded per `interactive-child.ts`.
public enum SubagentEvent: Sendable, Equatable {
    case messageEnd(role: String?, stopReason: String?, errorMessage: String?, toolCalls: [SubagentToolCall])
    case toolExecutionUpdate(toolCallId: String?, toolName: String?, args: [String: JSONValue])
    case toolExecutionEnd(toolCallId: String?, toolName: String?, args: [String: JSONValue])

    /// Decodes one JSON line object (`{"type": "...", ...payload}`). Returns
    /// `nil` for malformed lines or unrecognised types, which are skipped
    /// rather than blocking the rest of the stream.
    public static func decode(from line: Data) -> SubagentEvent? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              let object = value.objectValue,
              let type = object["type"]?.stringValue
        else { return nil }

        switch type {
        case "message_end":
            let message = object["message"]?.objectValue ?? [:]
            let role = message["role"]?.stringValue
            let stopReason = message["stopReason"]?.stringValue
            let errorMessage = message["errorMessage"]?.stringValue
            let toolCalls = extractToolCalls(from: message)
            return .messageEnd(role: role, stopReason: stopReason, errorMessage: errorMessage, toolCalls: toolCalls)
        case "tool_execution_update":
            let toolCallId = object["toolCallId"]?.stringValue
            let toolName = object["toolName"]?.stringValue ?? object["tool"]?.stringValue
            let args = argsDictionary(from: object["partialResult"])
            return .toolExecutionUpdate(toolCallId: toolCallId, toolName: toolName, args: args)
        case "tool_execution_end":
            let toolCallId = object["toolCallId"]?.stringValue
            let toolName = object["toolName"]?.stringValue ?? object["tool"]?.stringValue
            let args = argsDictionary(from: object["result"])
            return .toolExecutionEnd(toolCallId: toolCallId, toolName: toolName, args: args)
        default:
            return nil
        }
    }

    /// Assistant messages may carry a `toolCalls`/`content` array with each
    /// call's `args`, echoed back on `tool_execution_end` under `result` in
    /// some tools but not others; both paths are merged so formatting always
    /// has the best arguments available.
    private static func extractToolCalls(from message: [String: JSONValue]) -> [SubagentToolCall] {
        guard case let .array(calls)? = message["toolCalls"] else { return [] }
        return calls.compactMap { call -> SubagentToolCall? in
            guard let object = call.objectValue else { return nil }
            let id = object["id"]?.stringValue ?? object["toolCallId"]?.stringValue
            let name = object["name"]?.stringValue ?? object["toolName"]?.stringValue
            let args = argsDictionary(from: object["args"] ?? object["input"])
            return SubagentToolCall(id: id, name: name, args: args)
        }
    }

    /// A payload's `partialResult`/`result` is either the arguments directly,
    /// or an object nesting them under an `args` key. Either shape is
    /// accepted so callers only ever deal with a flat dictionary.
    private static func argsDictionary(from value: JSONValue?) -> [String: JSONValue] {
        guard let object = value?.objectValue else { return [:] }
        if let nested = object["args"]?.objectValue {
            return nested
        }
        return object
    }
}

public struct SubagentToolCall: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var args: [String: JSONValue]
}

/// The `done.json` payload written when a child finishes.
public struct SubagentDonePayload: Sendable, Equatable {
    public var exitCode: Int?
    public var stopReason: String?
    public var errorMessage: String?

    public static func decode(from data: Data) -> SubagentDonePayload? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue
        else { return nil }
        return SubagentDonePayload(
            exitCode: object["exitCode"]?.intValue,
            stopReason: object["stopReason"]?.stringValue,
            errorMessage: object["errorMessage"]?.stringValue
        )
    }
}
