import AppKit
import GhosttyTheme
import SwiftUI

/// The whole app's semantic colour palette, derived from the user's resolved
/// Ghostty theme. Every region outside the terminal grid reads colours from
/// here instead of hardcoding greys, so a different theme restyles the whole app for free.
///
/// Elevated surfaces, separators, and disabled text are the theme's own
/// background blended toward its own foreground, so they stay correctly related to this theme's contrast.
public struct BSidePalette: Equatable, Sendable {
    /// Pulls `statusSuccess` unambiguously green rather than a theme's often yellowish-lime ANSI green.
    static let successHueRange: ClosedRange<Double> = 120...135

    /// Per WCAG relative luminance. Drives ``preferredAppearance``.
    public let isDark: Bool

    /// `false` for ``fallback``: no opinion, let macOS apply the system appearance.
    private let forcesAppearance: Bool

    /// `nil` for ``fallback``. Computed rather than stored: `NSAppearance` isn't `Sendable`.
    public var preferredAppearance: NSAppearance? {
        guard forcesAppearance else { return nil }
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    public let windowBackground: Color
    /// First elevation step above the window background: sidebars, the drawer.
    public let surfaceBackground: Color
    /// Second elevation step: cards and content sitting above a surface.
    public let elevatedSurfaceBackground: Color
    public let separator: Color

    public let textPrimary: Color
    public let textSecondary: Color
    public let textDisabled: Color

    /// Prefers the theme's own selection colours, falling back to accent/window background.
    public let selectionBackground: Color
    public let selectionForeground: Color

    public let accent: Color

    /// Amber/yellow, distinct from the blue "unread" and green "read" dots either side of it.
    public let statusRunning: Color
    /// A question, blocked, or vanished worktree; the most attention-grabbing colour.
    public let statusNeedsAttention: Color
    public let statusError: Color
    public let statusSuccess: Color
    public let statusUnread: Color

    /// Standard system colours, adapting to macOS light/dark on their own.
    /// Used whenever no Ghostty theme has resolved.
    public static let fallback = BSidePalette(
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
        statusRunning: .orange,
        statusNeedsAttention: Color(red: 0.85, green: 0.24, blue: 0.1),
        statusError: .red,
        statusSuccess: .green,
        statusUnread: .blue
    )

    public static func themed(from definition: GhosttyThemeDefinition) -> BSidePalette {
        let background = RGBColor(hex: definition.background)
        let foreground = RGBColor(hex: definition.foreground)
        let dark = background.relativeLuminance < 0.5

        let accentColor = definition.cursorColor.map(RGBColor.init(hex:))
            ?? definition.palette[4].map(RGBColor.init(hex:))
            ?? foreground

        let selectionBg = definition.selectionBackground.map(RGBColor.init(hex:)) ?? accentColor
        let selectionFg = definition.selectionForeground.map(RGBColor.init(hex:)) ?? background

        // Derived from foreground/background, never a raw palette slot (ANSI
        // "bright black" is sometimes barely distinguishable from the terminal's own background).
        let secondaryText = foreground
            .blended(toward: background, amount: 0.15)
            .ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 4.5)
        let disabledText = foreground
            .blended(toward: background, amount: 0.32)
            .ensuringContrast(against: background, pulledToward: foreground, minimumRatio: 3.0)

        func status(base: Int, bright: Int) -> RGBColor {
            let hex = (dark ? definition.palette[bright] : nil) ?? definition.palette[base]
            return hex.map(RGBColor.init(hex:)) ?? foreground
        }

        return BSidePalette(
            isDark: dark,
            forcesAppearance: true,
            windowBackground: background.color,
            surfaceBackground: background.blended(toward: foreground, amount: 0.09).color,
            elevatedSurfaceBackground: background.blended(toward: foreground, amount: 0.15).color,
            separator: background.blended(toward: foreground, amount: 0.24).color,
            textPrimary: foreground.color,
            textSecondary: secondaryText.color,
            textDisabled: disabledText.color,
            selectionBackground: selectionBg.color,
            selectionForeground: selectionFg.color,
            accent: accentColor.color,
            statusRunning: status(base: 3, bright: 11).color,
            // Blended toward the theme's own yellow so "question" reads orange-red, distinct from "running"'s amber.
            statusNeedsAttention: status(base: 1, bright: 9)
                .blended(toward: status(base: 3, bright: 11), amount: 0.35)
                .color,
            statusError: status(base: 1, bright: 9).color,
            // The theme's own ANSI green is often a yellowish lime (e.g. hue
            // ~80°), too far from "green" to read as success; nudged into a true-green hue band.
            statusSuccess: status(base: 2, bright: 10).huePulled(intoRange: BSidePalette.successHueRange).color,
            statusUnread: status(base: 4, bright: 12).color
        )
    }
}

