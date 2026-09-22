import Foundation
import Testing
@testable import DashNativeKit

/// Pure config-parsing tests: no terminal surface, no libghostty runtime.
/// Exercises the `theme = ...` extraction/resolution pipeline in
/// `GhosttyBridge` that keeps a name it cannot resolve from rejecting the
/// rest of the user's config.
@MainActor
struct GhosttyThemeConfigTests {
    @Test("Plain `theme = Name` is extracted and the line removed")
    func plainThemeForm() {
        let contents = """
        font-size = 14
        theme = Ayu Mirage
        cursor-style = bar
        """
        let (sanitized, directive) = GhosttyBridge.extractThemeDirective(from: contents)
        #expect(directive == .fixed("Ayu Mirage"))
        #expect(!sanitized.contains("theme"))
        #expect(sanitized.contains("font-size = 14"))
        #expect(sanitized.contains("cursor-style = bar"))
    }

    @Test("light:/dark: adaptive form is parsed into both names")
    func adaptiveThemeForm() {
        let contents = "theme = light:Ayu Light,dark:Ayu Mirage"
        let (_, directive) = GhosttyBridge.extractThemeDirective(from: contents)
        #expect(directive == .adaptive(light: "Ayu Light", dark: "Ayu Mirage"))
    }

    @Test("Adaptive form resolves against the given appearance")
    func adaptiveThemeResolution() {
        let directive = GhosttyBridge.ThemeDirective.adaptive(light: "Ayu Light", dark: "Ayu Mirage")
        let dark = GhosttyBridge.resolveThemeDefinition(directive, preferDark: true)
        let light = GhosttyBridge.resolveThemeDefinition(directive, preferDark: false)
        #expect(dark?.name == "Ayu Mirage")
        #expect(light?.name == "Ayu Light")
    }

    @Test("Comments and stray whitespace around the directive are ignored")
    func commentsAndWhitespace() {
        let contents = """
        # this is the user's ghostty config
        \t  theme   =   Ayu Mirage
        # theme = this looks like a directive but is commented out
          font-size = 14
        """
        let (sanitized, directive) = GhosttyBridge.extractThemeDirective(from: contents)
        #expect(directive == .fixed("Ayu Mirage"))
        #expect(sanitized.contains("# this is the user's ghostty config"))
        #expect(sanitized.contains("# theme = this looks like a directive but is commented out"))
        #expect(sanitized.contains("font-size = 14"))
    }

    @Test("A missing or unknown theme name resolves to nil and is logged, not thrown")
    func unknownThemeName() {
        let directive = GhosttyBridge.ThemeDirective.fixed("Definitely Not A Real Theme")
        let resolved = GhosttyBridge.resolveThemeDefinition(directive, preferDark: true)
        #expect(resolved == nil)
    }

    @Test("A known theme name resolves to its full catalog definition")
    func knownThemeName() {
        let directive = GhosttyBridge.ThemeDirective.fixed("Ayu Mirage")
        let resolved = GhosttyBridge.resolveThemeDefinition(directive, preferDark: true)
        #expect(resolved?.name == "Ayu Mirage")
        #expect(resolved?.background == "1f2430")
    }

    @Test("An absent config file (via a relocated XDG_CONFIG_HOME) resolves to no path and no theme")
    func absentConfigFile() {
        let emptyConfigHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-theme-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyConfigHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyConfigHome) }

        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", emptyConfigHome.path, 1)
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }

        #expect(GhosttyBridge.userConfigFilePath == nil)

        let resolved = GhosttyBridge.resolveUserConfig(preferDark: true)
        #expect(resolved.configSource == .none)
        #expect(resolved.themeDefinition == nil)
    }

    @Test("A config with an unresolvable theme still yields the user's other settings")
    func unresolvableThemeKeepsRestOfConfig() {
        let contents = """
        theme = Definitely Not A Real Theme
        font-size = 14
        font-thicken = true
        font-thicken-strength = 70
        cursor-style = bar
        cursor-style-blink = true
        window-padding-x = 8
        window-padding-y = 6
        background-opacity = 0.98
        """
        let (sanitized, directive) = GhosttyBridge.extractThemeDirective(from: contents)
        let resolved = GhosttyBridge.resolveThemeDefinition(directive, preferDark: true)

        #expect(resolved == nil)
        #expect(!sanitized.contains("theme"))
        #expect(sanitized.contains("font-size = 14"))
        #expect(sanitized.contains("font-thicken = true"))
        #expect(sanitized.contains("font-thicken-strength = 70"))
        #expect(sanitized.contains("cursor-style = bar"))
        #expect(sanitized.contains("cursor-style-blink = true"))
        #expect(sanitized.contains("window-padding-x = 8"))
        #expect(sanitized.contains("window-padding-y = 6"))
        #expect(sanitized.contains("background-opacity = 0.98"))
    }
}
