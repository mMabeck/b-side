import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders the reworked right-sidebar tab strip offscreen and samples real
/// composited pixels, following the same conventions as
/// `AuxiliaryWindowThemeSnapshotTests`: a borderless, never-shown-onscreen
/// window (no real titlebar chrome to sample by mistake), a themed palette
/// resolved the same way production does, and a minimum-luminance check
/// alongside a bright-pixel check so a dark-on-dark label can't hide behind
/// a single lucky sample.
@Suite(.serialized)
@MainActor
struct RightSidebarSnapshotTests {
    @Test("The tab strip is flush with the sidebar's top edge, full width, themed, and legible")
    func tabStripIsFlushToTopAndThemed() async throws {
        let (window, palette) = try await renderOffscreen()
        defer { window.orderOut(nil) }

        let bitmap = try capture(window)

        // Flush to the top: the very first row of pixels should already be
        // sidebar surface or picker chrome, not the window background
        // colour with a gap above the strip.
        let topRowSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 1))
        #expect(luminance(of: topRowSample) > 0.02)

        // Full width: sampling near the left and right edges of the strip's
        // row should both land inside picker/strip chrome, not the bare
        // sidebar background peeking out at either side.
        let stripRowY = bitmap.pixelsHigh - 10
        let leftEdgeSample = try #require(bitmap.colorAt(x: 4, y: stripRowY))
        let rightEdgeSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 4, y: stripRowY))
        report("stripLeftEdge", leftEdgeSample, expected: NSColor(palette.surfaceBackground))
        report("stripRightEdge", rightEdgeSample, expected: NSColor(palette.surfaceBackground))

        // No near-black glyphs anywhere in the content area: the segmented
        // control's own tab labels are system-drawn text over the themed
        // background.
        let (minLuminance, maxLuminance) = luminanceRange(
            in: bitmap,
            xRange: 10..<(bitmap.pixelsWide - 10),
            yRange: 10..<(bitmap.pixelsHigh - 10)
        )
        print("sidebar content area: minLuminance=\(minLuminance) maxLuminance=\(maxLuminance)")
        #expect(minLuminance > 0.05)
        #expect(maxLuminance > 0.05)

        // The empty-state placeholder below the strip should sit on the
        // sidebar's themed surface background, not a hardcoded colour.
        let placeholderAreaSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20))
        #expect(isCloseToDarkThemeFamily(placeholderAreaSample, background: NSColor(palette.surfaceBackground)))
    }

    // MARK: - Shared offscreen render/capture plumbing

    private func renderOffscreen() async throws -> (NSWindow, BSidePalette) {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-sidebar-test-\(UUID().uuidString)")
        let ghosttyConfigDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: ghosttyConfigDir, withIntermediateDirectories: true)
        try "theme = Ayu Mirage\n".write(
            to: ghosttyConfigDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        let previousXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previousXDG {
                setenv("XDG_CONFIG_HOME", previousXDG, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            try? FileManager.default.removeItem(at: configHome)
        }

        let previousDefinition = GhosttyResolvedTheme.shared.definition
        defer { GhosttyResolvedTheme.shared.update(previousDefinition) }
        GhosttyResolvedTheme.resolveEagerly()
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        #expect(GhosttyResolvedTheme.shared.definition?.name == ayuMirage.name)
        let theme = GhosttyResolvedTheme.shared

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: RightSidebarView(store: store))
        window.setIsVisible(true)
        try await Task.sleep(for: .milliseconds(400))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, theme.palette)
    }

    private func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
            Issue.record("Failed to capture window image")
            throw CaptureError.failed
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private enum CaptureError: Error { case failed }

    private func report(_ label: String, _ color: NSColor, expected: NSColor) {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let e = expected.usingColorSpace(.deviceRGB) ?? expected
        print("\(label): r=\(c.redComponent) g=\(c.greenComponent) b=\(c.blueComponent) | expected: r=\(e.redComponent) g=\(e.greenComponent) b=\(e.blueComponent)")
    }

    private func luminance(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    private func luminanceRange(
        in bitmap: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> (min: CGFloat, max: CGFloat) {
        var minL: CGFloat = 1
        var maxL: CGFloat = 0
        for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
            for x in xRange where x >= 0 && x < bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let l = luminance(of: color)
                minL = min(minL, l)
                maxL = max(maxL, l)
            }
        }
        return (minL, maxL)
    }
}

/// True if `color` is dark (low luminance, matching a dark Ghostty theme)
/// and reasonably close to the theme's own background — duplicated from
/// `AuxiliaryWindowThemeSnapshotTests` (private there) rather than shared,
/// per that file's own precedent.
private func isCloseToDarkThemeFamily(_ color: NSColor, background: NSColor, tolerance: CGFloat = 0.25) -> Bool {
    guard let color = color.usingColorSpace(.deviceRGB), let background = background.usingColorSpace(.deviceRGB) else {
        return false
    }
    let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    guard luminance < 0.5 else { return false }
    return abs(color.redComponent - background.redComponent) < tolerance
        && abs(color.greenComponent - background.greenComponent) < tolerance
        && abs(color.blueComponent - background.blueComponent) < tolerance
}

/// Guards the exact failure mode that made the icons silently disappear
/// twice while this strip was being built: SwiftUI's own segmented `Picker`
/// and `TabView` both *accept* a `Label` with a system image and then render
/// only its title, with no error and no compile-time complaint. Asserting on
/// the real `NSSegmentedControl` catches that directly — a segment that has
/// lost either half fails here rather than quietly shipping.
@MainActor
struct InspectorTabStripTests {
    private enum Tab: Hashable { case first, second }

    @Test("Every segment carries both an icon and a title")
    func segmentsCarryIconAndTitle() {
        var selection = Tab.first
        let strip = InspectorTabStrip(
            items: [
                .init(tab: Tab.first, title: "Source Control", systemImage: "arrow.triangle.branch"),
                .init(tab: Tab.second, title: "Subagents", systemImage: "person.2"),
            ],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            accent: .yellow
        )

        let control = strip.makeControl(target: nil, action: nil)

        #expect(control.segmentCount == 2)
        for index in 0..<control.segmentCount {
            #expect(control.image(forSegment: index) != nil)
            #expect(control.label(forSegment: index)?.isEmpty == false)
        }
        #expect(control.label(forSegment: 0) == "Source Control")
        #expect(control.label(forSegment: 1) == "Subagents")
        // Equal-width segments are what make the strip span the sidebar
        // rather than shrink-wrap into a small centred pill.
        #expect(control.segmentDistribution == .fillEqually)
        #expect(control.selectedSegment == 0)
    }
}
