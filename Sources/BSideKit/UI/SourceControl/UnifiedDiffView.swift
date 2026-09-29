import AppKit
import HighlightSwift
import SwiftUI

enum UnifiedDiffRenderer {
    enum RowKind: Equatable {
        case context
        case added
        case removed
        case separator
    }

    struct Row {
        let kind: RowKind
        let oldLineNumber: Int?
        let newLineNumber: Int?
        let text: String
    }

    /// Kept out of the visible text so copying never includes line numbers or markers.
    struct DiffLineGutterInfo: Hashable {
        enum Kind: Hashable { case context, added, removed }
        let kind: Kind
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

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

            // Metadata and hunk headers only apply between hunks; a removed/added line can itself start with "--- "/"+++ ".
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
                rows.append(Row(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: line))
                oldLine += 1
                newLine += 1
                oldRemaining = max(0, oldRemaining - 1)
                newRemaining = max(0, newRemaining - 1)
            }
        }

        return rows
    }

    static func render(_ diff: String, palette: BSidePalette) -> NSAttributedString {
        renderRows(parse(diff), palette: palette).attributed
    }

    /// Shared with the highlighter so runs are measured against the same metrics.
    static var bodyFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

    static func renderRows(_ rows: [Row], palette: BSidePalette) -> (attributed: NSMutableAttributedString, rowRanges: [NSRange]) {
        let result = NSMutableAttributedString()
        var rowRanges: [NSRange] = []
        let font = bodyFont
        let separatorFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let addedBackground = NSColor(palette.statusSuccess).withAlphaComponent(0.08)
        let removedBackground = NSColor(palette.statusError).withAlphaComponent(0.08)
        let addedWord = NSColor(palette.statusSuccess).withAlphaComponent(0.32)
        let removedWord = NSColor(palette.statusError).withAlphaComponent(0.32)

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
                // A truly empty line needs one character to carry the gutter/background attributes; a space renders as blank.
                let text = row.text.isEmpty ? " " : row.text
                result.append(NSAttributedString(string: text, attributes: attributes))
            }

            rowRanges.append(NSRange(location: startLocation, length: result.length - startLocation))
        }

        for pair in DiffWordHighlights.pairs(in: rows) {
            guard let highlights = DiffWordHighlights.highlights(old: rows[pair.removed].text, new: rows[pair.added].text) else { continue }
            for (ranges, rowIndex, color) in [(highlights.old, pair.removed, removedWord), (highlights.new, pair.added, addedWord)] {
                let rowRange = rowRanges[rowIndex]
                for range in ranges where NSMaxRange(range) <= rowRange.length {
                    result.addAttribute(.backgroundColor, value: color, range: NSRange(location: rowRange.location + range.location, length: range.length))
                }
            }
        }

        return (result, rowRanges)
    }

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
    static let diffLineInfo = NSAttributedString.Key("BSideDiffLineInfo")
    static let diffRowBackground = NSAttributedString.Key("BSideDiffRowBackground")
}

/// Forces TextKit 1 (`NSLayoutManager`/`NSTextContainer` built directly): TextKit 2 doesn't expose per-line background drawing.
private final class DiffRowBackgroundLayoutManager: NSLayoutManager {
    var focusedRange: NSRange?
    var focusColor: NSColor = .clear

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Drawing is always on the main thread, but NSLayoutManager's override point isn't main-actor-isolated; this bridges to read `textView.bounds`.
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
            drawFocusOutline(width: fullWidth, origin: origin, textLength: textStorage.length)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

extension DiffRowBackgroundLayoutManager {
    fileprivate func drawFocusOutline(width: CGFloat, origin: NSPoint, textLength: Int) {
        guard let focusedRange, NSMaxRange(focusedRange) <= textLength else { return }
        var union = NSRect.null
        let glyphRange = glyphRange(forCharacterRange: focusedRange, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in union = union.union(rect) }
        guard !union.isNull else { return }
        let outline = NSRect(x: 1, y: union.minY + origin.y + 0.5, width: max(width, union.maxX + origin.x) - 2, height: union.height - 1)
        focusColor.setStroke()
        let path = NSBezierPath(rect: outline)
        path.lineWidth = 1
        path.stroke()
    }
}

/// Drawn outside the text storage so copies exclude numbers; pinned to the scroll view so it never scrolls horizontally.
private final class DiffGutterView: NSView {
    weak var diffTextView: NSTextView?
    private weak var scrollView: DiffScrollView?
    var palette: BSidePalette = .fallback {
        didSet { needsDisplay = true }
    }

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
    private static let changeBarWidth: CGFloat = 3
    private static let markerColumnWidth: CGFloat = {
        ("\u{2212}" as NSString).size(withAttributes: [.font: font]).width
    }()

