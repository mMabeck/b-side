import AppKit
import Foundation
import SwiftUI
import Testing

@testable import BSideKit

/// Renders ``ThemePreviewView`` offscreen for the bundled "B-Side" brand
/// theme and samples real composited pixels, the same technique
/// `AuxiliaryWindowThemeSnapshotTests` uses for other themed windows.
@MainActor
struct ThemePreviewSnapshotTests {
    @Test("The preview's terminal area and sidebar are coloured from the theme's own palette")
    func previewReflectsTheme() async throws {
        let definition = BSideBundledThemes.bSide
        let palette = BSidePalette.themed(from: definition)

        let hostingView = NSHostingView(rootView: ThemePreviewView(definition: definition))
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 200)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setIsVisible(true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }

        let bitmap = try await capture(window)

        // Main terminal area: a pixel well inside the right two-thirds of
        // the mock, clear of any glyph, should read as the theme's own
        // background — not the sidebar's lighter surface tone.
        let terminalSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2))
        let expectedBackground = NSColor(RGBColor(hex: definition.background).color)
        #expect(closeColor(terminalSample, expectedBackground))

        // Sidebar: a pixel near the left edge should be a visibly different
        // tone from the terminal background — the elevation step
        // `BSidePalette.surfaceBackground` provides.
        let sidebarSample = try #require(bitmap.colorAt(x: 10, y: bitmap.pixelsHigh / 2))
        #expect(!closeColor(sidebarSample, expectedBackground, tolerance: 0.03))
        let expectedSurface = NSColor(palette.surfaceBackground)
        #expect(closeColor(sidebarSample, expectedSurface, tolerance: 0.1))
    }

    /// Draws the hosting view into a bitmap directly, as
    /// `SubagentCardSnapshotTests` does, not via `CGWindowListCreateImage`:
    /// the preview is plain SwiftUI with no window vibrancy to wait on, and a
    /// WindowServer capture intermittently never succeeds within any short
    /// deadline while other snapshot suites run in parallel.
    private func capture(_ window: NSWindow) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(300))
        guard let hostingView = window.contentView else { throw CaptureError.failed }
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds),
              let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw CaptureError.failed }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        hostingView.displayIgnoringOpacity(hostingView.bounds, in: graphicsContext)
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/bside-theme-preview.png"))
        return bitmap
    }

    private enum CaptureError: Error { case failed }

    private func closeColor(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.05) -> Bool {
        guard let a = a.usingColorSpace(.deviceRGB), let b = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}
