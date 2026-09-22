import Foundation

/// Formats one tool call into the single clipped row Pi's own subagent cards
/// use, mirroring `tool-line.ts::formatToolCall`. Pure text only — the card
/// view applies colour by prefix, not this formatter.
public enum ToolCallLineFormatter {
    /// Formats `toolName`/`args` into the row body, without the leading `→ `.
    public static func format(toolName: String, args: [String: JSONValue]) -> String {
        switch toolName {
        case "bash":
            let command = args["command"]?.stringValue ?? "..."
            return "$ \(clip(command, 60))"
        case "read":
            let rawPath = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? "..."
            var text = "read \(shortenPath(rawPath))"
            if let symbol = args["symbol"]?.stringValue {
                text += "::\(symbol)"
            } else if args["offset"] != nil || args["limit"] != nil {
                let startLine = args["offset"]?.intValue ?? 1
                if let limit = args["limit"]?.intValue {
                    text += ":\(startLine)-\(startLine + limit - 1)"
                } else {
                    text += ":\(startLine)"
                }
            }
            return text
        case "search":
            let query = args["query"]?.stringValue ?? ""
            var text = "search /\(clip(query, 80))/"
            if let kind = args["kind"]?.stringValue, kind != "any" {
                text += " [\(kind)]"
            }
            return text
        case "code_tree":
            let rawPath = args["path"]?.stringValue ?? "."
            var text = "code_tree \(shortenPath(rawPath))"
            if let depth = args["depth"]?.intValue {
                text += " depth=\(depth)"
            }
            return text
        case "web_search":
            let query = args["query"]?.stringValue ?? ""
            return "web_search \"\(clip(query, 80))\""
        case "web_browse":
            let command = args["command"]?.stringValue ?? "..."
            return "web_browse \(clip(command, 80))"
        case "subagent":
            let agent = args["agent"]?.stringValue ?? "?"
            let taskName = args["taskName"]?.stringValue ?? "..."
            return "subagent \(agent): \(taskName)"
        case "write":
            let rawPath = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? "..."
            var text = "write \(shortenPath(rawPath))"
            if let content = args["content"]?.stringValue {
                let lines = content.components(separatedBy: "\n").count
                if lines > 1 {
                    text += " (\(lines) lines)"
                }
            }
            return text
        case "edit":
            let rawPath = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? "..."
            return "edit \(shortenPath(rawPath))"
        case "ls":
            let rawPath = args["path"]?.stringValue ?? "."
            return "ls \(shortenPath(rawPath))"
        case "find":
            let pattern = args["pattern"]?.stringValue ?? "*"
            let rawPath = args["path"]?.stringValue ?? "."
            return "find \(pattern) in \(shortenPath(rawPath))"
        case "grep":
            let pattern = args["pattern"]?.stringValue ?? ""
            let rawPath = args["path"]?.stringValue ?? "."
            return "grep /\(pattern)/ in \(shortenPath(rawPath))"
        default:
            let preview = clip(jsonPreview(args), 120)
            return "\(toolName) \(preview)"
        }
    }

    /// Shortens an argument preview to `max` characters, marking what was cut.
    static func clip(_ text: String, _ max: Int) -> String {
        text.count > max ? "\(text.prefix(max))..." : text
    }

    static func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func jsonPreview(_ args: [String: JSONValue]) -> String {
        let sortedKeys = args.keys.sorted()
        let pairs = sortedKeys.map { key -> String in
            "\"\(key)\":\(jsonPreview(args[key]!))"
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    private static func jsonPreview(_ value: JSONValue) -> String {
        switch value {
        case let .string(value): return "\"\(value)\""
        case let .number(value):
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value)) : String(value)
        case let .bool(value): return value ? "true" : "false"
        case let .object(value):
            let pairs = value.keys.sorted().map { "\"\($0)\":\(jsonPreview(value[$0]!))" }
            return "{\(pairs.joined(separator: ","))}"
        case let .array(value):
            return "[\(value.map(jsonPreview).joined(separator: ","))]"
        case .null: return "null"
        }
    }
}