/// Plain sRGB triple for blends/luminance before converting to `Color`.
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    /// Ghostty hex strings have no leading `#`, but one is tolerated.
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

    /// WCAG relative luminance, 0 (black) to 1 (white). Threshold at 0.5 decides ``BSidePalette/isDark``.
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

    /// Achromatic colours (r == g == b) have an undefined hue, reported as 0.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxComponent = max(r, g, b)
        let minComponent = min(r, g, b)
        let lightness = (maxComponent + minComponent) / 2
        guard maxComponent != minComponent else { return (0, 0, lightness) }

        let delta = maxComponent - minComponent
        let saturation = lightness > 0.5 ? delta / (2 - maxComponent - minComponent) : delta / (maxComponent + minComponent)

        var hue: Double
        switch maxComponent {
        case r: hue = (g - b) / delta + (g < b ? 6 : 0)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        return (hue, saturation, lightness)
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        guard saturation > 0 else {
            self.init(r: lightness, g: lightness, b: lightness)
            return
        }
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hPrime = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r0, g0, b0): (Double, Double, Double)
        switch hPrime {
        case 0..<1: (r0, g0, b0) = (c, x, 0)
        case 1..<2: (r0, g0, b0) = (x, c, 0)
        case 2..<3: (r0, g0, b0) = (0, c, x)
        case 3..<4: (r0, g0, b0) = (0, x, c)
        case 4..<5: (r0, g0, b0) = (x, 0, c)
        default: (r0, g0, b0) = (c, 0, x)
        }
        self.init(r: r0 + m, g: g0 + m, b: b0 + m)
    }

    /// Nudges hue to the nearer edge of `range`, leaving saturation/lightness
    /// untouched. Greys (negligible saturation) are left alone.
    func huePulled(intoRange range: ClosedRange<Double>, minimumSaturation: Double = 0.15) -> RGBColor {
        let (hue, saturation, lightness) = hsl
        guard saturation >= minimumSaturation, !range.contains(hue) else { return self }
        let distanceToLower = abs(hue - range.lowerBound)
        let distanceToUpper = abs(hue - range.upperBound)
        let target = distanceToLower <= distanceToUpper ? range.lowerBound : range.upperBound
        return RGBColor(hue: target, saturation: saturation, lightness: lightness)
    }

    /// `(lighter + 0.05) / (darker + 0.05)`, always ≥ 1. 4.5:1 is the WCAG AA floor for normal text, 3:1 for large text.
    func contrastRatio(with other: RGBColor) -> Double {
        let (lighter, darker) = relativeLuminance >= other.relativeLuminance
            ? (relativeLuminance, other.relativeLuminance)
            : (other.relativeLuminance, relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Nudges toward `foreground` until contrast against `background` reaches
    /// `minimumRatio`; worst case converges on `foreground` rather than vanishing into the background.
    func ensuringContrast(against background: RGBColor, pulledToward foreground: RGBColor, minimumRatio: Double) -> RGBColor {
        var candidate = self
        for _ in 0..<24 {
            guard candidate.contrastRatio(with: background) < minimumRatio else { break }
            candidate = candidate.blended(toward: foreground, amount: 0.15)
        }
        return candidate
    }
}
