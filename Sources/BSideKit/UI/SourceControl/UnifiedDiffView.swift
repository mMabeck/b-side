import AppKit
import SwiftUI

/// Pure, side-effect-free parsing and rendering of a unified diff `String`
/// into an `NSAttributedString`, coloured from a ``BSidePalette``. No git
/// types, no view lifecycle — safe to call off the main thread and to unit
/// test directly.
enum UnifiedDiffRenderer {
    enum RowKind: Equatable {
        case context
        case added
        case removed
        /// Replaces a `@@` hunk header in the rendered output.
        case separator
    }

    /// One parsed diff line. `text` never carries the leading `+`/`-`/space
    /// marker or any git metadata — those are either dropped or drawn in the gutter.
    struct Row: Equatable {
        let kind: RowKind
        let oldLineNumber: Int?
        let newLineNumber: Int?
        let text: String
    }

    /// Gutter data attached to each rendered context/added/removed line via
    /// ``NSAttributedString/Key/diffLineInfo``, read back by
    /// `DiffGutterView` at draw time. Kept out of the visible text so
    /// copying a selection never includes line numbers or markers.
    struct DiffLineGutterInfo: Hashable {
        enum Kind: Hashable { case context, added, removed }
        let kind: Kind
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

    /// Splits a unified diff into rows, dropping git metadata lines (`diff
    /// --git`, `index`, `---`/`+++`, mode/similarity/rename lines) and
    /// `\ No newline at end of file` markers, and replacing each `@@` hunk
    /// header with a `.separator` row. No separator precedes a first hunk
    /// that starts at the beginning of the file.
    static func parse(_ diff: String) -> [Row] {
        var rows: [Row] = []
        var oldLine = 0
        var newLine = 0
        var isFirstHunk = true

        diff.enumerateLines { line, _ in
            if isMetadataLine(line) { return }
            if line.hasPrefix("\\ No newline") { return }

            if line.hasPrefix("@@") {
                guard let hunk = parseHunkHeader(line) else { return }
                oldLine = hunk.oldStart
                newLine = hunk.newStart
                let isFileStart = isFirstHunk && hunk.oldStart <= 1 && hunk.newStart <= 1
                if !isFileStart {
                    let label = hunk.trailingContext.isEmpty ? "⋯" : "⋯ \(hunk.trailingContext)"
                    rows.append(Row(kind: .separator, oldLineNumber: nil, newLineNumber: nil, text: label))
                }
                isFirstHunk = false
                return
            }

            switch line.first {
            case "+":
                rows.append(Row(kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            case "-":
                rows.append(Row(kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            case " ":
                rows.append(Row(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            default:
                // Outside any recognised hunk (e.g. a stray blank line): show it verbatim as context.
                rows.append(Row(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: line))
                oldLine += 1
                newLine += 1
            }
        }

        return rows
    }

    /// One `append` per row rather than per-character lookups, so a 10k+ line diff renders in well under a second.
    static func render(_ diff: String, palette: BSidePalette) -> NSAttributedString {
        let rows = parse(diff)
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let separatorFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let addedBackground = NSColor(palette.statusSuccess).withAlphaComponent(0.14)
        let removedBackground = NSColor(palette.statusError).withAlphaComponent(0.14)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }

            switch row.kind {
            case .separator:
                result.append(NSAttributedString(string: row.text, attributes: [
                    .font: separatorFont,
                    .foregroundColor: NSColor(palette.textDisabled),
                ]))
            case .context, .added, .removed:
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(palette.textPrimary),
                    .diffLineInfo: DiffLineGutterInfo(
                        kind: gutterKind(for: row.kind),
                        oldLineNumber: row.oldLineNumber,
                        newLineNumber: row.newLineNumber
                    ),
                ]
                switch row.kind {
                case .added: attributes[.diffRowBackground] = addedBackground
                case .removed: attributes[.diffRowBackground] = removedBackground
                case .context: break
                case .separator: break
                }
                // A truly empty line needs one character to carry the gutter/background
                // attributes; a space renders indistinguishably from blank.
                let text = row.text.isEmpty ? " " : row.text
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
        }

        return result
    }

    /// Counts additions/deletions by scanning the rendered attributed string, so
    /// `DiffTextView` can build a VoiceOver-reachable summary without re-parsing the diff.
    static func changeCounts(in attributed: NSAttributedString) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        attributed.enumerateAttribute(.diffLineInfo, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let info = value as? DiffLineGutterInfo else { return }
            switch info.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .context: break
            }
        }
        return (added, removed)
    }

    private static func gutterKind(for rowKind: RowKind) -> DiffLineGutterInfo.Kind {
        switch rowKind {
        case .added: return .added
        case .removed: return .removed
        case .context, .separator: return .context
        }
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode")
            || line.hasPrefix("similarity index") || line.hasPrefix("dissimilarity index")
            || line.hasPrefix("rename from") || line.hasPrefix("rename to")
            || line.hasPrefix("copy from") || line.hasPrefix("copy to")
            || line.hasPrefix("Binary files")
    }

    private struct HunkHeader {
        let oldStart: Int
        let newStart: Int
        let trailingContext: String
    }

    private static let hunkHeaderRegex = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@ ?(.*)$"#
    )

    private static func parseHunkHeader(_ line: String) -> HunkHeader? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = hunkHeaderRegex.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard let stringRange = Range(match.range(at: index), in: line) else { return nil }
            return String(line[stringRange])
        }
        guard let oldString = group(1), let newString = group(2),
              let oldStart = Int(oldString), let newStart = Int(newString) else { return nil }
        return HunkHeader(oldStart: oldStart, newStart: newStart, trailingContext: group(3) ?? "")
    }
}

