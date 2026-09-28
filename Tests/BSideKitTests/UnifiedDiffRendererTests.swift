import AppKit
import SwiftUI
import Testing

@testable import BSideKit

/// Pure parser/renderer tests: no window, no view hierarchy, no palette resolution
/// from a live Ghostty theme.
struct UnifiedDiffRendererTests {
    private let palette = BSidePalette.fallback

    private let sampleDiff = """
    diff --git a/foo.swift b/foo.swift
    index 1234567..89abcde 100644
    --- a/foo.swift
    +++ b/foo.swift
    @@ -1,3 +1,3 @@
     let unchanged = 1
    -let removed = 2
    +let added = 2
    @@ -10,2 +10,3 @@ func bar() {
     let tail = 1
    +let inserted = 2
     let last = 3
    """

    @Test("Parsing produces the right row kind and old/new line numbers across two hunks", arguments: [
        (rowIndex: 0, kind: UnifiedDiffRenderer.RowKind.context, old: 1, new: 1, text: "let unchanged = 1"),
        (rowIndex: 1, kind: UnifiedDiffRenderer.RowKind.removed, old: 2, new: nil, text: "let removed = 2"),
        (rowIndex: 2, kind: UnifiedDiffRenderer.RowKind.added, old: nil, new: 2, text: "let added = 2"),
        (rowIndex: 3, kind: UnifiedDiffRenderer.RowKind.separator, old: nil, new: nil, text: "⋯ func bar() {"),
        (rowIndex: 4, kind: UnifiedDiffRenderer.RowKind.context, old: 10, new: 10, text: "let tail = 1"),
        (rowIndex: 5, kind: UnifiedDiffRenderer.RowKind.added, old: nil, new: 11, text: "let inserted = 2"),
        (rowIndex: 6, kind: UnifiedDiffRenderer.RowKind.context, old: 11, new: 12, text: "let last = 3"),
    ])
    private func parsedRow(rowIndex: Int, kind: UnifiedDiffRenderer.RowKind, old: Int?, new: Int?, text: String) {
        let rows = UnifiedDiffRenderer.parse(sampleDiff)
        #expect(rows.count == 7)
        let row = rows[rowIndex]
        #expect(row.kind == kind)
        #expect(row.oldLineNumber == old)
        #expect(row.newLineNumber == new)
        #expect(row.text == text)
    }

    @Test("A 10k-line diff renders under a reasonable time bound")
    func largeDiffRendersQuickly() {
        var lines: [String] = ["diff --git a/big.txt b/big.txt", "--- a/big.txt", "+++ b/big.txt", "@@ -1,10000 +1,10000 @@"]
        for i in 0..<10_000 {
            switch i % 3 {
            case 0: lines.append("+added line \(i)")
            case 1: lines.append("-removed line \(i)")
            default: lines.append(" context line \(i)")
            }
        }
        let bigDiff = lines.joined(separator: "\n")

        let start = Date()
        let attributed = UnifiedDiffRenderer.render(bigDiff, palette: palette)
        let elapsed = Date().timeIntervalSince(start)

        #expect(attributed.length > 0)
        #expect(elapsed < 2.0)
    }
}

@MainActor
struct DiffTextViewLayoutTests {
    private func makeHostedWindow(diff: String) -> NSWindow {
        let palette = BSidePalette.fallback
        let attributed = UnifiedDiffRenderer.render(diff, palette: palette)
        let representable = DiffTextView(attributedText: attributed, palette: palette)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: representable.frame(width: 600, height: 400))
        window.setIsVisible(true)
        return window
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    @Test("DiffTextView lays out glyphs and scrolls horizontally instead of wrapping long lines")
    func diffTextViewLaysOutAndScrollsHorizontally() async throws {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,1 +1,1 @@
        -let removed = 2
        +let added = 2
        """ + "\n+" + String(repeating: "x", count: 500)
        let window = makeHostedWindow(diff: diff)
        defer { window.orderOut(nil) }

        var scrollView: NSScrollView?
        try await waitUntil {
            scrollView = window.contentView.flatMap { self.firstScrollView(in: $0) }
            return scrollView != nil
        }
        let textView = try #require(scrollView?.documentView as? NSTextView)
        let viewportWidth = try #require(scrollView).contentView.bounds.width
        try await waitUntil { textView.frame.width > viewportWidth && textView.frame.height > 0 }
        #expect(textView.frame.width > viewportWidth)
        #expect(textView.frame.height > 0)

        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        #expect(usedRect.width > 0)
        #expect(usedRect.height > 0)
    }
}