    private func digitColumnWidth(_ digitCount: Int) -> CGFloat {
        guard digitCount > 0 else { return 0 }
        return (String(repeating: "0", count: digitCount) as NSString).size(withAttributes: [.font: Self.font]).width
    }

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
        columnMaxXs.marker + Self.horizontalPadding + Self.changeBarWidth
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

        func drawRightAligned(
            _ string: String, maxX: CGFloat, lineOriginY: CGFloat, lineHeight: CGFloat,
            attributes: [NSAttributedString.Key: Any] = attributes
        ) {
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
            let statusColor: NSColor
            switch info.kind {
            case .added:
                marker = "+"
                statusColor = NSColor(self.palette.statusSuccess)
            case .removed:
                marker = "\u{2212}"
                statusColor = NSColor(self.palette.statusError)
            case .context:
                return
            }
            drawRightAligned(
                marker, maxX: markerColumnMaxX, lineOriginY: lineOriginInGutter.y, lineHeight: fragmentRect.height,
                attributes: [.font: Self.font, .foregroundColor: statusColor.withAlphaComponent(0.55)]
            )
            statusColor.setFill()
            NSRect(x: self.bounds.width - Self.changeBarWidth, y: lineOriginInGutter.y, width: Self.changeBarWidth, height: fragmentRect.height).fill()
        }
    }
}

/// `NSScrollView.contentInsets` didn't move the clip view's frame here, so `tile()` reserves `gutterLeftInset` by hand.
final class DiffScrollView: NSScrollView {
    var gutterLeftInset: CGFloat = 0
    weak var gutterView: NSView?
    /// Keeps `NSAccessibilityCustomRotor.itemSearchDelegate` (a weak reference) alive.
    var rotorSearchDelegates: [NSObject] = []
    var appliedFocus: NSRange?

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

/// The +/- markers only live in the hidden gutter, so this rotor is how VoiceOver tells added and removed lines apart.
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

struct DiffTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let palette: BSidePalette
    var focusedRange: NSRange?

    func makeNSView(context: Context) -> DiffScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = DiffRowBackgroundLayoutManager()
        textStorage.addLayoutManager(layoutManager)
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
        syncFocus(in: scrollView, textView: textView, textChanged: true)

