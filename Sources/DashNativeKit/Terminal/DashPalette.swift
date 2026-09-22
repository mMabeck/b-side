import AppKit
import GhosttyTheme
import SwiftUI

/// The whole app's semantic colour palette, derived from the user's resolved
/// Ghostty theme (``GhosttyResolvedTheme/palette``). Every region outside the
/// terminal grid — window chrome, sidebars, drawer, settings — reads colours
/// from here instead of hardcoding greys or leaning on system blue, so a
/// different Ghostty theme restyles the whole app for free.
///
/// Elevated surfaces, separators, and disabled text are never hardcoded
/// greys: they are the theme's own background blended a small amount toward
/// its own foreground, so they stay correctly related to *this* theme's
/// contrast rather than assuming any particular background lightness.
public struct DashPalette: Equatable, Sendable {
    /// Whether this palette's background reads as dark, per WCAG relative
    /// luminance. Drives ``preferredAppearance``.
    public let isDark: Bool

    /// Whether this palette should force a specific `NSAppearance` at all.
    /// `false` for ``fallback``, meaning "no opinion — let macOS apply the
    /// user's system appearance."
    private let forcesAppearance: Bool

    /// The `NSAppearance` the window should adopt so system-drawn chrome
    /// (scrollbars, menus, text-field carets, focus rings, traffic lights)
    /// matches instead of staying light. `nil` for ``fallback``, meaning
    /// "no opinion — let macOS apply the user's system appearance." Computed
    /// rather than stored: `NSAppearance` isn't `Sendable`.
    public var preferredAppearance: NSAppearance? {
        guard forcesAppearance else { return nil }
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Window/base background.
    public let windowBackground: Color
    /// First elevation step above the window background: sidebars, the
    /// terminal drawer.
    public let surfaceBackground: Color
    /// Second elevation step: cards and other content that should read as
    /// sitting above a surface.
    public let elevatedSurfaceBackground: Color
    /// Borders and separator lines.
    public let separator: Color

    public let textPrimary: Color
    public let textSecondary: Color
    public let textDisabled: Color

    /// Prefers the theme's own `selectionBackground`/`selectionForeground`
    /// where defined, falling back to the accent (background) and window
    /// background (foreground) otherwise.
    public let selectionBackground: Color
    public let selectionForeground: Color

    public let accent: Color

    public let statusRunning: Color
    public let statusNeedsAttention: Color
    public let statusError: Color
    public let statusSuccess: Color

    /// Standard system colours, all of which already adapt to the user's
    /// macOS light/dark appearance on their own. Used whenever no Ghostty
    /// theme has resolved, so the app never gets stuck looking broken just
    /// because `~/.config/ghostty/config` has no `theme` directive.
    public static let fallback = DashPalette(
        isDark: false,
        forcesAppearance: false,
        windowBackground: Color(nsColor: .windowBackgroundColor),
        surfaceBackground: Color(nsColor: .underPageBackgroundColor),
        elevatedSurfaceBackground: Color(nsColor: .controlBackgroundColor),
        separator: Color(nsColor: .separatorColor),
        textPrimary: Color(nsColor: .labelColor),
        textSecondary: Color(nsColor: .secondaryLabelColor),
        textDisabled: Color(nsColor: .tertiaryLabelColor),
        selectionBackground: Color(nsColor: .selectedContentBackgroundColor),
        selectionForeground: Color(nsColor: .selectedMenuItemTextColor),
        accent: Color.accentColor,
        statusRunning: .blue,
        statusNeedsAttention: .yellow,
        statusError: .red,
        statusSuccess: .green
    )

    /// Derives the full palette from a resolved Ghostty theme definition.
    public static func themed(from definition: GhosttyThemeDefinition) -> DashPalette {
        let background = RGBColor(hex: definition.background)
        let foreground = RGBColor(hex: definition.foreground)
        let dark = background.relativeLuminance < 0.5

        let accentColor = definition.cursorColor.map(RGBColor.init(hex:))
            ?? definition.palette[4].map(RGBColor.init(hex:))
            ?? foreground

        let selectionBg = definition.selectionBackground.map(RGBColor.init(hex:)) ?? accentColor
        let selectionFg = definition.selectionForeground.map(RGBColor.init(hex:)) ?? background

        // Derived from the theme's own foreground/background, never from a
        // raw palette slot (ANSI "bright black", palette[8], is meant for
        // terminal text on the terminal's own background and is sometimes
        // barely distinguishable from it — see native-rewrite.md's chrome
        // audit). `ensuringContrast` then guarantees legibility even if this
        // theme's foreground/background pair is itself unusually close.
        let secondaryText = foreground
            .blended(toward: background, amount: 0.25)
            .ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 4.5)
        let disabledText = foreground
            .blended(toward: background, amount: 0.45)
            .ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 3.0)

