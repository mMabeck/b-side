import Foundation

/// Parses SGR mouse-report bytes (`\e[<b;x;yM`/`\e[<b;x;ym`) and hit-tests
/// them against a rendered `SubagentStripRenderer.Result`.
///
/// The strip surface enables mouse reporting (`\e[?1000h\e[?1006h`) on its
/// in-memory Ghostty session; a click over that surface's `NSView` is
/// translated by Ghostty into an SGR report and delivered back to the host
/// through the session's `write` handler (there is no real pty to send it
/// to) — see `GhosttyBridge.SubagentStripHost`. This type is pure so the
/// parsing and hit-testing are unit-testable without a live surface.
public enum SubagentStripMouseParser {
    public struct MouseEvent: Equatable {
        public let button: Int
        /// 1-based terminal column/row, as SGR reports them.
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

    /// Parses every complete SGR mouse sequence found in `data`. Only press
    /// events (`M`) matter to the strip — release (`m`) sequences parse too,
    /// in case a caller wants to filter for a real click (press then
    /// release) rather than a drag.
    public static func parse(_ data: Data) -> [MouseEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [MouseEvent] = []
        var remainder = Substring(text)
        while let range = remainder.range(of: "\u{1B}[<") {
            let afterPrefix = remainder[range.upperBound...]
            guard let terminatorIndex = afterPrefix.firstIndex(where: { $0 == "M" || $0 == "m" }) else { break }
            let body = afterPrefix[afterPrefix.startIndex..<terminatorIndex]
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

    /// Resolves a 1-based `(column, row)` click against a rendered strip:
    /// a card's child id if the click lands within `cardRowCount` rows and
    /// inside one of `slots`' column ranges, `.mainHint` if it lands on the
    /// label row's "main" hint, else `nil`.
    public enum HitTestResult: Equatable {
        case card(childId: String)
        case mainHint
    }

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
