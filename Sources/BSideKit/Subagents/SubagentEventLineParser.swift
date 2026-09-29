import Foundation

/// Shared by the file-tailing and HTTP transports. Holds back a partial trailing line; skips malformed ones.
public struct SubagentEventLineParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func consume(_ data: Data) -> [SubagentEvent] {
        buffer.append(data)

        var events: [SubagentEvent] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if !line.isEmpty, let event = SubagentEvent.decode(from: Data(line)) {
                events.append(event)
            }
        }
        return events
    }
}
