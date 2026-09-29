import AppKit
import Foundation
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

/// Samples real pixels offscreen; sidebars and title bar are Liquid Glass sampling the desktop, so only the opaque main area is checked.
@MainActor
struct ContentViewThemeSnapshotTests {
    @Test("The main area picks up the resolved theme")
    func mainAreaMatchesResolvedTheme() async throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bside-window-theme-test-\(UUID().uuidString)")
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
        let expectedPalette = BSidePalette.themed(from: ayuMirage)
        let expectedBackground = NSColor(expectedPalette.windowBackground)

        // Force both sidebars visible regardless of persisted UserDefaults.
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

        try await Task.sleep(for: .milliseconds(800))

        guard let contentView = window.contentView, let frameView = contentView.superview else {
            Issue.record("Window has no content/frame view to render")
            return
        }
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Manual NSView draw pass: the main area is a plain NSHostingView, so `cacheDisplay` works without Screen Recording permission.
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            Issue.record("Failed to create bitmap for content view")
            window.orderOut(nil)
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        window.orderOut(nil)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: "/tmp/bside-themed-window.png"))

        // AppKit points (bottom-left origin) to bitmap pixels (top-left origin), scaled.
        let scaleX = CGFloat(bitmap.pixelsWide) / contentView.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / contentView.bounds.height
        func sample(atPointX x: CGFloat, appKitY y: CGFloat) -> NSColor? {
            let pixelX = Int(x * scaleX)
            let pixelY = bitmap.pixelsHigh - Int(y * scaleY) - 1
            guard pixelX >= 0, pixelX < bitmap.pixelsWide, pixelY >= 0, pixelY < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: pixelX, y: pixelY)
        }

        let contentFrame = contentView.bounds
        let mainAreaSampleX = contentFrame.minX + contentFrame.width * 0.45
        let midY = contentFrame.midY

        let mainAreaColor = try #require(sample(atPointX: mainAreaSampleX, appKitY: midY))

        func report(_ label: String, _ color: NSColor) -> String {
            let c = color.usingColorSpace(.deviceRGB) ?? color
            return "\(label): r=\(c.redComponent) g=\(c.greenComponent) b=\(c.blueComponent)"
        }
        print([
            report("mainArea", mainAreaColor),
            report("expectedBackground", expectedBackground),
        ].joined(separator: " | "))

        #expect(isCloseToDarkThemeFamily(mainAreaColor, background: expectedBackground))
    }
}

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
