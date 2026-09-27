import AppKit
import SwiftUI
import Testing

@testable import BSideKit

/// Pure renderer tests: no window, no view hierarchy, no palette resolution
/// from a live Ghostty theme.
struct UnifiedDiffRendererTests {
    private let palette = BSidePalette.fallback

    private func color(at index: Int, in attributed: NSAttributedString) -> NSColor {
        let value = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil)
        return (value as? NSColor) ?? .clear
    }

    private func sameColor(_ a: NSColor, _ b: Color) -> Bool {
        guard let deviceA = a.usingColorSpace(.deviceRGB),
              let deviceB = NSColor(b).usingColorSpace(.deviceRGB) else { return false }
        return abs(deviceA.redComponent - deviceB.redComponent) < 0.001
            && abs(deviceA.greenComponent - deviceB.greenComponent) < 0.001
            && abs(deviceA.blueComponent - deviceB.blueComponent) < 0.001
    }

    private let sampleDiff = """
    diff --git a/foo.swift b/foo.swift
    index 1234567..89abcde 100644
    --- a/foo.swift
    +++ b/foo.swift
    @@ -1,3 +1,3 @@
     let unchanged = 1
    -let removed = 2
    +let added = 2
    """

    private enum ExpectedRole { case dimmed, accent, primary, added, removed }

    @Test("Each diff line kind is coloured distinctly: git/index/file headers dimmed, hunk header accented, +/- lines success/error, context primary", arguments: [
        (lineIndex: 0, prefix: "diff --git", role: ExpectedRole.dimmed),
        (lineIndex: 1, prefix: "index ", role: ExpectedRole.dimmed),
        (lineIndex: 2, prefix: "--- ", role: ExpectedRole.dimmed),
        (lineIndex: 3, prefix: "+++ ", role: ExpectedRole.dimmed),
        (lineIndex: 4, prefix: "@@", role: ExpectedRole.accent),
        (lineIndex: 5, prefix: " let unchanged", role: ExpectedRole.primary),
        (lineIndex: 6, prefix: "-let removed", role: ExpectedRole.removed),
        (lineIndex: 7, prefix: "+let added", role: ExpectedRole.added),
    ])
    private func lineColour(lineIndex: Int, prefix: String, role: ExpectedRole) {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)
        let lines = sampleDiff.components(separatedBy: "\n")
        let lineStart = lines[0..<lineIndex].reduce(0) { $0 + $1.count + 1 }
        let expectedColor: Color
        switch role {
        case .dimmed: expectedColor = palette.textDisabled
        case .accent: expectedColor = palette.accent
        case .primary: expectedColor = palette.textPrimary
        case .added: expectedColor = palette.statusSuccess
        case .removed: expectedColor = palette.statusError
        }

        #expect(lines[lineIndex].hasPrefix(prefix))
        #expect(sameColor(color(at: lineStart, in: attributed), expectedColor))
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

/// Regression test for `DiffTextView`: it must host a real, laid-out
/// `NSTextView` inside its `NSScrollView`, not a zero-frame view that never
/// receives layout. Hosts the representable in a real, never-ordered-front
/// `NSWindow`, matching the pattern in `TerminalSurfaceHostTests`.
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

    /// Polls rather than sleeping a fixed duration: layout happens on the
    /// next run-loop pass after the window is ordered in.
    private func pollUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func diffTextViewLaysOutNonEmptyGlyphsAtARealSize() async throws {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,1 +1,1 @@
        -let removed = 2
        +let added = 2
        """
        let window = makeHostedWindow(diff: diff)
        defer { window.orderOut(nil) }

        var scrollView: NSScrollView?
        await pollUntil {
            scrollView = window.contentView.flatMap { self.firstScrollView(in: $0) }
            return scrollView != nil
        }
        let textView = try #require(scrollView?.documentView as? NSTextView)
        await pollUntil { textView.frame.width > 0 && textView.frame.height > 0 }

        #expect(textView.frame.width > 0)
        #expect(textView.frame.height > 0)

        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        #expect(usedRect.width > 0)
        #expect(usedRect.height > 0)
    }
}