extension NSAttributedString.Key {
    /// Carries ``UnifiedDiffRenderer/DiffLineGutterInfo`` for a rendered line; read by `DiffGutterView`.
    static let diffLineInfo = NSAttributedString.Key("BSideDiffLineInfo")
    /// A full-row tint colour for added/removed lines; read by `DiffRowBackgroundLayoutManager`.
    static let diffRowBackground = NSAttributedString.Key("BSideDiffRowBackground")
}

/// Fills full-width row backgrounds for added/removed lines, sized to the
/// text view's own width so the tint reaches the visible edge even for short
/// lines and while scrolled horizontally. Forces TextKit 1 (built directly
/// from `NSLayoutManager`/`NSTextContainer` rather than `NSTextView(usingTextLayoutManager:)`)
/// since TextKit 2 doesn't expose per-line background drawing this way.
private final class DiffRowBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Drawing always happens on the main thread; NSLayoutManager's own
        // override point isn't main-actor-isolated, so this bridges to read `textView.bounds`.
        if let textContainer = textContainers.first,
           let textView = textContainer.textView,
           let textStorage {
            let fullWidth = MainActor.assumeIsolated { textView.bounds.width }
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
                let charIndex = self.characterIndexForGlyph(at: glyphRange.location)
                guard charIndex < textStorage.length,
                      let color = textStorage.attribute(.diffRowBackground, at: charIndex, effectiveRange: nil) as? NSColor else {
                    return
                }
                let fillRect = NSRect(
                    x: 0,
                    y: rect.minY + origin.y,
                    width: max(fullWidth, rect.maxX + origin.x),
                    height: rect.height
                )
                color.setFill()
                fillRect.fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Fixed-width line-number gutter drawn outside the text storage, so
/// selecting/copying diff text never includes line numbers or +/- markers.
/// A plain `NSView` pinned to the scroll view itself (not the scrolling
/// clip/document view), with the text content inset out of its way by
/// `DiffScrollView`: stays put when the text view scrolls horizontally, and
/// repaints on vertical scroll via a bounds-changed notification on the clip
/// view (an `NSRulerView` would do this automatically, but its automatic
/// content-area accommodation wasn't reliably reserving space here, so this needs the notification wiring by hand).
private final class DiffGutterView: NSView {
    weak var diffTextView: NSTextView?
    private weak var scrollView: NSScrollView?
    var palette: BSidePalette = .fallback {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private static let horizontalPadding: CGFloat = 8
    private static let columnGap: CGFloat = 5
    private static let digitColumnWidth: CGFloat = {
        ("00000" as NSString).size(withAttributes: [.font: font]).width
    }()
    private static let markerColumnWidth: CGFloat = {
        ("\u{2212}" as NSString).size(withAttributes: [.font: font]).width
    }()

    static var preferredWidth: CGFloat {
        horizontalPadding * 2 + columnGap * 2 + digitColumnWidth * 2 + markerColumnWidth
    }

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        diffTextView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollPositionDidChange),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollPositionDidChange() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = diffTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage,
              let scrollView else { return }

        NSColor(palette.surfaceBackground).setFill()
        bounds.fill()

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor(palette.textDisabled),
        ]

        let oldColumnMaxX = Self.horizontalPadding + Self.digitColumnWidth
        let newColumnMaxX = oldColumnMaxX + Self.columnGap + Self.digitColumnWidth
        let markerColumnMaxX = newColumnMaxX + Self.columnGap + Self.markerColumnWidth

        func drawRightAligned(_ string: String, maxX: CGFloat, lineOriginY: CGFloat, lineHeight: CGFloat) {
            guard !string.isEmpty else { return }
            let size = (string as NSString).size(withAttributes: attributes)
            let point = NSPoint(x: maxX - size.width, y: lineOriginY + (lineHeight - size.height) / 2)
            (string as NSString).draw(at: point, withAttributes: attributes)
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            guard charIndex < textStorage.length,
                  let info = textStorage.attribute(.diffLineInfo, at: charIndex, effectiveRange: nil)
                    as? UnifiedDiffRenderer.DiffLineGutterInfo else { return }

            let lineOriginInTextView = NSPoint(x: 0, y: fragmentRect.minY + textView.textContainerInset.height)
            let lineOriginInGutter = self.convert(lineOriginInTextView, from: textView)

            if let old = info.oldLineNumber {
                drawRightAligned(String(old), maxX: oldColumnMaxX, lineOriginY: lineOriginInGutter.y, lineHeight: fragmentRect.height)
            }
            if let new = info.newLineNumber {
                drawRightAligned(String(new), maxX: newColumnMaxX, lineOriginY: lineOriginInGutter.y, lineHeight: fragmentRect.height)
            }
            let marker: String
            switch info.kind {
            case .added: marker = "+"
            case .removed: marker = "\u{2212}"
            case .context: marker = ""
            }
            drawRightAligned(marker, maxX: markerColumnMaxX, lineOriginY: lineOriginInGutter.y, lineHeight: fragmentRect.height)
        }
    }
}

