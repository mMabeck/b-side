import Foundation

/// Pure terminal-native rendering of a task's subagent cards, drawn as text
/// (box-drawing + SGR colour codes), not SwiftUI, so the strip reads like
/// the terminal it lives above. Plain ANSI text a `SubagentStripHost` writes
/// into an in-memory Ghostty surface. The viewed card draws with a
/// double-line border instead of a single line, so which surface is live is legible from the strip alone.
public enum SubagentStripRenderer {
    /// 3 tool-call lines plus a status row, framed top/bottom — 6 rows per card, plus the label row below.
    public static let cardBodyRowCount = 4
    public static let cardRowCount = cardBodyRowCount + 2 // + top/bottom border
    public static let labelRowCount = 1
    public static let totalRowCount = cardRowCount + labelRowCount

    public static let minCardWidth = 30
    private static let columnGap = 1

    /// Shared by rendering and `SubagentStripMouseParser.hitTest` so a click always resolves against the layout drawn.
    public struct CardSlot: Equatable {
        public let childId: String
        public let columnRange: Range<Int>
        public init(childId: String, columnRange: Range<Int>) {
            self.childId = childId
            self.columnRange = columnRange
        }
    }

    public struct Result: Equatable {
        /// Exactly `totalRowCount` lines, each `columns` wide (ANSI aside), or empty if `runs` is empty.
        public let lines: [String]
        public let slots: [CardSlot]
        /// The "main" hint's column range in the label row, hit-testable like a card.
        public let mainHintRange: Range<Int>?

        public init(lines: [String], slots: [CardSlot], mainHintRange: Range<Int>?) {
            self.lines = lines
            self.slots = slots
            self.mainHintRange = mainHintRange
        }
    }

    private static let spinnerFrames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    /// Pi's own spinner rate, so the strip moves in step with the terminal below it.
    public static let spinnerFrameInterval: TimeInterval = 0.08

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
    }

    public static func render(runs: [ChildRun], viewedChildId: String?, columns: Int, now: Date) -> Result {
        guard !runs.isEmpty, columns > 0 else {
            return Result(lines: [], slots: [], mainHintRange: nil)
        }

        // Too narrow for even one card: clamp to just the label row, which fits `columns` exactly via `fit()`.
        guard columns >= minCardWidth else {
            let (labelLine, mainHintRange) = renderLabelRow(runs: runs, columns: columns, hiddenCount: 0)
            let blankRow = String(repeating: " ", count: columns)
            return Result(
                lines: Array(repeating: blankRow, count: cardRowCount) + [labelLine],
                slots: [],
                mainHintRange: mainHintRange
            )
        }

        let maxCards = max(1, (columns + columnGap) / (minCardWidth + columnGap))
        let shown = Array(runs.prefix(maxCards))
        let hiddenCount = runs.count - shown.count

        // Equal width: split the available columns evenly, minimum enforced.
        let totalGaps = columnGap * (shown.count - 1)
        let cardWidth = max(minCardWidth, (columns - totalGaps) / max(shown.count, 1))

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
            let frame = spinnerFrames[max(0, Int(elapsed / spinnerFrameInterval)) % spinnerFrames.count]
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
        // Clamped: with several states in play the label alone can exceed a
        // narrow strip, so `hintStart` must never land past the line's end.
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

    /// Pads or clips to exactly `width`; callers only pass plain text, colour is layered around it afterwards.
    static func fit(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        if text.count > width {
            return String(text.prefix(width))
        }
        return text + String(repeating: " ", count: width - text.count)
    }
}
