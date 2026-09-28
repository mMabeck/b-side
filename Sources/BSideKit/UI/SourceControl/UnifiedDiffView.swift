import AppKit
import HighlightSwift
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
    struct Row {
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
        var oldRemaining = 0
        var newRemaining = 0
        var isFirstHunk = true

        diff.enumerateLines { line, _ in
            // Git places this marker inside a hunk, between a changed last line's -/+ pair.
            if line.hasPrefix("\\ No newline") { return }
            let inHunk = oldRemaining > 0 || newRemaining > 0

            // Metadata and hunk headers only mean what they look like between hunks;
            // a removed/added line's content can itself start with "--- "/"+++ ".
            if !inHunk {
                if isMetadataLine(line) { return }

                if line.hasPrefix("@@") {
                    guard let hunk = parseHunkHeader(line) else {
                        rows.append(Row(kind: .separator, oldLineNumber: nil, newLineNumber: nil, text: "⋯"))
                        isFirstHunk = false
                        return
                    }
                    oldLine = hunk.oldStart
                    newLine = hunk.newStart
                    oldRemaining = hunk.oldCount
                    newRemaining = hunk.newCount
                    let isFileStart = isFirstHunk && hunk.oldStart <= 1 && hunk.newStart <= 1
                    if !isFileStart {
                        let label = hunk.trailingContext.isEmpty ? "⋯" : "⋯ \(hunk.trailingContext)"
                        rows.append(Row(kind: .separator, oldLineNumber: nil, newLineNumber: nil, text: label))
                    }
                    isFirstHunk = false
                    return
                }

                // Outside any recognised hunk and not metadata/a header: nothing to render.
                return
            }

            switch line.first {
            case "+":
                rows.append(Row(kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
                newRemaining = max(0, newRemaining - 1)
            case "-":
                rows.append(Row(kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
                oldRemaining = max(0, oldRemaining - 1)
            case " ":
                rows.append(Row(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
                oldRemaining = max(0, oldRemaining - 1)
                newRemaining = max(0, newRemaining - 1)
            default:
                // A stray line inside a hunk with no marker: show it verbatim as context.
                rows.append(Row(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: line))
                oldLine += 1
                newLine += 1
                oldRemaining = max(0, oldRemaining - 1)
                newRemaining = max(0, newRemaining - 1)
            }
        }

        return rows
    }

    /// One `append` per row rather than per-character lookups, so a 10k+ line diff renders in well under a second.
    static func render(_ diff: String, palette: BSidePalette) -> NSAttributedString {
        renderRows(parse(diff), palette: palette).attributed
    }

    /// Font used for diff body text; shared with the syntax highlighter so highlighted
    /// runs are measured against the same metrics the base render used.
    static var bodyFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

    /// Same as ``render(_:palette:)`` but also returns each row's character range in
    /// the result, so callers (the syntax highlighter) can overlay colours onto exactly
    /// the right span without re-deriving row boundaries.
    static func renderRows(_ rows: [Row], palette: BSidePalette) -> (attributed: NSMutableAttributedString, rowRanges: [NSRange]) {
        let result = NSMutableAttributedString()
        var rowRanges: [NSRange] = []
        let font = bodyFont
        let separatorFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let addedBackground = NSColor(palette.statusSuccess).withAlphaComponent(0.14)
        let removedBackground = NSColor(palette.statusError).withAlphaComponent(0.14)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            let startLocation = result.length

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
                case .context, .separator: break
                }
                // A truly empty line needs one character to carry the gutter/background
                // attributes; a space renders indistinguishably from blank.
                let text = row.text.isEmpty ? " " : row.text
                result.append(NSAttributedString(string: text, attributes: attributes))
            }

            rowRanges.append(NSRange(location: startLocation, length: result.length - startLocation))
        }

        return (result, rowRanges)
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

    /// Digit-width of the largest old/new line number, `0` when a side never appears
    /// (an added or deleted file), so the gutter can collapse that column entirely.
    struct GutterMetrics: Equatable {
        let oldDigitCount: Int
        let newDigitCount: Int
    }

    static func gutterMetrics(for rows: [Row]) -> GutterMetrics {
        var maxOld = 0
        var maxNew = 0
        for row in rows {
            if let old = row.oldLineNumber { maxOld = max(maxOld, old) }
            if let new = row.newLineNumber { maxNew = max(maxNew, new) }
        }
        return GutterMetrics(
            oldDigitCount: maxOld > 0 ? String(maxOld).count : 0,
            newDigitCount: maxNew > 0 ? String(maxNew).count : 0
        )
    }

    /// Same as ``gutterMetrics(for:)`` but reads back from a rendered attributed
    /// string, for callers (the gutter view) that only see the final text.
    static func gutterMetrics(in attributed: NSAttributedString) -> GutterMetrics {
        var maxOld = 0
        var maxNew = 0
        attributed.enumerateAttribute(.diffLineInfo, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let info = value as? DiffLineGutterInfo else { return }
            if let old = info.oldLineNumber { maxOld = max(maxOld, old) }
            if let new = info.newLineNumber { maxNew = max(maxNew, new) }
        }
        return GutterMetrics(
            oldDigitCount: maxOld > 0 ? String(maxOld).count : 0,
            newDigitCount: maxNew > 0 ? String(maxNew).count : 0
        )
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
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let trailingContext: String
    }

    private static let hunkHeaderRegex = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$"#
    )

    private static func parseHunkHeader(_ line: String) -> HunkHeader? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = hunkHeaderRegex.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            guard let stringRange = Range(match.range(at: index), in: line) else { return nil }
            return String(line[stringRange])
        }
        guard let oldString = group(1), let newString = group(3),
              let oldStart = Int(oldString), let newStart = Int(newString) else { return nil }
        // A hunk header's count is omitted when it's 1 (e.g. `@@ -5 +5,2 @@`).
        let oldCount = group(2).flatMap(Int.init) ?? 1
        let newCount = group(4).flatMap(Int.init) ?? 1
        return HunkHeader(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, trailingContext: group(5) ?? "")
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

/// Line-number gutter drawn outside the text storage so copies exclude numbers
/// and markers. Pinned to the scroll view, not the clip view, so it never
/// scrolls horizontally; repaints on the clip view's bounds changes.
private final class DiffGutterView: NSView {
    weak var diffTextView: NSTextView?
    private weak var scrollView: DiffScrollView?
    var palette: BSidePalette = .fallback {
        didSet { needsDisplay = true }
    }

    /// Set whenever the diff text changes; a collapsed (all-zero) side omits that
    /// column entirely instead of reserving empty space for it.
    var metrics: UnifiedDiffRenderer.GutterMetrics = UnifiedDiffRenderer.GutterMetrics(oldDigitCount: 0, newDigitCount: 0) {
        didSet {
            guard metrics != oldValue else { return }
            scrollView?.gutterLeftInset = preferredWidth
            scrollView?.tile()
            needsDisplay = true
        }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let horizontalPadding: CGFloat = 8
    private static let columnGap: CGFloat = 4
    private static let markerColumnWidth: CGFloat = {
        ("\u{2212}" as NSString).size(withAttributes: [.font: font]).width
    }()

    private func digitColumnWidth(_ digitCount: Int) -> CGFloat {
        guard digitCount > 0 else { return 0 }
        return (String(repeating: "0", count: digitCount) as NSString).size(withAttributes: [.font: Self.font]).width
    }

    /// Layout in drawing order: left padding, old column (if any), gap, new column
    /// (if any), gap, marker column, right padding into the code.
    private var columnMaxXs: (old: CGFloat?, new: CGFloat?, marker: CGFloat) {
        var x = Self.horizontalPadding
        var oldMaxX: CGFloat?
        var newMaxX: CGFloat?
        if metrics.oldDigitCount > 0 {
            x += digitColumnWidth(metrics.oldDigitCount)
            oldMaxX = x
        }
        if metrics.newDigitCount > 0 {
            if oldMaxX != nil { x += Self.columnGap }
            x += digitColumnWidth(metrics.newDigitCount)
            newMaxX = x
        }
        if oldMaxX != nil || newMaxX != nil { x += Self.columnGap }
        let markerMaxX = x + Self.markerColumnWidth
        return (oldMaxX, newMaxX, markerMaxX)
    }

    var preferredWidth: CGFloat {
        columnMaxXs.marker + Self.horizontalPadding
    }

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: DiffScrollView) {
        diffTextView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        // Line numbers/markers are exposed to VoiceOver via a rotor on the text view instead.
        setAccessibilityElement(false)
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

        var visibleRect = scrollView.contentView.bounds
        visibleRect.origin.x -= textView.textContainerOrigin.x
        visibleRect.origin.y -= textView.textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor(palette.textDisabled),
        ]

        let (oldColumnMaxX, newColumnMaxX, markerColumnMaxX) = columnMaxXs

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

            if let old = info.oldLineNumber, let oldColumnMaxX {
                drawRightAligned(String(old), maxX: oldColumnMaxX, lineOriginY: lineOriginInGutter.y, lineHeight: fragmentRect.height)
            }
            if let new = info.newLineNumber, let newColumnMaxX {
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
    weak var gutterView: NSView?
    /// Keeps `NSAccessibilityCustomRotor.itemSearchDelegate` (a weak reference) alive.
    var rotorSearchDelegates: [NSObject] = []

    override func tile() {
        super.tile()
        guard gutterLeftInset > 0 else { return }
        let width = gutterLeftInset.rounded()
        var clipFrame = contentView.frame
        clipFrame.origin.x = width
        clipFrame.size.width = max(0, bounds.width - width)
        contentView.frame = clipFrame
        gutterView?.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}

/// Backs a VoiceOver rotor ("Added lines"/"Removed lines") by walking `.diffLineInfo`
/// runs in the text storage on demand — the +/- markers only live in the gutter, which
/// is itself hidden from accessibility, so this is how VoiceOver tells the kinds apart.
@MainActor
private final class DiffLineKindRotorDelegate: NSObject, @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    private weak var textView: NSTextView?
    private let kind: UnifiedDiffRenderer.DiffLineGutterInfo.Kind

    init(textView: NSTextView, kind: UnifiedDiffRenderer.DiffLineGutterInfo.Kind) {
        self.textView = textView
        self.kind = kind
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let textView, let textStorage = textView.textStorage else { return nil }
        let length = textStorage.length
        guard length > 0 else { return nil }

        let forward = searchParameters.searchDirection == .next
        var index: Int
        if let currentRange = searchParameters.currentItem?.targetRange, currentRange.location != NSNotFound {
            index = forward ? NSMaxRange(currentRange) : currentRange.location - 1
        } else {
            index = forward ? 0 : length - 1
        }

        while index >= 0, index < length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let info = textStorage.attribute(.diffLineInfo, at: index, effectiveRange: &effectiveRange)
                as? UnifiedDiffRenderer.DiffLineGutterInfo
            if info?.kind == kind {
                let result = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
                result.targetRange = effectiveRange
                return result
            }
            index = forward ? NSMaxRange(effectiveRange) : effectiveRange.location - 1
        }
        return nil
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
        textView.textContainerInset = NSSize(width: 6, height: 8)
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

        let gutter = DiffGutterView(textView: textView, scrollView: scrollView)
        gutter.metrics = UnifiedDiffRenderer.gutterMetrics(in: attributedText)
        scrollView.gutterLeftInset = gutter.preferredWidth
        scrollView.gutterView = gutter
        scrollView.addSubview(gutter)
        scrollView.tile()

        let addedDelegate = DiffLineKindRotorDelegate(textView: textView, kind: .added)
        let removedDelegate = DiffLineKindRotorDelegate(textView: textView, kind: .removed)
        scrollView.rotorSearchDelegates = [addedDelegate, removedDelegate]
        textView.setAccessibilityCustomRotors([
            NSAccessibilityCustomRotor(label: "Added lines", itemSearchDelegate: addedDelegate),
            NSAccessibilityCustomRotor(label: "Removed lines", itemSearchDelegate: removedDelegate),
        ])

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
            gutter?.metrics = UnifiedDiffRenderer.gutterMetrics(in: attributedText)
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

/// Renders a unified diff, showing the plain (uncoloured) result immediately and
/// layering in `HighlightSwift` token colours once ready. Reconstructs the old and
/// new side of the diff from the parsed rows and highlights each independently so
/// multi-line constructs (docstrings, block comments) colour correctly even where a
/// hunk boundary would otherwise cut them off. Highlighting runs off the main thread
/// via `Task`; SwiftUI's `.task(id:)` cancels a stale pass when the selected file
/// (or diff text, or the palette's light/dark theme) changes.
struct DiffPaneView: View {
    let diffText: String
    let filePath: String
    let palette: BSidePalette

    @State private var displayed = NSAttributedString()

    private struct RenderKey: Equatable {
        let filePath: String
        let diffText: String
        let isDark: Bool
    }

    private static let highlighter = Highlight()

    var body: some View {
        DiffTextView(attributedText: displayed, palette: palette)
            .task(id: RenderKey(filePath: filePath, diffText: diffText, isDark: palette.isDark)) {
                await render()
            }
    }

    private func render() async {
        let rows = UnifiedDiffRenderer.parse(diffText)
        let (plain, rowRanges) = UnifiedDiffRenderer.renderRows(rows, palette: palette)
        displayed = plain
        guard rows.count <= DiffSyntaxHighlighter.maxHighlightableRowCount else { return }

        let oldRowIndices = rows.indices.filter { rows[$0].oldLineNumber != nil }
        let newRowIndices = rows.indices.filter { rows[$0].newLineNumber != nil }
        guard !oldRowIndices.isEmpty || !newRowIndices.isEmpty else { return }

        let oldText = oldRowIndices.map { rows[$0].text }.joined(separator: "\n")
        let newText = newRowIndices.map { rows[$0].text }.joined(separator: "\n")
        let mode: HighlightMode = DiffLanguageDetector.language(forPath: filePath).map { .languageIgnoreIllegal($0) } ?? .automatic
        let colors = DiffSyntaxHighlighter.colors(isDark: palette.isDark)

        // Sequential, not `async let`: both calls funnel through the same `HLJS`
        // actor anyway, and returning `NSAttributedString` (non-Sendable) across a
        // concurrent child task's boundary isn't allowed under strict concurrency.
        let old = await Self.highlight(oldText, mode: mode, colors: colors)
        guard !Task.isCancelled else { return }
        let new = await Self.highlight(newText, mode: mode, colors: colors)
        guard !Task.isCancelled else { return }

        let rowTextLengths = rows.map { ($0.text as NSString).length }
        let colored = NSMutableAttributedString(attributedString: plain)
        if let old {
            DiffSyntaxHighlighter.applyColorRuns(
                DiffSyntaxHighlighter.colorRunsByLine(in: old),
                toRowIndices: oldRowIndices, rowTextLengths: rowTextLengths, rowRanges: rowRanges, in: colored
            )
        }
        if let new {
            DiffSyntaxHighlighter.applyColorRuns(
                DiffSyntaxHighlighter.colorRunsByLine(in: new),
                toRowIndices: newRowIndices, rowTextLengths: rowTextLengths, rowRanges: rowRanges, in: colored
            )
        }
        guard !Task.isCancelled else { return }
        displayed = colored
    }

    private static func highlight(_ text: String, mode: HighlightMode, colors: HighlightColors) async -> NSAttributedString? {
        guard !text.isEmpty else { return nil }
        guard let result = try? await highlighter.request(text, mode: mode, colors: colors) else { return nil }
        return NSAttributedString(result.attributedText)
    }
}