        return scrollView
    }

    func updateNSView(_ scrollView: DiffScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let gutter = scrollView.subviews.compactMap { $0 as? DiffGutterView }.first
        apply(palette: palette, to: textView, scrollView: scrollView, gutter: gutter)
        let textChanged = textView.attributedString() != attributedText
        if textChanged {
            textView.textStorage?.setAttributedString(attributedText)
            gutter?.metrics = UnifiedDiffRenderer.gutterMetrics(in: attributedText)
            updateAccessibilityLabel(textView: textView)
            gutter?.needsDisplay = true
        }
        syncFocus(in: scrollView, textView: textView, textChanged: textChanged)
    }

    private func syncFocus(in scrollView: DiffScrollView, textView: NSTextView, textChanged: Bool) {
        (textView.layoutManager as? DiffRowBackgroundLayoutManager)?.focusedRange = focusedRange
        guard textChanged || focusedRange != scrollView.appliedFocus else { return }
        scrollView.appliedFocus = focusedRange
        textView.needsDisplay = true
        if let focusedRange {
            scrollToFocus(focusedRange, in: scrollView, textView: textView)
        } else if textChanged {
            scrollToStart(scrollView)
        }
    }

    private static let contextLinesAboveFocus: CGFloat = 3

    private func scrollToFocus(_ range: NSRange, in scrollView: DiffScrollView, textView: NSTextView) {
        DispatchQueue.main.async {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let clip = scrollView.contentView
            let maxY = max(0, textView.frame.height - clip.bounds.height)
            let y = lineRect.minY + textView.textContainerInset.height - lineRect.height * Self.contextLinesAboveFocus
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// The frame can grow wider than the clip view after layout, leaving the scroll mid-document; deferred a runloop turn to apply after that pass.
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
        if let layoutManager = textView.layoutManager as? DiffRowBackgroundLayoutManager {
            layoutManager.focusColor = NSColor(palette.accent).withAlphaComponent(0.7)
        }
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

struct DiffPaneView: View {
    let diffText: String
    let filePath: String
    let palette: BSidePalette
    var focusedBlock: DiffChangeBlock?

    @State private var displayed = NSAttributedString()
    @State private var rowRanges: [NSRange] = []
    @State private var renderedDiffText: String?

    private struct RenderKey: Equatable {
        let filePath: String
        let diffText: String
        let palette: BSidePalette
    }

    private static let highlighter = Highlight()

    var body: some View {
        DiffTextView(attributedText: displayed, palette: palette, focusedRange: focusedRange)
            .task(id: RenderKey(filePath: filePath, diffText: diffText, palette: palette)) {
                await render()
            }
    }

    private var focusedRange: NSRange? {
        guard renderedDiffText == diffText, let focusedBlock,
              focusedBlock.lastRow < rowRanges.count else { return nil }
        let first = rowRanges[focusedBlock.firstRow]
        return NSRange(location: first.location, length: NSMaxRange(rowRanges[focusedBlock.lastRow]) - first.location)
    }

    private func render() async {
        let rows = UnifiedDiffRenderer.parse(diffText)
        let (plain, rowRanges) = UnifiedDiffRenderer.renderRows(rows, palette: palette)
        self.rowRanges = rowRanges
        renderedDiffText = diffText
        displayed = plain
        guard rows.count <= DiffSyntaxHighlighter.maxHighlightableRowCount else { return }

        let oldRowIndices = rows.indices.filter { rows[$0].oldLineNumber != nil }
        let newRowIndices = rows.indices.filter { rows[$0].newLineNumber != nil }
        guard !oldRowIndices.isEmpty || !newRowIndices.isEmpty else { return }

        // Strip stray `\r` (CRLF sources) so it doesn't inflate the leading-whitespace run `leadingTrim` measures.
        let oldText = oldRowIndices.map { rows[$0].text.replacingOccurrences(of: "\r", with: "") }.joined(separator: "\n")
        let newText = newRowIndices.map { rows[$0].text.replacingOccurrences(of: "\r", with: "") }.joined(separator: "\n")
        let mode: HighlightMode = DiffLanguageDetector.language(forPath: filePath).map { .languageIgnoreIllegal($0) } ?? .automatic
        let colors = DiffSyntaxHighlighter.colors(isDark: palette.isDark)

        // Sequential, not `async let`: `NSAttributedString` isn't Sendable across a child task boundary under strict concurrency.
        let old = await Self.highlight(oldText, mode: mode, colors: colors)
        guard !Task.isCancelled else { return }
        let new = await Self.highlight(newText, mode: mode, colors: colors)
        guard !Task.isCancelled else { return }

        let rowTextLengths = rows.map { ($0.text as NSString).length }
        let colored = NSMutableAttributedString(attributedString: plain)
        if let old {
            let trim = DiffSyntaxHighlighter.leadingTrim(of: oldText)
            DiffSyntaxHighlighter.applyColorRuns(
                DiffSyntaxHighlighter.colorRunsByLine(in: old),
                toRowIndices: Array(oldRowIndices.dropFirst(trim.droppedLines)),
                rowTextLengths: rowTextLengths, rowRanges: rowRanges, leadingIndent: trim.indent, in: colored
            )
        }
        if let new {
            let trim = DiffSyntaxHighlighter.leadingTrim(of: newText)
            DiffSyntaxHighlighter.applyColorRuns(
                DiffSyntaxHighlighter.colorRunsByLine(in: new),
                toRowIndices: Array(newRowIndices.dropFirst(trim.droppedLines)),
                rowTextLengths: rowTextLengths, rowRanges: rowRanges, leadingIndent: trim.indent, in: colored
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
