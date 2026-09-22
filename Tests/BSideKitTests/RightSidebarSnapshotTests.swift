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

        // Poll instead of a single fixed sleep before the one-shot capture:
        // the window's chrome suppression (see `ThemedWindowModifier`) reacts
        // to AppKit inserting vibrancy/backdrop layers asynchronously with no
        // fixed completion time, so re-render and re-sample until the strip
        // actually looks right or a timeout elapses. The timeout path falls
        // through to the real assertions below with whatever was last
        // captured, so a genuine regression still fails the test.
        let deadline = Date().addingTimeInterval(3)
        var capturedBitmap: NSBitmapImageRep?
        var lastCaptureError: Error?
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            do {
                let candidate = try capture(window)
                capturedBitmap = candidate
                if looksSettled(candidate, palette: palette) {
                    break
                }
            } catch {
                // WindowServer hasn't registered this window's surface yet
                // right after `setIsVisible`; retry rather than failing on
                // the very first, too-early capture attempt.
                lastCaptureError = error
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        guard let bitmap = capturedBitmap else {
            Issue.record("Failed to capture window image")
            throw lastCaptureError ?? CaptureError.failed
        }

        // Flush to the top: the very first row of pixels should already be
        // sidebar surface or picker chrome, not the window background
        // colour with a gap above the strip.
        let topRowSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 1))
        #expect(luminance(of: topRowSample) > 0.02)

        // Full width: sample two points inside the strip row that sit well
        // clear of the segmented control's own 8pt (16px at this capture's
        // 2x backing scale) horizontal padding, near the left and right
        // edges of the sidebar, and compare them against a plain-background
        // reference sampled from the same row, just inside that padding.
        // The old, broken layout shrink-wrapped the segmented control into a
        // small centred pill, which left these same coordinates showing the
        // bare sidebar background untouched, indistinguishable from the
        // reference; a genuinely full-width strip instead has its own
        // chrome there — measured here at approximately 0.39 (selected
        // segment fill) and 0.28 (unselected segment fill) per channel,
        // against a background reference of approximately 0.21.
        //
        // This deliberately does NOT compare against the nominal
        // `palette.surfaceBackground`, which a first attempt at this
        // assertion did: measured on this same capture, plain sidebar
        // background differs from `NSColor(palette.surfaceBackground)` by a
        // colour distance of roughly 0.088, just from AppKit's colour-space
        // conversion, not from anything being wrong with the layout. That
        // gap alone clears the `> 0.03` threshold that comparison used, so
        // it passed whether or not the strip was actually full width — the
        // rendered surface never matches the nominal palette colour closely
        // enough for that comparison to mean anything here.
        let stripRowY = 35
        let backgroundReference = try #require(bitmap.colorAt(x: 8, y: stripRowY))
        let leftInteriorSample = try #require(bitmap.colorAt(x: 24, y: stripRowY))
        let rightInteriorSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 24, y: stripRowY))
        report("stripLeftInterior", leftInteriorSample, expected: backgroundReference)
        report("stripRightInterior", rightInteriorSample, expected: backgroundReference)
        // 0.1 sits with wide headroom above zero (what same-background noise
        // would produce) and well below the smallest measured real gap
        // (~0.22 for the unselected segment against the background).
        #expect(colorDistance(leftInteriorSample, backgroundReference) > 0.1)
        #expect(colorDistance(rightInteriorSample, backgroundReference) > 0.1)

        let surfaceBackground = NSColor(palette.surfaceBackground)

        // The empty-state placeholder below the strip should sit on the
        // sidebar's themed surface background, not a hardcoded colour.
        // Sampled here, ahead of the glyph-brightness check below, so its
        // luminance can serve as the known-background reference for that
        // check too.
        let placeholderAreaSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20))
        #expect(isCloseToDarkThemeFamily(placeholderAreaSample, background: surfaceBackground))

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
        // A readable light-on-dark label produces pixels well above the
        // background's own luminance; `maxLuminance > 0.05` alone can never
        // fail independently of the assertion above (max >= min by
        // construction), so this checks the brightest pixel really is a
        // rendered glyph rather than just "not black".
        #expect(maxLuminance - luminance(of: placeholderAreaSample) > 0.3)
    }

    /// Cheap, non-asserting re-check of the same conditions the real
    /// assertions below make, used only to decide whether polling can stop.
    private func looksSettled(_ bitmap: NSBitmapImageRep, palette: BSidePalette) -> Bool {
        guard let topRowSample = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 1),
            luminance(of: topRowSample) > 0.02
        else { return false }

        let (minLuminance, maxLuminance) = luminanceRange(
            in: bitmap,
            xRange: 10..<(bitmap.pixelsWide - 10),
            yRange: 10..<(bitmap.pixelsHigh - 10)
        )
        guard minLuminance > 0.05, maxLuminance > 0.05 else { return false }

        guard let placeholderAreaSample = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20) else { return false }
        return isCloseToDarkThemeFamily(placeholderAreaSample, background: NSColor(palette.surfaceBackground))
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
        // Explicitly themed, exactly as `themedWindow` does in production.
        // Without this the suite passes or fails depending on run *order*:
        // `NSApp.appearance` is process-global, and the suites that host a
        // whole `ContentView` set it as a side effect, so this view would
        // inherit dark appearance only when one of those happened to run
        // first. Alone, it rendered its AppKit tab strip in light `aqua` —
        // black labels on the dark themed surface, the very bug the
        // minimum-luminance assertion below exists to catch.
        window.appearance = theme.palette.preferredAppearance
        window.contentView = NSHostingView(rootView: RightSidebarView(store: store))
        window.setIsVisible(true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, theme.palette)
    }

    private func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
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

    /// Sum of per-channel absolute differences, used where luminance alone
    /// can't tell a neutral grey (equal r/g/b) apart from a blue-tinted
    /// colour of similar brightness.
    private func colorDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.deviceRGB) ?? a
        let b = b.usingColorSpace(.deviceRGB) ?? b
        return abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
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
