import AppKit
import HighlightSwift

/// Maps a `HighlightSwift`-coloured reconstruction of one side (old or new)
/// of a diff back onto the rendered unified-diff rows. Pure and
/// side-effect-free — the actual JavaScriptCore call lives in
/// `DiffPaneView`, off the main thread; everything here is synchronous
/// string/attribute bookkeeping, safe to unit test without a JS runtime.
enum DiffSyntaxHighlighter {
    /// Diffs bigger than this many rows skip highlighting entirely — the
    /// reconstructed side text would be large and the win is marginal.
    static let maxHighlightableRowCount = 5000

    struct LineColorRun: Equatable {
        let range: NSRange
        let color: NSColor
    }

    /// Splits `attributed`'s `.foregroundColor` runs onto one array per line
    /// (split on `"\n"`), each entry's ranges relative to the start of that line.
    static func colorRunsByLine(in attributed: NSAttributedString) -> [[LineColorRun]] {
        let fullLength = attributed.length
        let lines = attributed.string.components(separatedBy: "\n")
        var result: [[LineColorRun]] = []
        var offset = 0

        for line in lines {
            let lineLength = (line as NSString).length
            var runs: [LineColorRun] = []
            var index = 0
            while index < lineLength {
                let absoluteIndex = offset + index
                guard absoluteIndex < fullLength else { break }
                var effectiveRange = NSRange(location: 0, length: 0)
                let color = attributed.attribute(.foregroundColor, at: absoluteIndex, effectiveRange: &effectiveRange) as? NSColor
                let runEndInLine = min(effectiveRange.location + effectiveRange.length - offset, lineLength)
                if let color, runEndInLine > index {
                    runs.append(LineColorRun(range: NSRange(location: index, length: runEndInLine - index), color: color))
                }
                index = max(runEndInLine, index + 1)
            }
            result.append(runs)
            offset += lineLength + 1 // +1 for the "\n" joiner, absent after the last line but harmless to overcount there.
        }
        return result
    }

    /// Applies `colorRunsByLine` (one entry per reconstructed side line, in
    /// order) onto `result` at the row locations given by `rowIndices`
    /// (indices into `rowRanges`/`rowTextLengths`, in the same order the
    /// side text was reconstructed). A run that would run past its row's
    /// own text length (a mismatch between the highlighted and diff text)
    /// is skipped rather than mis-colouring adjacent rows.
    static func applyColorRuns(
        _ colorRunsByLine: [[Self.LineColorRun]],
        toRowIndices rowIndices: [Int],
        rowTextLengths: [Int],
        rowRanges: [NSRange],
        in result: NSMutableAttributedString
    ) {
        for (lineIndex, rowIndex) in rowIndices.enumerated() {
            guard lineIndex < colorRunsByLine.count,
                  rowIndex < rowRanges.count, rowIndex < rowTextLengths.count else { continue }
            let runs = colorRunsByLine[lineIndex]
            guard !runs.isEmpty else { continue }
            let rowRange = rowRanges[rowIndex]
            let rowTextLength = rowTextLengths[rowIndex]
            for run in runs {
                guard run.range.location + run.range.length <= rowTextLength else { continue }
                let target = NSRange(location: rowRange.location + run.range.location, length: run.range.length)
                guard target.location + target.length <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: run.color, range: target)
            }
        }
    }

    /// The theme suited to the current appearance; matches Xcode's own light/dark syntax colours.
    static func colors(isDark: Bool) -> HighlightColors {
        isDark ? .dark(.xcode) : .light(.xcode)
    }
}
