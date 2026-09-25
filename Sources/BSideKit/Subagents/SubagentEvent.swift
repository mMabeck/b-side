import Foundation

/// One event from a child's `events.jsonl` (or the HTTP transport carrying the
/// same shapes), decoded per Pi's `getDisplayItems` (`extensions/subagent/index.ts`).
///
/// Tool names and arguments live only on `message_end`'s assistant content
/// parts; `tool_execution_update`/`tool_execution_end` carry a `toolCallId`
/// but no arguments, and only report liveness/completion for a call already
/// known from that assistant message.
public enum SubagentEvent: Sendable, Equatable {
    case messageEnd(role: String?, stopReason: String?, errorMessage: String?, toolCalls: [SubagentToolCall], text: String?, usage: MessageUsage? = nil)
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
            return .messageEnd(
                role: role,
                stopReason: stopReason,
                errorMessage: errorMessage,
                toolCalls: toolCalls,
                text: text,
                usage: MessageUsage.decode(from: message)
            )
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

/// Token usage of one assistant message, as Pi reports it on `message.usage`
/// (`cost` is `usage.cost.total`), plus the message's `model`.
public struct MessageUsage: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var cost: Double = 0
    public var totalTokens = 0
    public var model: String?

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cost: Double = 0, totalTokens: Int = 0, model: String? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cost = cost
        self.totalTokens = totalTokens
        self.model = model
    }

    static func decode(from message: [String: JSONValue]) -> MessageUsage? {
        guard let usage = message["usage"]?.objectValue else { return nil }
        return MessageUsage(
            input: usage["input"]?.intValue ?? 0,
            output: usage["output"]?.intValue ?? 0,
            cacheRead: usage["cacheRead"]?.intValue ?? 0,
            cacheWrite: usage["cacheWrite"]?.intValue ?? 0,
            cost: usage["cost"]?.objectValue?["total"]?.doubleValue ?? 0,
            totalTokens: usage["totalTokens"]?.intValue ?? 0,
            model: message["model"]?.stringValue
        )
    }
}

/// The `done.json` payload written when a child finishes.
public struct SubagentDonePayload: Sendable, Equatable {
    public var exitCode: Int?
    public var stopReason: String?
    public var errorMessage: String?
    /// Cumulative totals for the run, when the sender tracks them. Replaces
    /// the per-message tally, which misses anything sent before the card opened.
    public var statistics: RunStatistics?

    public init(exitCode: Int? = nil, stopReason: String? = nil, errorMessage: String? = nil, statistics: RunStatistics? = nil) {
        self.exitCode = exitCode
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.statistics = statistics
    }

    public static func decode(from data: Data) -> SubagentDonePayload? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue
        else { return nil }
        return SubagentDonePayload(
            exitCode: object["exitCode"]?.intValue,
            stopReason: object["stopReason"]?.stringValue,
            errorMessage: object["errorMessage"]?.stringValue,
            statistics: object["usage"]?.objectValue.map { usage in
                RunStatistics(
                    turns: usage["turns"]?.intValue ?? 0,
                    input: usage["input"]?.intValue ?? 0,
                    output: usage["output"]?.intValue ?? 0,
                    cacheRead: usage["cacheRead"]?.intValue ?? 0,
                    cacheWrite: usage["cacheWrite"]?.intValue ?? 0,
                    cost: usage["cost"]?.doubleValue ?? 0,
                    contextTokens: usage["contextTokens"]?.intValue ?? 0,
                    model: object["model"]?.stringValue
                )
            }
        )
    }
}
