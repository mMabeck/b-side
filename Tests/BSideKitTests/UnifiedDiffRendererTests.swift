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

    @Test("Added lines are coloured with statusSuccess")
    func addedLineColour() {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)
        let lines = sampleDiff.components(separatedBy: "\n")
        let addedLineStart = lines[0..<(lines.count - 1)].reduce(0) { $0 + $1.count + 1 }

        #expect(sameColor(color(at: addedLineStart, in: attributed), palette.statusSuccess))
    }

    @Test("Removed lines are coloured with statusError")
    func removedLineColour() {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)
        let lines = sampleDiff.components(separatedBy: "\n")
        let removedLineStart = lines[0..<(lines.count - 2)].reduce(0) { $0 + $1.count + 1 }

        #expect(sameColor(color(at: removedLineStart, in: attributed), palette.statusError))
    }

    @Test("Hunk headers are coloured with accent")
    func hunkHeaderColour() {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)
        let lines = sampleDiff.components(separatedBy: "\n")
        let hunkLineStart = lines[0..<4].reduce(0) { $0 + $1.count + 1 }

        #expect(lines[4].hasPrefix("@@"))
        #expect(sameColor(color(at: hunkLineStart, in: attributed), palette.accent))
    }

    @Test("Context lines use textPrimary, not added/removed colours")
    func contextLineColour() {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)
        let lines = sampleDiff.components(separatedBy: "\n")
        let contextLineStart = lines[0..<5].reduce(0) { $0 + $1.count + 1 }

        #expect(lines[5] == " let unchanged = 1")
        #expect(sameColor(color(at: contextLineStart, in: attributed), palette.textPrimary))
    }

    @Test("+++ and --- file headers are dimmed, not treated as added/removed content")
    func fileHeadersAreNotAddedOrRemoved() {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)
        let lines = sampleDiff.components(separatedBy: "\n")

        let removedHeaderStart = lines[0..<2].reduce(0) { $0 + $1.count + 1 }
        #expect(lines[2].hasPrefix("--- "))
        #expect(sameColor(color(at: removedHeaderStart, in: attributed), palette.textDisabled))
        #expect(!sameColor(color(at: removedHeaderStart, in: attributed), palette.statusError))

        let addedHeaderStart = lines[0..<3].reduce(0) { $0 + $1.count + 1 }
        #expect(lines[3].hasPrefix("+++ "))
        #expect(sameColor(color(at: addedHeaderStart, in: attributed), palette.textDisabled))
        #expect(!sameColor(color(at: addedHeaderStart, in: attributed), palette.statusSuccess))
    }

    @Test("diff --git and index lines are dimmed")
    func gitAndIndexHeadersAreDimmed() {
        let attributed = UnifiedDiffRenderer.render(sampleDiff, palette: palette)

        #expect(sameColor(color(at: 0, in: attributed), palette.textDisabled))

        let lines = sampleDiff.components(separatedBy: "\n")
        let indexLineStart = lines[0].count + 1
        #expect(lines[1].hasPrefix("index "))
        #expect(sameColor(color(at: indexLineStart, in: attributed), palette.textDisabled))
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
