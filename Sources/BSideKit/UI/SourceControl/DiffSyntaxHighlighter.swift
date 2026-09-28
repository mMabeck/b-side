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

    /// How much of the input `HighlightSwift` silently drops from the front
    /// before highlighting (it trims `.whitespacesAndNewlines` off both ends
    /// of its output): `droppedLines` whole leading blank lines, plus
    /// `indent` UTF-16 units of leading whitespace remaining on the first
    /// surviving line. Used to keep colour runs aligned to the right row.
    struct LeadingTrim: Equatable {
        let droppedLines: Int
        let indent: Int
    }

    /// Measures the leading whitespace/newline run of `text` the same way
    /// `HighlightSwift` trims it, so colour output can be remapped back onto
    /// the rows it actually corresponds to. A `\r\n` pair counts as one
    /// line break, not two.
    static func leadingTrim(of text: String) -> LeadingTrim {
        let ns = text as NSString
        var index = 0
        var droppedLines = 0
        var indent = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            guard let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            if unit == 0x0D, index + 1 < ns.length, ns.character(at: index + 1) == 0x0A {
                index += 1
                continue
            }
            if unit == 0x0A || unit == 0x0D {
                droppedLines += 1
                indent = 0
            } else {
                indent += 1
            }
            index += 1
        }
        return LeadingTrim(droppedLines: droppedLines, indent: indent)
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
        leadingIndent: Int = 0,
        in result: NSMutableAttributedString
    ) {
        for (lineIndex, rowIndex) in rowIndices.enumerated() {
            guard lineIndex < colorRunsByLine.count,
                  rowIndex < rowRanges.count, rowIndex < rowTextLengths.count else { continue }
            let runs = colorRunsByLine[lineIndex]
            guard !runs.isEmpty else { continue }
            // Only the first surviving line lost indentation to the trim; every
            // later line's runs are already relative to its own start.
            let indentShift = lineIndex == 0 ? leadingIndent : 0
            let rowRange = rowRanges[rowIndex]
            let rowTextLength = rowTextLengths[rowIndex]
            for run in runs {
                let shiftedLocation = run.range.location + indentShift
                guard shiftedLocation + run.range.length <= rowTextLength else { continue }
                let target = NSRange(location: rowRange.location + shiftedLocation, length: run.range.length)
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
