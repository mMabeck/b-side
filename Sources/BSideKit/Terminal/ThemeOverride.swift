import Foundation

/// `UserDefaults`/`@AppStorage` keys backing the Appearance tab's theme
/// override. Grouped here so ``SettingsView`` and ``ThemeOverride`` agree on
/// the exact strings without importing one another's private state.
enum AppearanceSettingsKeys {
    static let mode = "settings.appearance.mode"
    static let singleThemeName = "settings.appearance.singleThemeName"
    static let lightThemeName = "settings.appearance.lightThemeName"
    static let darkThemeName = "settings.appearance.darkThemeName"
}

/// How the Appearance tab picks a theme, mirrored 1:1 by
/// ``AppearanceSettingsKeys/mode``'s stored raw value.
enum ThemeOverrideMode: String, CaseIterable {
    /// The default: behaviour is unchanged from before this feature existed
    /// — whatever `theme = ...` directive (if any) is in the user's own
    /// `~/.config/ghostty/config` wins.
    case useConfig
    /// One catalog theme name, used regardless of the user's own config or
    /// system appearance.
    case single
    /// A light theme name and a dark theme name, switched the same way the
    /// config file's own `theme = light:X,dark:Y` form would be.
    case matchSystem

    var label: String {
        switch self {
        case .useConfig: "Use Ghostty Config"
        case .single: "Single Theme"
        case .matchSystem: "Match System"
        }
    }
}

/// Turns the Appearance tab's stored preference into an optional
/// ``GhosttyBridge/ThemeDirective``, the same shape `GhosttyBridge` already
/// extracts from a config file's `theme = ...` line — so it can be fed
/// straight into ``GhosttyBridge/resolveUserConfig(preferDark:override:)``
/// as a stand-in for (and override of) whatever the config file itself says.
/// Kept as a pure function of its inputs, not a `UserDefaults` reader, so it
/// is trivially testable; ``currentDirective(defaults:)`` below is the thin
/// `UserDefaults`-reading wrapper actual callers use.
enum ThemeOverride {
    static func directive(
        mode: ThemeOverrideMode,
        singleThemeName: String,
        lightThemeName: String,
        darkThemeName: String
    ) -> GhosttyBridge.ThemeDirective? {
        switch mode {
        case .useConfig:
            return nil
        case .single:
            guard !singleThemeName.isEmpty else { return nil }
            return .fixed(singleThemeName)
        case .matchSystem:
            guard !lightThemeName.isEmpty, !darkThemeName.isEmpty else { return nil }
            return .adaptive(light: lightThemeName, dark: darkThemeName)
        }
    }

    /// Reads the Appearance tab's current preference straight from
    /// `defaults` — the same store `@AppStorage` writes to (`.standard` by
    /// default), so this reflects whatever the Settings window last set.
    static func currentDirective(defaults: UserDefaults = .standard) -> GhosttyBridge.ThemeDirective? {
        let mode = ThemeOverrideMode(rawValue: defaults.string(forKey: AppearanceSettingsKeys.mode) ?? "") ?? .useConfig
        return directive(
            mode: mode,
            singleThemeName: defaults.string(forKey: AppearanceSettingsKeys.singleThemeName) ?? "",
            lightThemeName: defaults.string(forKey: AppearanceSettingsKeys.lightThemeName) ?? "",
            darkThemeName: defaults.string(forKey: AppearanceSettingsKeys.darkThemeName) ?? ""
        )
    }
}