        func status(base: Int, bright: Int) -> Color {
            let hex = (dark ? definition.palette[bright] : nil) ?? definition.palette[base]
            return (hex.map(RGBColor.init(hex:)) ?? foreground).color
        }

        return DashPalette(
            isDark: dark,
            forcesAppearance: true,
            windowBackground: background.color,
            surfaceBackground: background.blended(toward: foreground, amount: 0.06).color,
            elevatedSurfaceBackground: background.blended(toward: foreground, amount: 0.12).color,
            separator: background.blended(toward: foreground, amount: 0.18).color,
            textPrimary: foreground.color,
            textSecondary: secondaryText.color,
            textDisabled: disabledText.color,
            selectionBackground: selectionBg.color,
            selectionForeground: selectionFg.color,
            accent: accentColor.color,
            statusRunning: status(base: 4, bright: 12),
            statusNeedsAttention: status(base: 3, bright: 11),
            statusError: status(base: 1, bright: 9),
            statusSuccess: status(base: 2, bright: 10)
        )
    }
}

/// Plain sRGB triple used only to compute blends and luminance before
/// converting to a SwiftUI `Color`. Kept private: nothing outside this file
/// should reason about theme colour in raw components.
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    /// Ghostty theme hex strings have no leading `#` (e.g. `"1f2430"`), but
    /// a leading `#` is tolerated too.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        r = Double((value & 0xFF0000) >> 16) / 255
        g = Double((value & 0x00FF00) >> 8) / 255
        b = Double(value & 0x0000FF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    /// WCAG relative luminance (sRGB-gamma-corrected), 0 (black) to 1
    /// (white). Threshold at 0.5 decides light vs dark for
    /// ``DashPalette/isDark``.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func blended(toward other: RGBColor, amount: Double) -> RGBColor {
        RGBColor(
            r: r + (other.r - r) * amount,
            g: g + (other.g - g) * amount,
            b: b + (other.b - b) * amount
        )
    }

    /// WCAG contrast ratio between two colours: `(lighter + 0.05) / (darker + 0.05)`,
    /// always ≥ 1. 4.5:1 is the WCAG AA floor for normal text, 3:1 for large or
    /// de-emphasised text.
    func contrastRatio(with other: RGBColor) -> Double {
        let (lighter, darker) = relativeLuminance >= other.relativeLuminance
            ? (relativeLuminance, other.relativeLuminance)
            : (other.relativeLuminance, relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Nudges `self` toward `foreground` until its contrast ratio against
    /// `background` reaches `minimumRatio`, or until it has all but reached
    /// `foreground` itself. This is the contrast guarantee for derived chrome
    /// text: no matter how close together a theme's foreground and background
    /// are, the text tones this app derives from them cannot land below a
    /// readable floor — the worst case is that they converge on the theme's
    /// own foreground colour instead of vanishing into the background.
    func ensuringContrast(against background: RGBColor, pulledToward foreground: RGBColor, minimumRatio: Double) -> RGBColor {
        var candidate = self
        for _ in 0..<24 {
            guard candidate.contrastRatio(with: background) < minimumRatio else { break }
            candidate = candidate.blended(toward: foreground, amount: 0.15)
        }
        return candidate
    }
}
