import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import DashNativeKit

/// Pure palette-derivation tests: no window, no terminal surface, no
/// libghostty runtime.
@MainActor
struct DashPaletteTests {
    @Test("A known dark theme (Ayu Mirage) resolves as dark and forces darkAqua")
    func darkThemeResolvesDarkAppearance() throws {
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        #expect(ayuMirage.background == "1f2430")

        let palette = DashPalette.themed(from: ayuMirage)
        #expect(palette.isDark)
        #expect(palette.preferredAppearance?.name == .darkAqua)
    }

    @Test("A known light theme resolves as light and forces aqua")
    func lightThemeResolvesLightAppearance() throws {
        let ayuLight = try #require(GhosttyThemeCatalog.theme(named: "Ayu Light"))

        let palette = DashPalette.themed(from: ayuLight)
        #expect(!palette.isDark)
        #expect(palette.preferredAppearance?.name == .aqua)
    }

    @Test("Elevated surfaces are distinct from the window background but close to it")
    func surfacesAreDistinctButClose() throws {
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        let palette = DashPalette.themed(from: ayuMirage)

        let window = try #require(NSColor(palette.windowBackground).usingColorSpace(.deviceRGB))
        let surface = try #require(NSColor(palette.surfaceBackground).usingColorSpace(.deviceRGB))
        let elevated = try #require(NSColor(palette.elevatedSurfaceBackground).usingColorSpace(.deviceRGB))

        // Distinct: each elevation step actually differs from the window background.
        #expect(!componentsAreClose(window, surface, tolerance: 0.005))
        #expect(!componentsAreClose(window, elevated, tolerance: 0.005))
        #expect(!componentsAreClose(surface, elevated, tolerance: 0.005))

        // Close: still visibly the same theme, not an unrelated hardcoded grey.
        #expect(componentsAreClose(window, surface, tolerance: 0.15))
        #expect(componentsAreClose(window, elevated, tolerance: 0.2))
    }

    @Test("No resolved theme falls back to standard system colours with no forced appearance")
    func fallbackWhenNoThemeResolves() {
        let theme = GhosttyResolvedTheme()
        let palette = theme.palette

        #expect(palette == DashPalette.fallback)
        #expect(palette.preferredAppearance == nil)
    }

    @Test("Selection colours prefer the theme's own selectionBackground over the accent")
    func selectionPrefersThemesOwnColour() throws {
        let definition = GhosttyThemeDefinition(
            name: "Test Theme",
            background: "1a1a1a",
            foreground: "eeeeee",
            cursorColor: "ff00ff",
            selectionBackground: "336699",
            selectionForeground: "ffffff",
            palette: [4: "0000ff"]
        )
        let palette = DashPalette.themed(from: definition)

        let expectedSelection = try #require(NSColor(Color(hex: "336699")).usingColorSpace(.deviceRGB))
        let actualSelection = try #require(NSColor(palette.selectionBackground).usingColorSpace(.deviceRGB))
        #expect(componentsAreClose(expectedSelection, actualSelection, tolerance: 0.01))

        // Distinct from what the accent-based fallback would have produced
        // (the cursor colour, ff00ff) — proves the theme's own selection
        // colour won, not the accent fallback.
        let accentColor = try #require(NSColor(palette.accent).usingColorSpace(.deviceRGB))
        #expect(!componentsAreClose(actualSelection, accentColor, tolerance: 0.05))
    }

    @Test("Selection colours fall back to the accent when the theme defines no selection colours")
    func selectionFallsBackToAccentWhenUndefined() throws {
        let definition = GhosttyThemeDefinition(
            name: "No Selection Theme",
            background: "1a1a1a",
            foreground: "eeeeee",
            cursorColor: "ff00ff",
            palette: [:]
        )
        let palette = DashPalette.themed(from: definition)

        let selection = try #require(NSColor(palette.selectionBackground).usingColorSpace(.deviceRGB))
        let accent = try #require(NSColor(palette.accent).usingColorSpace(.deviceRGB))
        #expect(componentsAreClose(selection, accent, tolerance: 0.01))
    }
}

private func componentsAreClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat) -> Bool {
    abs(a.redComponent - b.redComponent) < tolerance
        && abs(a.greenComponent - b.greenComponent) < tolerance
        && abs(a.blueComponent - b.blueComponent) < tolerance
}

private extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
