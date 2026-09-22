import AppKit
import Foundation
import GhosttyTheme
import SwiftUI
import Testing

@testable import DashNativeKit

/// Renders the *whole* app window offscreen — title bar, both sidebars, main
/// area — and samples real pixel values to prove the resolved Ghostty theme
/// reaches every region, not just the terminal grid. Uses a real, never-
/// key, never-onscreen `NSWindow` driven only by programmatic APIs (see
/// `SubagentCardSnapshotTests`/`TerminalSurfaceHostTests` for the same
/// pattern): no synthetic clicks or keystrokes are used anywhere here.
@MainActor
struct ContentViewThemeSnapshotTests {
    @Test("The whole window — title bar, both sidebars, main area — picks up the resolved theme")
    func wholeWindowMatchesResolvedTheme() async throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-native-window-theme-test-\(UUID().uuidString)")
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

        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        let expectedPalette = DashPalette.themed(from: ayuMirage)
        let expectedBackground = NSColor(expectedPalette.windowBackground)

        // Ensure the split view opens with both sidebars visible regardless
        // of state a previous run may have persisted to UserDefaults.
        UserDefaults.standard.set(false, forKey: "leftSidebarCollapsed")
        UserDefaults.standard.set(false, forKey: "rightSidebarCollapsed")
        UserDefaults.standard.set(true, forKey: "terminalDrawerCollapsed")

        let database = try AppDatabase.openInMemory()
        let store = ProjectsStore(database: database)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.setIsVisible(true)

        // MainAreaView's `TerminalSurfaceHost` resolves the same theme
        // through the real config file above, matching production: the
        // terminal grid and the rest of the chrome are proven to agree.
        try await Task.sleep(for: .milliseconds(800))

        guard let contentView = window.contentView, let frameView = contentView.superview else {
            Issue.record("Window has no content/frame view to render")
            return
        }
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Captured via `CGWindowListCreateImage`, not a manual `NSView` draw
        // pass: a manual `bitmapImageRepForCachingDisplay` +
        // `displayIgnoringOpacity` capture only walks the `drawRect`-based
        // rendering path and silently produces a blank image for content
        // whose real painting happens only through WindowServer's
        // compositor (confirmed separately for `List`'s per-row
        // `NSHostingView`s in `SidebarSnapshotTests`). Asking WindowServer
        // directly for this window's own composited pixels is the only
        // capture path that reflects what real rendering actually produced.
        // The window is still positioned off any physical display and never
        // key/frontmost, so nothing is shown to the user; no layers are
        // hidden before sampling.
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else {
            Issue.record("Failed to capture window image")
            window.orderOut(nil)
            return
        }
        window.orderOut(nil)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: "/tmp/dash-native-themed-window.png"))

        // Map AppKit points (origin bottom-left) to bitmap pixels (origin
        // top-left), accounting for the backing scale factor.
        let scaleX = CGFloat(bitmap.pixelsWide) / frameView.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / frameView.bounds.height
        func sample(atPointX x: CGFloat, appKitY y: CGFloat) -> NSColor? {
            let pixelX = Int(x * scaleX)
            let pixelY = bitmap.pixelsHigh - Int(y * scaleY) - 1
            guard pixelX >= 0, pixelX < bitmap.pixelsWide, pixelY >= 0, pixelY < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: pixelX, y: pixelY)
        }

        let contentFrame = contentView.frame // in frameView's coordinate space
        let titleBarSampleY = frameView.bounds.height - 10 // a few points below the very top edge
        let titleBarSampleX = frameView.bounds.width * 0.5 // clear of the traffic lights

        let leftSidebarSampleX = contentFrame.minX + 40
        let mainAreaSampleX = contentFrame.minX + contentFrame.width * 0.45
        let rightSidebarSampleX = contentFrame.maxX - 40
        let midY = contentFrame.midY

        let titleBarColor = try #require(sample(atPointX: titleBarSampleX, appKitY: titleBarSampleY))
        let leftSidebarColor = try #require(sample(atPointX: leftSidebarSampleX, appKitY: midY))
        let mainAreaColor = try #require(sample(atPointX: mainAreaSampleX, appKitY: midY))
        let rightSidebarColor = try #require(sample(atPointX: rightSidebarSampleX, appKitY: midY))

        func report(_ label: String, _ color: NSColor) -> String {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            return "\(label): r=\(c.redComponent) g=\(c.greenComponent) b=\(c.blueComponent)"
        }
        print([
            report("titleBar", titleBarColor),
            report("leftSidebar", leftSidebarColor),
            report("mainArea", mainAreaColor),
            report("rightSidebar", rightSidebarColor),
            report("expectedBackground", expectedBackground),
        ].joined(separator: " | "))

        // None of the sampled regions should be plain white/light-system
        // default — every one should read close to the theme's dark
        // background family (window background, or a nearby elevated
        // surface tone), proving the whole window followed the theme.
        #expect(isCloseToDarkThemeFamily(titleBarColor, background: expectedBackground))
        #expect(isCloseToDarkThemeFamily(leftSidebarColor, background: expectedBackground))
        #expect(isCloseToDarkThemeFamily(mainAreaColor, background: expectedBackground))
        #expect(isCloseToDarkThemeFamily(rightSidebarColor, background: expectedBackground))
    }
}

/// True if `color` is dark (low luminance, matching a dark Ghostty theme)
/// and reasonably close to the theme's own background — i.e. not a light
/// system default and not an unrelated hardcoded colour.
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
