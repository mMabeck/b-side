import Foundation

/// Incrementally splits appended bytes into complete `\n`-terminated JSON
/// lines, decoding each into a `SubagentEvent`. Shared by the file-tailing
/// transport (jsonl on disk) and the HTTP transport, since both deliver the
/// same line-oriented event stream, possibly split across multiple chunks.
///
/// A partial trailing line (no `\n` yet) is held back until the rest
/// arrives. A malformed line is skipped without blocking lines after it.
public struct SubagentEventLineParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feeds newly received bytes and returns the events decoded from any
    /// complete lines now available. Incomplete trailing bytes are retained
    /// for the next call.
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
