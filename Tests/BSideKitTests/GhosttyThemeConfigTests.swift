import Foundation
import Testing
@testable import BSideKit

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

    @Test("An absent config file (via a relocated XDG_CONFIG_HOME) still releases the app's own key equivalents")
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
        #expect(resolved.themeDefinition == nil)
        // Generated, not `.none`: the unbinds below must reach the surface
        // even when the user has no Ghostty config at all.
        #expect(resolved.configSource == .generated(GhosttyBridge.appOwnedKeybinds))
    }

    @Test("A config file that exists but can't be read still falls back to the generated unbinds")
    func unreadableConfigFileFallsBackToGenerated() throws {
        guard getuid() != 0 else {
            // root ignores POSIX permission bits, so chmod-based
            // unreadability doesn't apply when tests run elevated.
            return
        }

        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-unreadable-test-\(UUID().uuidString)")
        let configDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configPath = configDir.appendingPathComponent("config")
        try "theme = Ayu Mirage\n".write(to: configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: configPath.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configPath.path)
            try? FileManager.default.removeItem(at: configHome)
        }

        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }

        // The file exists, so this is a read failure, not an absent config.
        #expect(GhosttyBridge.userConfigFilePath != nil)

        let resolved = GhosttyBridge.resolveUserConfig(preferDark: true)
        #expect(resolved.themeDefinition == nil)
        #expect(resolved.configSource == .generated(GhosttyBridge.appOwnedKeybinds))
    }

    /// `AppTerminalView.performKeyEquivalent` consumes any key Ghostty binds
    /// before the main menu is offered it, so a shortcut the app's own menu
    /// owns has to be released from Ghostty's defaults or the menu item
    /// silently never fires. `cmd+,` (Ghostty's `open_config`) is the one
    /// that actually broke Settings.
    @Test("Every config path unbinds the key equivalents the app's own menus own")
    func generatedConfigUnbindsAppOwnedKeys() throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-keybind-test-\(UUID().uuidString)")
        let configDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configHome) }

        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }

        // Both branches that read a real file: one with a `theme` directive
        // to strip and one without, since they build their config source
        // separately and either could drop the unbinds.
        for contents in ["theme = Ayu Mirage\nfont-size = 14\n", "font-size = 14\n"] {
            try contents.write(
                to: configDir.appendingPathComponent("config"),
                atomically: true,
                encoding: .utf8
            )

            let resolved = GhosttyBridge.resolveUserConfig(preferDark: true)
            guard case let .generated(generated) = resolved.configSource else {
                Issue.record("expected a generated config source, got \(resolved.configSource)")
                return
            }
            #expect(generated.contains("keybind = cmd+,=unbind"))
            // The user's own settings must survive the append.
            #expect(generated.contains("font-size = 14"))
        }
    }

    @Test("resolveEagerly publishes the resolved theme independent of any terminal surface")
    func resolveEagerlyPublishesWithoutATerminalSurface() throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-theme-test-\(UUID().uuidString)")
        let configDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "theme = Ayu Mirage\n".write(
            to: configDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: configHome) }

        let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configHome.path, 1)
        defer {
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }

        // A private instance, not `.shared`: other suites (e.g.
        // `ContentViewThemeSnapshotTests`) read/write the process-global
        // singleton concurrently, so asserting against it here would race.
        let target = GhosttyResolvedTheme()
        #expect(target.definition == nil)

        GhosttyResolvedTheme.resolveEagerly(into: target)

        #expect(target.definition?.name == "Ayu Mirage")
        #expect(target.palette.isDark)
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
