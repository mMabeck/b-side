import GhosttyTheme
import Foundation
import Testing
@testable import BSideKit

/// Pure tests for ``ThemeOverride`` and its wiring into
/// `GhosttyBridge.resolveUserConfig`: no terminal surface, no libghostty
/// runtime, no real `UserDefaults` reads for the pure-function cases.
@MainActor
struct ThemeOverrideTests {
    @Test("directive(mode:) defers to the config in useConfig mode, and in single mode is fixed unless the name is empty", arguments: [
        (mode: ThemeOverrideMode.useConfig, name: "Ayu Mirage", expected: nil),
        (mode: ThemeOverrideMode.single, name: "Ayu Mirage", expected: GhosttyBridge.ThemeDirective.fixed("Ayu Mirage")),
        (mode: ThemeOverrideMode.single, name: "", expected: nil),
    ])
    func directiveForMode(mode: ThemeOverrideMode, name: String, expected: GhosttyBridge.ThemeDirective?) {
        let directive = ThemeOverride.directive(mode: mode, singleThemeName: name)
        #expect(directive == expected)
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

    @Test("A stored matchSystem mode migrates to Single Theme using the old dark theme name, or falls back to Use Ghostty Config when there isn't one", arguments: [
        (legacyDarkThemeName: "Ayu Mirage", expected: GhosttyBridge.ThemeDirective.fixed("Ayu Mirage")),
        (legacyDarkThemeName: "", expected: nil),
    ])
    func legacyMatchSystemMigrates(legacyDarkThemeName: String, expected: GhosttyBridge.ThemeDirective?) {
        let directive = ThemeOverride.directive(
            rawMode: "matchSystem",
            singleThemeName: "",
            legacyDarkThemeName: legacyDarkThemeName
        )
        #expect(directive == expected)
    }

    @Test("currentDirective migrates a prior install's stored matchSystem mode")
    func currentDirectiveMigratesLegacyMatchSystem() throws {
        let suiteName = "ThemeOverrideTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("matchSystem", forKey: AppearanceSettingsKeys.mode)
        defaults.set("Ayu Mirage", forKey: "settings.appearance.darkThemeName")

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

        let resolved = GhosttyBridge.resolveUserConfig(override: .fixed("Ayu Mirage"))
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

        let resolved = GhosttyBridge.resolveUserConfig(override: nil)
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

        let resolved = GhosttyBridge.resolveUserConfig(override: .fixed("Ayu Mirage"))
        #expect(resolved.themeDefinition?.name == "Ayu Mirage")
    }

    @Test("Bundled brand themes resolve through the same lookup as the catalog")
    func bundledBrandThemeResolves() {
        let resolved = GhosttyBridge.resolveThemeDefinition(.fixed("B-Side"))
        #expect(resolved?.name == "B-Side")
        #expect(resolved?.background == "16141c")
    }

    @Test("Every featured theme name exists in the catalog and appears exactly once in the picker")
    func featuredThemesResolve() {
        let missing = ThemeCatalogSource.featuredNames.filter { GhosttyThemeCatalog.theme(named: $0) == nil }
        #expect(missing.isEmpty, "featured names missing from GhosttyThemeCatalog: \(missing)")

        let listed = (ThemeCatalogSource.featuredThemes() + ThemeCatalogSource.otherThemes()).map(\.name)
        #expect(listed.count == Set(listed).count)
        #expect(Set(listed) == Set(ThemeCatalogSource.allThemes().map(\.name)))
    }
}
