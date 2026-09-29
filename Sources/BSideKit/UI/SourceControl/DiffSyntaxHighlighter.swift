import AppKit
import HighlightSwift

enum DiffSyntaxHighlighter {
    static let maxHighlightableRowCount = 5000

    struct LineColorRun: Equatable {
        let range: NSRange
        let color: NSColor
    }

    /// What `HighlightSwift` trims from the front (whitespace/newlines): dropped lines plus remaining first-line indent, to realign colour runs to rows.
    struct LeadingTrim: Equatable {
        let droppedLines: Int
        let indent: Int
    }

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
            offset += lineLength + 1
        }
        return result
    }

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
            // Only the first surviving line lost indentation to the trim; later lines' runs are already relative to their start.
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

    static func colors(isDark: Bool) -> HighlightColors {
        isDark ? .dark(.xcode) : .light(.xcode)
    }
}
