import AppKit
import SwiftUI

/// Pure, side-effect-free rendering of a unified diff `String` into an
/// `NSAttributedString`, coloured from a ``BSidePalette``. No git types, no
/// view lifecycle — safe to call off the main thread and to unit test
/// directly.
enum UnifiedDiffRenderer {
    /// Renders `diff` line by line, colouring hunk headers (`@@ ... @@`),
    /// added (`+`) and removed (`-`) lines, and dimming file header lines
    /// (`diff --git`, `index`, `---`, `+++`). Everything else (context
    /// lines) uses the palette's primary text colour.
    ///
    /// Built with a single mutable `NSMutableAttributedString` and one
    /// `append` per line rather than per-character attribute lookups, so a
    /// 10k+ line diff renders in well under a second.
    static func render(_ diff: String, palette: BSidePalette) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var isFirstLine = true

        diff.enumerateLines { line, _ in
            if !isFirstLine {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            isFirstLine = false

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(color(for: line, palette: palette)),
            ]
            result.append(NSAttributedString(string: line, attributes: attributes))
        }

        return result
    }

    /// Classifies a single diff line and picks its colour. Order matters:
    /// the file-header prefixes (`+++`/`---`) must be checked before the
    /// generic `+`/`-` line-content checks, or every added/removed-file
    /// header would be miscoloured as a content line.
    private static func color(for line: String, palette: BSidePalette) -> Color {
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename from")
            || line.hasPrefix("rename to") {
            return palette.textDisabled
        }
        if line.hasPrefix("@@") {
            return palette.accent
        }
        if line.hasPrefix("+") {
            return palette.statusSuccess
        }
        if line.hasPrefix("-") {
            return palette.statusError
        }
        return palette.textPrimary
    }
}

/// Read-only, selectable text view hosting a rendered diff, themed from a
/// ``BSidePalette``. Wraps a plain `NSTextView` in an `NSScrollView` rather
/// than a rich editor — the diff is display-only.
struct DiffTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let palette: BSidePalette

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityLabel("Diff")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        apply(palette: palette, to: textView, scrollView: scrollView)
        textView.textStorage?.setAttributedString(attributedText)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        apply(palette: palette, to: textView, scrollView: scrollView)
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }

    private func apply(palette: BSidePalette, to textView: NSTextView, scrollView: NSScrollView) {
        let background = NSColor(palette.windowBackground)
        textView.backgroundColor = background
        textView.textColor = NSColor(palette.textPrimary)
        textView.insertionPointColor = NSColor(palette.textPrimary)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(palette.selectionBackground),
            .foregroundColor: NSColor(palette.selectionForeground),
        ]
        scrollView.backgroundColor = background
    }
}
