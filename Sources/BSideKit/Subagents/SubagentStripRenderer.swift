import Foundation

/// Pure terminal-native rendering of a task's subagent cards, drawn as text
/// (box-drawing + SGR colour codes) rather than SwiftUI — mirrors
/// `agentic/pi/extensions/_agent_cards/card.ts`'s look so the strip reads
/// like the same terminal it lives above. No AppKit, no libghostty: the
/// output is plain ANSI text a `SubagentStripHost` (see `GhosttyBridge.swift`)
/// writes into an in-memory Ghostty surface.
///
///     subagents · 2 running · 1 done ────────────── click a card to view · ⌃⌘0 main
///     ┌─ explorer · Map cache callers ┐ ╔═ builder · Add retry logic ══╗
///     │ → search "cacheKey"           │ ║ → read src/net/client.ts     ║
///     │ → read src/cache/store.ts     │ ║                              ║
///     │                                │ ║                              ║
///     │                                │ ║                              ║
///     │ ⠙ working  18s                 │ ║ ! waiting for you  4s        ║
///     └────────────────────────────────┘ ╚══════════════════════════════╝
///
/// The viewed card (the one currently swapped into the main area, if any)
/// draws with a double-line border instead of the accent single line, so
/// which surface is live is legible from the strip alone.
public enum SubagentStripRenderer {
    /// Fixed body-row budget: 4 tool-call lines plus a status row, framed by
    /// a top and bottom border — 6 rows per card, plus the label/rule row
    /// below. `GhosttyBridge`'s strip host turns this into a point height
    /// using the surface's own cell metrics.
    public static let cardBodyRowCount = 4
    public static let cardRowCount = cardBodyRowCount + 2 // + top/bottom border
    public static let labelRowCount = 1
    public static let totalRowCount = cardRowCount + labelRowCount

    public static let minCardWidth = 30
    private static let columnGap = 1

    /// One rendered card's column span within the strip, in 0-based
    /// terminal columns — shared by rendering and by
    /// `SubagentStripMouseParser.hitTest` so a click always resolves against
    /// exactly the layout that was drawn.
    public struct CardSlot: Equatable {
        public let childId: String
        public let columnRange: Range<Int>
        public init(childId: String, columnRange: Range<Int>) {
            self.childId = childId
            self.columnRange = columnRange
        }
    }

    public struct Result: Equatable {
        /// Exactly `totalRowCount` lines, each `columns` visible characters
        /// wide (ANSI escapes aside), or empty if `runs` is empty.
        public let lines: [String]
        public let slots: [CardSlot]
        /// Column range of the "main" hint in the label row, so clicking it
        /// can be hit-tested the same way as a card.
        public let mainHintRange: Range<Int>?

        public init(lines: [String], slots: [CardSlot], mainHintRange: Range<Int>?) {
            self.lines = lines
            self.slots = slots
            self.mainHintRange = mainHintRange
        }
    }

    private static let spinnerFrames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    // ANSI SGR codes (terminal palette, not RGB — matches the surrounding
    // Ghostty theme instead of a hardcoded colour).
    private enum SGR {
        static let reset = "\u{1B}[0m"
        static let dim = "\u{1B}[2m"
        static let bold = "\u{1B}[1m"
        static let magenta = "\u{1B}[35m"
        static let yellow = "\u{1B}[33m"
        static let red = "\u{1B}[31m"
        static let brightBlack = "\u{1B}[90m"
        static let reverse = "\u{1B}[7m"
    }

    public static func render(runs: [ChildRun], viewedChildId: String?, columns: Int, now: Date) -> Result {
        guard !runs.isEmpty, columns > 0 else {
            return Result(lines: [], slots: [], mainHintRange: nil)
        }

        let widthBudget = max(columns, minCardWidth)
        let maxCards = max(1, (widthBudget + columnGap) / (minCardWidth + columnGap))
        let shown = Array(runs.prefix(maxCards))
        let hiddenCount = runs.count - shown.count

        // Equal width: split the available columns evenly, minimum enforced.
        let totalGaps = columnGap * (shown.count - 1)
        let cardWidth = max(minCardWidth, (widthBudget - totalGaps) / max(shown.count, 1))

        var cardLines: [[String]] = []
        var slots: [CardSlot] = []
        var cursor = 0
        for run in shown {
            let isViewed = run.id == viewedChildId
            cardLines.append(renderCard(run, width: cardWidth, isViewed: isViewed, now: now))
            slots.append(CardSlot(childId: run.id, columnRange: cursor..<(cursor + cardWidth)))
            cursor += cardWidth + columnGap
        }

        var rows: [String] = []
        for rowIndex in 0..<cardRowCount {
            var row = ""
            for (index, lines) in cardLines.enumerated() {
                if index > 0 { row += String(repeating: " ", count: columnGap) }
                row += lines[rowIndex]
            }
            rows.append(row)
        }

        let (labelLine, mainHintRange) = renderLabelRow(runs: runs, columns: columns, hiddenCount: hiddenCount)
        rows.append(labelLine)

        return Result(lines: rows, slots: slots, mainHintRange: mainHintRange)
    }

