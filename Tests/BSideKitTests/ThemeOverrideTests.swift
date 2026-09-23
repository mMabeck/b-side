import Foundation
import Testing
@testable import BSideKit

/// Pure tests for ``ThemeOverride`` and its wiring into
/// `GhosttyBridge.resolveUserConfig`: no terminal surface, no libghostty
/// runtime, no real `UserDefaults` reads for the pure-function cases.
@MainActor
struct ThemeOverrideTests {
    @Test("useConfig yields no override, deferring to the config file's own directive")
    func useConfigYieldsNoDirective() {
        let directive = ThemeOverride.directive(
            mode: .useConfig,
            singleThemeName: "Ayu Mirage",
            lightThemeName: "Ayu Light",
            darkThemeName: "Ayu Mirage"
        )
        #expect(directive == nil)
    }

    @Test("single mode with a theme name yields a fixed directive")
    func singleModeYieldsFixedDirective() {
        let directive = ThemeOverride.directive(
            mode: .single,
            singleThemeName: "Ayu Mirage",
            lightThemeName: "",
            darkThemeName: ""
        )
        #expect(directive == .fixed("Ayu Mirage"))
    }

    @Test("single mode with an empty theme name yields no directive")
    func singleModeWithEmptyNameYieldsNoDirective() {
        let directive = ThemeOverride.directive(
            mode: .single,
            singleThemeName: "",
            lightThemeName: "",
            darkThemeName: ""
        )
        #expect(directive == nil)
    }

    @Test("matchSystem with both names yields an adaptive directive")
    func matchSystemYieldsAdaptiveDirective() {
        let directive = ThemeOverride.directive(
            mode: .matchSystem,
            singleThemeName: "",
            lightThemeName: "Ayu Light",
            darkThemeName: "Ayu Mirage"
        )
        #expect(directive == .adaptive(light: "Ayu Light", dark: "Ayu Mirage"))
    }

    @Test("matchSystem missing either name yields no directive")
    func matchSystemMissingNameYieldsNoDirective() {
        #expect(ThemeOverride.directive(mode: .matchSystem, singleThemeName: "", lightThemeName: "Ayu Light", darkThemeName: "") == nil)
        #expect(ThemeOverride.directive(mode: .matchSystem, singleThemeName: "", lightThemeName: "", darkThemeName: "Ayu Mirage") == nil)
    }

    @Test("currentDirective reads the same UserDefaults keys @AppStorage writes to")
    func currentDirectiveReadsUserDefaults() throws {
        let suiteName = "ThemeOverrideTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ThemeOverrideMode.single.rawValue, forKey: AppearanceSettingsKeys.mode)
        defaults.set("Ayu Mirage", forKey: AppearanceSettingsKeys.singleThemeName)

        #expect(ThemeOverride.currentDirective(defaults: defaults) == .fixed("Ayu Mirage"))
    }

    @Test("An override replaces the config file's own theme directive, keeping the rest of the config")
    func overrideReplacesConfigDirective() throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-override-test-\(UUID().uuidString)")
        let configDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "theme = Ayu Light\nfont-size = 14\n".write(
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

        let resolved = GhosttyBridge.resolveUserConfig(preferDark: true, override: .fixed("Ayu Mirage"))
        #expect(resolved.themeDefinition?.name == "Ayu Mirage")
        guard case let .generated(generated) = resolved.configSource else {
            Issue.record("expected a generated config source, got \(resolved.configSource)")
            return
        }
        #expect(generated.contains("font-size = 14"))
    }

    @Test("With no override, the config file's own directive still resolves")
    func noOverrideFallsBackToConfigDirective() throws {
        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-override-test-\(UUID().uuidString)")
        let configDir = configHome.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "theme = Ayu Light\n".write(
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

        let resolved = GhosttyBridge.resolveUserConfig(preferDark: true, override: nil)
        #expect(resolved.themeDefinition?.name == "Ayu Light")
    }

    @Test("An override still applies even with no config file present")
    func overrideAppliesWithNoConfigFile() throws {
        let emptyConfigHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-override-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyConfigHome, withIntermediateDirectories: true)
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

        let resolved = GhosttyBridge.resolveUserConfig(preferDark: true, override: .fixed("Ayu Mirage"))
        #expect(resolved.themeDefinition?.name == "Ayu Mirage")
    }

    @Test("An unknown override name falls back to no theme, same as an unknown config directive")
    func unknownOverrideNameFallsBack() {
        let resolved = GhosttyBridge.resolveThemeDefinition(.fixed("Definitely Not A Real Theme"), preferDark: true)
        #expect(resolved == nil)
    }

    @Test("Bundled brand themes resolve through the same lookup as the catalog")
    func bundledBrandThemeResolves() {
        let resolved = GhosttyBridge.resolveThemeDefinition(.fixed("B-Side"), preferDark: true)
        #expect(resolved?.name == "B-Side")
        #expect(resolved?.background == "16141c")
    }
}
