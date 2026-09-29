import AppKit
import GhosttyTheme
import SwiftUI
import Testing

@testable import BSideKit

@MainActor
struct BSidePaletteTests {
    @Test("A known dark theme resolves as dark and forces darkAqua; a known light theme resolves as light and forces aqua", arguments: [
        (themeName: "Ayu Mirage", isDark: true, appearance: NSAppearance.Name.darkAqua),
        (themeName: "Ayu Light", isDark: false, appearance: NSAppearance.Name.aqua),
    ])
    func themeResolvesExpectedAppearance(themeName: String, isDark: Bool, appearance: NSAppearance.Name) throws {
        let theme = try #require(GhosttyThemeCatalog.theme(named: themeName))
        let palette = BSidePalette.themed(from: theme)
        #expect(palette.isDark == isDark)
        #expect(palette.preferredAppearance?.name == appearance)
    }

    @Test("Secondary and disabled text meet a readable contrast floor against the background, even for a hostile theme")
    func hostileThemeStillProducesReadableSecondaryAndDisabledText() throws {
        // Hostile theme: every ANSI slot, including index 8, sits next to the background; chrome text must derive from foreground.
        let hostile = GhosttyThemeDefinition(
            name: "Hostile",
            background: "1a1a1a",
            foreground: "f0f0f0",
            palette: [8: "1f1f1f"]
        )
        let palette = BSidePalette.themed(from: hostile)
        let background = RGBColor(hex: hostile.background)
        let secondary = rgbColor(from: palette.textSecondary)
        let disabled = rgbColor(from: palette.textDisabled)

        #expect(secondary.contrastRatio(with: background) >= 4.5 - 0.01)
        #expect(disabled.contrastRatio(with: background) >= 3.0 - 0.01)
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
}

private func rgbColor(from color: Color) -> BSideKit.RGBColor {
    let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
    return BSideKit.RGBColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
}
