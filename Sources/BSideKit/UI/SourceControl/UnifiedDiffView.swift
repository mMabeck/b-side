import AppKit
import SwiftUI

/// Pure, side-effect-free rendering of a unified diff `String` into an
/// `NSAttributedString`, coloured from a ``BSidePalette``. No git types, no
/// view lifecycle — safe to call off the main thread and to unit test
/// directly.
enum UnifiedDiffRenderer {
    /// One `append` per line rather than per-character lookups, so a 10k+ line diff renders in well under a second.
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

    /// Order matters: file-header prefixes (`+++`/`---`) must be checked before generic `+`/`-` content checks.
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

/// Read-only, selectable text view; wraps a plain `NSTextView`, not a rich editor, since the diff is display-only.
struct DiffTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let palette: BSidePalette

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // `scrollableTextView()` wires up autoresizing, vertical resizing, and
        // a width-tracking text container; a bare `NSTextView()` stays at a
        // zero frame and never lays out any glyphs.
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() must return an NSTextView document view")
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityLabel("Diff")

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        // scrollableTextView() wraps to the container width by default; a
        // diff needs horizontal scrolling for long lines instead.
        // `maxSize` defaults to the initial viewport width, which would cap the frame and disable horizontal scrolling.
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

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
