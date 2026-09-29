import Foundation

enum AppearanceSettingsKeys {
    static let mode = "settings.appearance.mode"
    static let singleThemeName = "settings.appearance.singleThemeName"
}

/// Retired Match System mode; a prior install may still have it stored.
private let legacyMatchSystemRawValue = "matchSystem"

/// Kept only so the migration below can read a prior install's dark-theme slot.
private let legacyDarkThemeNameKey = "settings.appearance.darkThemeName"

enum ThemeOverrideMode: String, CaseIterable {
    case useConfig
    case single

    var label: String {
        switch self {
        case .useConfig: "Use Ghostty Config"
        case .single: "Single Theme"
        }
    }
}

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

    static func currentDirective(defaults: UserDefaults = .standard) -> GhosttyBridge.ThemeDirective? {
        directive(
            rawMode: defaults.string(forKey: AppearanceSettingsKeys.mode),
            singleThemeName: defaults.string(forKey: AppearanceSettingsKeys.singleThemeName) ?? "",
            legacyDarkThemeName: defaults.string(forKey: legacyDarkThemeNameKey) ?? ""
        )
    }
}
