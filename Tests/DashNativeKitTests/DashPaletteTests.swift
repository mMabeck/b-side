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

    // MARK: - Secondary/disabled text derivation and contrast guarantee

    @Test("Secondary text is not the theme's palette[8], even when that slot is nearly invisible on its background")
    func secondaryTextIgnoresPaletteIndexEight() throws {
        // Ayu Mirage: palette[8] ("bright black") is 686868, barely off its
        // 1f2430 background. If textSecondary were still reading palette[8]
        // this would land close to it; deriving from foreground instead
        // should not.
        let ayuMirage = try #require(GhosttyThemeCatalog.theme(named: "Ayu Mirage"))
        #expect(ayuMirage.palette[8] == "686868")

        let palette = DashPalette.themed(from: ayuMirage)
        let secondary = try #require(NSColor(palette.textSecondary).usingColorSpace(.deviceRGB))
        let bright8 = try #require(NSColor(Color(hex: "686868")).usingColorSpace(.deviceRGB))

        #expect(!componentsAreClose(secondary, bright8, tolerance: 0.05))
    }

    @Test("Secondary and disabled text meet a readable contrast floor against the background, even for a hostile theme")
    func hostileThemeStillProducesReadableSecondaryAndDisabledText() throws {
        // A deliberately hostile theme: foreground and background contrast
        // normally (like any usable terminal theme), but every ANSI slot,
        // including index 8, sits right next to the background — exactly the
        // shape of theme that broke chrome text before this fix, so any
        // derivation that still trusted the palette instead of deriving from
        // foreground (backed by the contrast guarantee) would fail here.
        let hostile = GhosttyThemeDefinition(
            name: "Hostile",
            background: "1a1a1a",
            foreground: "f0f0f0",
            palette: [8: "1f1f1f"]
        )
        let palette = DashPalette.themed(from: hostile)
        let background = RGBColor(hex: hostile.background)
        let secondary = rgbColor(from: palette.textSecondary)
        let disabled = rgbColor(from: palette.textDisabled)

        #expect(secondary.contrastRatio(with: background) >= 4.5 - 0.01)
        #expect(disabled.contrastRatio(with: background) >= 3.0 - 0.01)
    }

    // MARK: - Contrast-guarantee helper

    @Test("ensuringContrast leaves a colour untouched once it already clears the minimum ratio")
    func ensuringContrastNoOpWhenAlreadyReadable() {
        let background = RGBColor(hex: "000000")
        let foreground = RGBColor(hex: "ffffff")
        let alreadyReadable = RGBColor(hex: "aaaaaa")

        let result = alreadyReadable.ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 3.0)
        #expect(result == alreadyReadable)
    }

    @Test("ensuringContrast pulls a too-close colour toward the foreground until it clears the minimum ratio")
    func ensuringContrastPullsTowardForegroundUntilReadable() {
        let background = RGBColor(hex: "1f2430")
        let foreground = RGBColor(hex: "cbccc6")
        let tooClose = RGBColor(hex: "242938")

        #expect(tooClose.contrastRatio(with: background) < 4.5)

        let result = tooClose.ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 4.5)
        #expect(result.contrastRatio(with: background) >= 4.5 - 0.01)
    }

    @Test("ensuringContrast still terminates and does no worse when even the foreground can't clear the floor")
    func ensuringContrastBestEffortWhenForegroundItselfIsUnreadable() {
        // foreground and background are near-identical: no amount of pulling
        // toward foreground can reach an unreasonably high floor, but the
        // helper must still terminate and never end up less readable than
        // where it started.
        let background = RGBColor(hex: "202020")
        let foreground = RGBColor(hex: "212121")
        let candidate = RGBColor(hex: "202020")
        let startingRatio = candidate.contrastRatio(with: background)

        let result = candidate.ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 21.0)
        #expect(result.contrastRatio(with: background) >= startingRatio)
    }
}

private func componentsAreClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat) -> Bool {
    abs(a.redComponent - b.redComponent) < tolerance
        && abs(a.greenComponent - b.greenComponent) < tolerance
        && abs(a.blueComponent - b.blueComponent) < tolerance
}

/// Recovers an `RGBColor` (this module's internal blend/contrast type) from a
/// resolved `Color`, for asserting on palette output without exposing test
/// plumbing in the palette's own API.
private func rgbColor(from color: Color) -> DashNativeKit.RGBColor {
    let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
    return DashNativeKit.RGBColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
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
