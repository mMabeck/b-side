import Foundation

/// One event from a child's `events.jsonl` (or the HTTP transport carrying the
/// same shapes), decoded per Pi's `getDisplayItems` (`extensions/subagent/index.ts`).
///
/// Tool names and arguments live only on `message_end`'s assistant content
/// parts; `tool_execution_update`/`tool_execution_end` carry a `toolCallId`
/// but no arguments, and only report liveness/completion for a call already
/// known from that assistant message.
public enum SubagentEvent: Sendable, Equatable {
    case messageEnd(role: String?, stopReason: String?, errorMessage: String?, toolCalls: [SubagentToolCall], text: String?)
    case toolResult(toolCallId: String?, isError: Bool)
    case toolExecutionUpdate(toolCallId: String?, toolName: String?)
    case toolExecutionEnd(toolCallId: String?, toolName: String?)

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
            if role == "toolResult" {
                let toolCallId = message["toolCallId"]?.stringValue
                let isError = message["isError"]?.boolValue ?? false
                return .toolResult(toolCallId: toolCallId, isError: isError)
            }
            let stopReason = message["stopReason"]?.stringValue
            let errorMessage = message["errorMessage"]?.stringValue
            let toolCalls = extractToolCalls(from: message)
            let text = extractText(from: message)
            return .messageEnd(role: role, stopReason: stopReason, errorMessage: errorMessage, toolCalls: toolCalls, text: text)
        case "tool_execution_update":
            let toolCallId = object["toolCallId"]?.stringValue
            let toolName = object["toolName"]?.stringValue ?? object["tool"]?.stringValue
            return .toolExecutionUpdate(toolCallId: toolCallId, toolName: toolName)
        case "tool_execution_end":
            let toolCallId = object["toolCallId"]?.stringValue
            let toolName = object["toolName"]?.stringValue ?? object["tool"]?.stringValue
            return .toolExecutionEnd(toolCallId: toolCallId, toolName: toolName)
        default:
            return nil
        }
    }

    /// An assistant message's `content` array carries each tool call as a
    /// part with `type == "toolCall"`, `id`, `name`, and `arguments`.
    private static func extractToolCalls(from message: [String: JSONValue]) -> [SubagentToolCall] {
        guard case let .array(parts)? = message["content"] else { return [] }
        return parts.compactMap { part -> SubagentToolCall? in
            guard let object = part.objectValue, object["type"]?.stringValue == "toolCall" else { return nil }
            let id = object["id"]?.stringValue
            let name = object["name"]?.stringValue
            let arguments = object["arguments"]?.objectValue ?? [:]
            return SubagentToolCall(id: id, name: name, arguments: arguments)
        }
    }

    /// An assistant message's `content` array may also carry `text` parts,
    /// which surface the child's prose.
    private static func extractText(from message: [String: JSONValue]) -> String? {
        guard case let .array(parts)? = message["content"] else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard let object = part.objectValue, object["type"]?.stringValue == "text" else { return nil }
            return object["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

public struct SubagentToolCall: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var arguments: [String: JSONValue]
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
