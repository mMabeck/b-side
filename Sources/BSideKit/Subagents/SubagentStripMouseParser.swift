import Foundation

/// Parses SGR mouse-report bytes and hit-tests them against a rendered
/// `SubagentStripRenderer.Result`. Ghostty translates a click over the strip
/// surface's `NSView` into an SGR report delivered via the in-memory
/// session's `write` handler (see `GhosttyBridge.SubagentStripHost`); this
/// type is pure so parsing/hit-testing are unit-testable without a live surface.
public enum SubagentStripMouseParser {
    public struct MouseEvent: Equatable {
        public let button: Int
        /// 1-based, as SGR reports them.
        public let column: Int
        public let row: Int
        public let isPress: Bool

        public init(button: Int, column: Int, row: Int, isPress: Bool) {
            self.button = button
            self.column = column
            self.row = row
            self.isPress = isPress
        }
    }

    /// Only press events (`M`) matter to the strip; release (`m`) parses too, for callers filtering a real click vs. a drag.
    public static func parse(_ data: Data) -> [MouseEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [MouseEvent] = []
        var remainder = Substring(text)
        while let range = remainder.range(of: "\u{1B}[<") {
            let afterPrefix = remainder[range.upperBound...]
            guard let terminatorIndex = afterPrefix.firstIndex(where: { $0 == "M" || $0 == "m" }) else { break }
            let body = afterPrefix[..<terminatorIndex]
            let isPress = afterPrefix[terminatorIndex] == "M"
            let components = body.split(separator: ";", omittingEmptySubsequences: false)
            if components.count == 3,
                let button = Int(components[0]), let column = Int(components[1]), let row = Int(components[2])
            {
                events.append(MouseEvent(button: button, column: column, row: row, isPress: isPress))
            }
            remainder = afterPrefix[afterPrefix.index(after: terminatorIndex)...]
        }
        return events
    }

    public enum HitTestResult: Equatable {
        case card(childId: String)
        case mainHint
    }

    /// A card's child id within `cardRowCount` rows and a slot's column
    /// range, `.mainHint` on the label row's hint, else `nil`.
    public static func hitTest(column: Int, row: Int, result: SubagentStripRenderer.Result) -> HitTestResult? {
        let zeroBasedColumn = column - 1
        let zeroBasedRow = row - 1
        guard zeroBasedRow >= 0 else { return nil }

        if zeroBasedRow < SubagentStripRenderer.cardRowCount {
            guard let slot = result.slots.first(where: { $0.columnRange.contains(zeroBasedColumn) }) else { return nil }
            return .card(childId: slot.childId)
        }

        if zeroBasedRow == SubagentStripRenderer.cardRowCount, let hintRange = result.mainHintRange,
            hintRange.contains(zeroBasedColumn)
        {
            return .mainHint
        }
        return nil
    }
}
