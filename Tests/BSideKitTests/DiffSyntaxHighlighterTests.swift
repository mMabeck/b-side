import AppKit
import Testing

@testable import BSideKit

struct DiffSyntaxHighlighterTests {
    @Test("Foreground-colour runs are split per line, relative to each line's own start")
    func colorRunsSplitPerLine() {
        let text = "let a = 1\nlet b = 2"
        let attributed = NSMutableAttributedString(string: text)
        // "a" on line 0, at index 4.
        attributed.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 4, length: 1))
        // "b" on line 1, at index 4 within that line (absolute index 14).
        attributed.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 14, length: 1))

        let runsByLine = DiffSyntaxHighlighter.colorRunsByLine(in: attributed)

        #expect(runsByLine.count == 2)
        #expect(runsByLine[0] == [.init(range: NSRange(location: 4, length: 1), color: .red)])
        #expect(runsByLine[1] == [.init(range: NSRange(location: 4, length: 1), color: .blue)])
    }

    @Test("A line with no coloured runs produces an empty array, not a crash")
    func plainLineHasNoRuns() {
        let attributed = NSAttributedString(string: "plain\nalso plain")
        let runsByLine = DiffSyntaxHighlighter.colorRunsByLine(in: attributed)
        #expect(runsByLine == [[], []])
    }

    @Test("Color runs are applied onto the target row ranges in the diff's rendered attributed string")
    func applyColorRunsMapsOntoRowRanges() {
        // Two "rows" of rendered diff text, back to back: "foo" then "bar".
        let result = NSMutableAttributedString(string: "foobar")
        let rowRanges = [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3)]
        let rowTextLengths = [3, 3]
        let runsByLine: [[DiffSyntaxHighlighter.LineColorRun]] = [
            [.init(range: NSRange(location: 0, length: 3), color: .systemGreen)],
        ]

        // Side text only reconstructed row 1 ("bar"), so it's the only entry in `rowIndices`.
        DiffSyntaxHighlighter.applyColorRuns(
            runsByLine, toRowIndices: [1], rowTextLengths: rowTextLengths, rowRanges: rowRanges, in: result
        )

        #expect(result.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor == .systemGreen)
        #expect(result.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test("A run that would overflow its row's own text length is skipped, not misapplied onto the next row")
    func overflowingRunIsSkipped() {
        let result = NSMutableAttributedString(string: "foobar")
        let rowRanges = [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3)]
        // Row 0's reconstructed text was somehow shorter than the highlighted line claims.
        let rowTextLengths = [2, 3]
        let runsByLine: [[DiffSyntaxHighlighter.LineColorRun]] = [
            [.init(range: NSRange(location: 0, length: 3), color: .systemRed)],
        ]

        DiffSyntaxHighlighter.applyColorRuns(
            runsByLine, toRowIndices: [0], rowTextLengths: rowTextLengths, rowRanges: rowRanges, in: result
        )

        #expect(result.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(result.attribute(.foregroundColor, at: 3, effectiveRange: nil) == nil)
    }

    @Test("Theme colours follow the requested light/dark appearance")
    func colorsFollowAppearance() {
        #expect(DiffSyntaxHighlighter.colors(isDark: true) != DiffSyntaxHighlighter.colors(isDark: false))
    }
}