/// Reserves `gutterLeftInset` of its own width for `DiffGutterView`, shrinking the
/// clip view accordingly. `NSScrollView.contentInsets` looked like the built-in way
/// to do this, but didn't move the clip view's frame in practice here, so `tile()` does it by hand.
final class DiffScrollView: NSScrollView {
    var gutterLeftInset: CGFloat = 0

    override func tile() {
        super.tile()
        guard gutterLeftInset > 0 else { return }
        var clipFrame = contentView.frame
        clipFrame.origin.x = gutterLeftInset
        clipFrame.size.width = max(0, bounds.width - gutterLeftInset)
        contentView.frame = clipFrame
    }
}

/// Read-only, selectable text view; wraps a plain `NSTextView`, not a rich editor, since the diff is display-only.
struct DiffTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let palette: BSidePalette

    func makeNSView(context: Context) -> DiffScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = DiffRowBackgroundLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        // A diff needs horizontal scrolling for long lines instead of wrapping.
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // `maxSize` defaults to the initial viewport width, which would cap the frame and disable horizontal scrolling.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []

        let scrollView = DiffScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        // The gutter is a plain sibling view pinned to the scroll view, not the
        // scrolling clip/document view, so it never moves horizontally; `DiffScrollView.tile()`
        // reserves the matching space in the scrollable content area.
        let gutterWidth = DiffGutterView.preferredWidth
        scrollView.gutterLeftInset = gutterWidth
        let gutter = DiffGutterView(textView: textView, scrollView: scrollView)
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: scrollView.bounds.height)
        gutter.autoresizingMask = [.height]
        scrollView.addSubview(gutter)
        scrollView.tile()

        apply(palette: palette, to: textView, scrollView: scrollView, gutter: gutter)
        textView.textStorage?.setAttributedString(attributedText)
        updateAccessibilityLabel(textView: textView)
        scrollToStart(scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: DiffScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let gutter = scrollView.subviews.compactMap { $0 as? DiffGutterView }.first
        apply(palette: palette, to: textView, scrollView: scrollView, gutter: gutter)
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
            updateAccessibilityLabel(textView: textView)
            gutter?.needsDisplay = true
            scrollToStart(scrollView)
        }
    }

    /// NSTextView's frame can grow wider than the clip view once layout runs for a horizontally
    /// scrollable document, which otherwise leaves the initial scroll position mid-document instead
    /// of at the start; deferred a runloop turn so it applies after that layout pass.
    private func scrollToStart(_ scrollView: DiffScrollView) {
        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func apply(palette: BSidePalette, to textView: NSTextView, scrollView: DiffScrollView, gutter: DiffGutterView?) {
        let background = NSColor(palette.windowBackground)
        textView.backgroundColor = background
        textView.textColor = NSColor(palette.textPrimary)
        textView.insertionPointColor = NSColor(palette.textPrimary)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(palette.selectionBackground),
            .foregroundColor: NSColor(palette.selectionForeground),
        ]
        scrollView.backgroundColor = background
        gutter?.palette = palette
    }

    private func updateAccessibilityLabel(textView: NSTextView) {
        let (added, removed) = UnifiedDiffRenderer.changeCounts(in: attributedText)
        guard added > 0 || removed > 0 else {
            textView.setAccessibilityLabel("Diff")
            return
        }
        textView.setAccessibilityLabel(
            "Diff, \(added) addition\(added == 1 ? "" : "s"), \(removed) deletion\(removed == 1 ? "" : "s")"
        )
    }
}
