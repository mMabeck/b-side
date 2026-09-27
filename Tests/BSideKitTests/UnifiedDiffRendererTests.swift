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
