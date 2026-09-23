import Foundation

/// `UserDefaults`/`@AppStorage` keys backing the Appearance tab's theme
/// override. Grouped here so ``SettingsView`` and ``ThemeOverride`` agree on
/// the exact strings without importing one another's private state.
enum AppearanceSettingsKeys {
    static let mode = "settings.appearance.mode"
    static let singleThemeName = "settings.appearance.singleThemeName"
}

/// The raw `mode` value written by the retired Match System mode. B-Side no
/// longer offers it — the app's appearance is derived from the chosen theme
/// alone, never the macOS system setting — but a prior install may still
/// have it stored; see ``ThemeOverride/directive(rawMode:singleThemeName:legacyDarkThemeName:)``.
private let legacyMatchSystemRawValue = "matchSystem"

/// The `UserDefaults` key Match System used to store its dark-theme slot,
/// kept only so the migration above can still read a prior install's value.
private let legacyDarkThemeNameKey = "settings.appearance.darkThemeName"

/// How the Appearance tab picks a theme, mirrored 1:1 by
/// ``AppearanceSettingsKeys/mode``'s stored raw value.
enum ThemeOverrideMode: String, CaseIterable {
    /// The default: behaviour is unchanged from before this feature existed
    /// — whatever `theme = ...` directive (if any) is in the user's own
    /// `~/.config/ghostty/config` wins.
    case useConfig
    /// One catalog theme name, used regardless of the user's own config.
    case single

    var label: String {
        switch self {
        case .useConfig: "Use Ghostty Config"
        case .single: "Single Theme"
        }
    }
}

/// Turns the Appearance tab's stored preference into an optional
/// ``GhosttyBridge/ThemeDirective``, the same shape `GhosttyBridge` already
/// extracts from a config file's `theme = ...` line — so it can be fed
/// straight into ``GhosttyBridge/resolveUserConfig(override:)`` as a
/// stand-in for (and override of) whatever the config file itself says.
/// Kept as a pure function of its inputs, not a `UserDefaults` reader, so it
/// is trivially testable; ``currentDirective(defaults:)`` below is the thin
/// `UserDefaults`-reading wrapper actual callers use.
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

    /// Resolves the raw `UserDefaults` values into a directive, migrating
    /// the retired Match System mode (``legacyMatchSystemRawValue``) to
    /// Single Theme on the fly: a prior install's stored dark-theme slot
    /// becomes the single theme name, or the mode falls back to Use Ghostty
    /// Config if that slot was itself empty. Kept as a pure function of its
    /// inputs, not a `UserDefaults` reader, so the migration is trivially
    /// testable; ``currentDirective(defaults:)`` below is the thin
    /// `UserDefaults`-reading wrapper actual callers use.
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

    /// Reads the Appearance tab's current preference straight from
    /// `defaults` — the same store `@AppStorage` writes to (`.standard` by
    /// default), so this reflects whatever the Settings window last set.
    static func currentDirective(defaults: UserDefaults = .standard) -> GhosttyBridge.ThemeDirective? {
        directive(
            rawMode: defaults.string(forKey: AppearanceSettingsKeys.mode),
            singleThemeName: defaults.string(forKey: AppearanceSettingsKeys.singleThemeName) ?? "",
            legacyDarkThemeName: defaults.string(forKey: legacyDarkThemeNameKey) ?? ""
        )
    }
}
