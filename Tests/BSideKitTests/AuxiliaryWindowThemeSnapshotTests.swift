import AppKit
import Foundation
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Renders the New Task sheet and the Settings window offscreen and samples
/// real composited pixels, the same way `ContentViewThemeSnapshotTests` does
/// for the main window. These two are the surfaces that never construct a
/// `TerminalSurfaceHost` (no terminal grid lives in either), which is
/// exactly the gap that left them on `BSidePalette.fallback` — plain system
/// label text, black in light `aqua` — composited over an already-dark
/// themed background before eager theme resolution existed.
// `.serialized`: both tests mutate the process-global `GhosttyResolvedTheme.shared`
// (the real singleton `SettingsView`/`TaskCreationView` read, matching
// production) and restore it afterward — running them concurrently with each
// other would race one test's restore against the other's in-flight capture.
@Suite(.serialized)
@MainActor
struct AuxiliaryWindowThemeSnapshotTests {
    @Test("The New Task sheet's background and heading text follow the resolved dark theme")
    func taskCreationSheetMatchesResolvedTheme() async throws {
        let (window, expectedPalette) = try await renderOffscreen(configuring: { theme in
            let project = Project(id: 1, path: "/tmp/example", displayName: "example", baseRef: "main")
            let database = try AppDatabase.openInMemory()
            let store = ProjectsStore(database: database)
            return NSHostingView(rootView: TaskCreationView(project: project, store: store, onFinished: {}))
        })
        defer { window.orderOut(nil) }

        let bitmap = try capture(window)
        let background = NSColor(expectedPalette.windowBackground)

        // Background: a strip clear of any text glyph, well inside the
        // window's edges.
        let backgroundSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 60))
        report("sheetBackground", backgroundSample, expected: background)
        #expect(isCloseToDarkThemeFamily(backgroundSample, background: background))

        // Scan the whole rendered content area (a small margin in from each
        // edge, to avoid any window-frame artifact) for the lightest pixel:
        // wherever the heading and form text actually landed, a readable
        // light-on-dark glyph produces one, without needing to predict this
        // sheet's exact layout coordinates.
        let (minLuminance, maxLuminance) = luminanceRange(
            in: bitmap,
            xRange: 10..<(bitmap.pixelsWide - 10),
            yRange: 10..<(bitmap.pixelsHigh - 10)
        )
        print("content area: minLuminance=\(minLuminance) maxLuminance=\(maxLuminance) backgroundLuminance=\(luminance(of: backgroundSample))")

        // A readable light-on-dark heading produces some pixels much
        // brighter than the background (the glyph strokes); black-on-black
        // text would leave this band uniformly dark, indistinguishable from
        // the background luminance sampled above.
        #expect(maxLuminance - luminance(of: backgroundSample) > 0.3)

        // The reported symptom itself: system label text drawn in light
        // `aqua` lands as near-black glyph strokes. The darkest pixel in a
        // correctly themed sheet is the theme's own background, so anything
        // materially darker than it can only be such a glyph. Asserting a
        // bright glyph exists is not enough on its own — a light-appearance
        // text field would supply one while still painting black text inside
        // it.
        #expect(minLuminance > 0.05)
    }

    @Test("The Settings window's background and control text follow the resolved dark theme")
    func settingsWindowMatchesResolvedTheme() async throws {
        let (window, expectedPalette) = try await renderOffscreen(configuring: { _ in
            NSHostingView(rootView: SettingsView())
        })
        defer { window.orderOut(nil) }

        let bitmap = try capture(window)
        let background = NSColor(expectedPalette.windowBackground)

        let backgroundSample = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        report("settingsBackground", backgroundSample, expected: background)
        #expect(isCloseToDarkThemeFamily(backgroundSample, background: background))

        // No near-black glyphs anywhere in the content area: the Form's
        // labels, toggle titles and tab items are all system-drawn text,
        // which renders black whenever the window is left in light `aqua`.
        let (minLuminance, maxLuminance) = luminanceRange(
            in: bitmap,
            xRange: 10..<(bitmap.pixelsWide - 10),
            yRange: 10..<(bitmap.pixelsHigh - 10)
        )
        print("settings content area: minLuminance=\(minLuminance) maxLuminance=\(maxLuminance) backgroundLuminance=\(luminance(of: backgroundSample))")
        #expect(minLuminance > 0.05)
        #expect(maxLuminance - luminance(of: backgroundSample) > 0.3)
    }

    // MARK: - Shared offscreen render/capture plumbing

    private func renderOffscreen(
        configuring makeView: (BSidePalette) throws -> NSView
    ) async throws -> (NSWindow, BSidePalette) {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-aux-theme-test-\(UUID().uuidString)")
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

        // `SettingsView`/`TaskCreationView` both read `GhosttyResolvedTheme.shared`
        // directly (not an injected instance), matching production, so this
        // resolves into `.shared` — exactly what `BSideApp.init()` does at
        // real launch — and restores its previous value afterward.
        // `TerminalSurfaceHostTests` already mutates the same singleton from
        // a concurrently running suite, so this follows existing precedent
        // rather than introducing a new shared-state risk.
        let previousDefinition = GhosttyResolvedTheme.shared.definition
        defer { GhosttyResolvedTheme.shared.update(previousDefinition) }
        GhosttyResolvedTheme.resolveEagerly()
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        #expect(GhosttyResolvedTheme.shared.definition?.name == ayuMirage.name)
        let theme = GhosttyResolvedTheme.shared

        // Borderless: both a real `.sheet` presentation and the `Settings`
        // scene render with no native titlebar chrome. A `.titled` test
        // window would sample that chrome's own opaque background near the
        // top edge instead of this app's themed content underneath it.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Themed explicitly, as `themedWindow` does in production: relying
        // on the process-global `NSApp.appearance` that other suites set as
        // a side effect makes these captures order-dependent (see
        // RightSidebarSnapshotTests for the same hazard biting).
        window.appearance = theme.palette.preferredAppearance
        window.contentView = try makeView(theme.palette)
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
/// and reasonably close to the theme's own background — i.e. not a light
/// system default and not an unrelated hardcoded colour. Duplicated from
/// `ContentViewThemeSnapshotTests` (private there) rather than shared,
/// since both are small, self-contained assertions over a captured bitmap.
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