    private static func renderCard(_ run: ChildRun, width: Int, isViewed: Bool, now: Date) -> [String] {
        let isFinished = run.state == .completed || run.state == .failed
        let color: String
        switch run.state {
        case .active: color = SGR.magenta
        case .blocked: color = SGR.yellow
        case .failed: color = SGR.red
        case .completed: color = SGR.brightBlack
        }
        let bodyColor = isFinished ? SGR.brightBlack : ""

        let inner = width - 2
        let title = run.taskLabel.isEmpty ? run.agent : "\(run.agent) · \(run.taskLabel)"
        let room = max(0, inner - 3)
        let clippedTitle = String(title.prefix(room))

        let topLeft = isViewed ? "╔═ " : "┌─ "
        let topRight = isViewed ? "╗" : "┐"
        let botLeft = isViewed ? "╚" : "└"
        let botRight = isViewed ? "╝" : "┘"
        let horizontal = isViewed ? "═" : "─"
        let vertical = isViewed ? "║" : "│"

        let fillCount = max(0, inner - 3 - clippedTitle.count)
        let titleStyle = isViewed ? SGR.bold + color : color
        var lines: [String] = []
        lines.append(
            titleStyle + topLeft + SGR.reset + titleStyle + clippedTitle + SGR.reset
                + color + " " + String(repeating: horizontal, count: fillCount) + topRight + SGR.reset
        )

        func bodyRow(_ text: String, textColor: String) -> String {
            let visible = fit(text, width: inner - 2)
            return color + vertical + SGR.reset + " " + textColor + visible + SGR.reset + " " + color + vertical + SGR.reset
        }

        var toolRows = run.toolLines.suffix(cardBodyRowCount - 1).map { line in bodyRow("→ \(line)", textColor: bodyColor) }
        while toolRows.count < cardBodyRowCount - 1 {
            toolRows.append(bodyRow("", textColor: bodyColor))
        }
        lines.append(contentsOf: toolRows)

        let elapsed = (run.endedAt ?? now).timeIntervalSince(run.startedAt)
        let statusText: String
        let statusColor: String
        switch run.state {
        case .active:
            let frame = spinnerFrames[Int(now.timeIntervalSinceReferenceDate * 10) % spinnerFrames.count]
            statusText = "\(frame) working  \(formatElapsed(elapsed))"
            statusColor = color
        case .blocked:
            statusText = "! waiting for you  \(formatElapsed(elapsed))"
            statusColor = color
        case .completed:
            statusText = "✔ done  \(formatElapsed(elapsed))"
            statusColor = bodyColor
        case .failed:
            statusText = "✗ failed  \(formatElapsed(elapsed))"
            statusColor = color
        }
        lines.append(bodyRow(statusText, textColor: statusColor))

        lines.append(color + botLeft + String(repeating: horizontal, count: inner) + botRight + SGR.reset)
        return lines
    }

    private static func renderLabelRow(runs: [ChildRun], columns: Int, hiddenCount: Int) -> (String, Range<Int>?) {
        let running = runs.filter { $0.state == .active }.count
        let blocked = runs.filter { $0.state == .blocked }.count
        let done = runs.filter { $0.state == .completed || $0.state == .failed }.count

        var parts: [String] = ["subagents"]
        if running > 0 { parts.append("\(running) running") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if done > 0 { parts.append("\(done) done") }
        if hiddenCount > 0 { parts.append("+\(hiddenCount) more") }
        let label = " " + parts.joined(separator: " · ") + " "

        let hint = "click a card to view · ⌃⌘0 main"
        // Clamped to `columns`: with several states in play (running,
        // blocked, done, +N more) the label alone can exceed a narrow
        // strip — `hintStart` must never land past the end of the line, or
        // the range built below would have its lower bound past its upper
        // one.
        let hintStart = min(max(label.count, columns - hint.count - 1), columns)
        let ruleWidth = max(0, hintStart - label.count)
        let plain = label + String(repeating: "─", count: ruleWidth) + " " + hint
        let padded = fit(plain, width: columns)

        let hintLowerBound = min(hintStart + 1, columns)
        let hintUpperBound = min(columns, hintStart + 1 + hint.count)
        let hintRange = hintLowerBound..<max(hintLowerBound, hintUpperBound)
        return (SGR.dim + padded + SGR.reset, hintRange.isEmpty ? nil : hintRange)
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 {
            return "\(total)s"
        }
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes)m \(String(format: "%02d", seconds))s"
    }

    /// Pads `text` to exactly `width` visible columns, or clips it — the
    /// same contract as `card.ts`'s `fit`, minus ANSI-awareness (callers
    /// here only ever pass plain text into `fit`, colour is layered around
    /// it afterwards).
    static func fit(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        if text.count > width {
            return String(text.prefix(width))
        }
        return text + String(repeating: " ", count: width - text.count)
    }
}
