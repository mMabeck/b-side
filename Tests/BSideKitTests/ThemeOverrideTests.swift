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

    @Test("Every featured theme name exists in the catalog and appears exactly once in the picker")
    func featuredThemesResolve() {
        let missing = ThemeCatalogSource.featuredNames.filter { GhosttyThemeCatalog.theme(named: $0) == nil }
        #expect(missing.isEmpty, "featured names missing from GhosttyThemeCatalog: \(missing)")

        let listed = (ThemeCatalogSource.featuredThemes() + ThemeCatalogSource.otherThemes()).map(\.name)
        #expect(listed.count == Set(listed).count)
        #expect(Set(listed) == Set(ThemeCatalogSource.allThemes().map(\.name)))
    }
}
