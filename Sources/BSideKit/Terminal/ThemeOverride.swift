import Foundation

/// Grouped here so ``SettingsView`` and ``ThemeOverride`` agree on the exact strings.
enum AppearanceSettingsKeys {
    static let mode = "settings.appearance.mode"
    static let singleThemeName = "settings.appearance.singleThemeName"
}

/// The retired Match System mode's raw value; B-Side no longer offers it,
/// but a prior install may still have it stored.
private let legacyMatchSystemRawValue = "matchSystem"

/// Kept only so the migration below can read a prior install's dark-theme slot.
private let legacyDarkThemeNameKey = "settings.appearance.darkThemeName"

enum ThemeOverrideMode: String, CaseIterable {
    /// Whatever `theme = ...` directive is in `~/.config/ghostty/config` wins.
    case useConfig
    /// One catalog theme name, regardless of the user's own config.
    case single

    var label: String {
        switch self {
        case .useConfig: "Use Ghostty Config"
        case .single: "Single Theme"
        }
    }
}

/// Turns the Appearance tab's preference into a ``GhosttyBridge/ThemeDirective``
/// so it can override ``GhosttyBridge/resolveUserConfig(override:)``. Kept
/// pure, not a `UserDefaults` reader, so it's trivially testable; ``currentDirective(defaults:)`` is the thin wrapper callers use.
enum ThemeOverride {
    static func directive(
        mode: ThemeOverrideMode,
        singleThemeName: String
    ) -> GhosttyBridge.ThemeDirective? {
        switch mode {
        case .useConfig:
            return nil
        case .single:
            guard !singleThemeName.isEmpty else { return nil }
            return .fixed(singleThemeName)
        }
    }

    /// Migrates the retired Match System mode to Single Theme on the fly: a
    /// prior install's dark-theme slot becomes the single theme name, or falls back to Use Ghostty Config if empty.
    static func directive(
        rawMode: String?,
        singleThemeName: String,
        legacyDarkThemeName: String
    ) -> GhosttyBridge.ThemeDirective? {
        if rawMode == legacyMatchSystemRawValue {
            return legacyDarkThemeName.isEmpty ? nil : .fixed(legacyDarkThemeName)
        }
        let mode = ThemeOverrideMode(rawValue: rawMode ?? "") ?? .useConfig
        return directive(mode: mode, singleThemeName: singleThemeName)
    }

    /// `defaults` is the same store `@AppStorage` writes to.
    static func currentDirective(defaults: UserDefaults = .standard) -> GhosttyBridge.ThemeDirective? {
        directive(
            rawMode: defaults.string(forKey: AppearanceSettingsKeys.mode),
            singleThemeName: defaults.string(forKey: AppearanceSettingsKeys.singleThemeName) ?? "",
            legacyDarkThemeName: defaults.string(forKey: legacyDarkThemeNameKey) ?? ""
        )
    }
}
