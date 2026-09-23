import AppKit

/// `settings.notifications.*` `@AppStorage` keys, shared between
/// `SettingsView` and the alert-handling code that reads them outside
/// SwiftUI (`TaskAlertSoundPlayer`, `ProjectsStore`).
public enum TaskAlertSettingsKeys {
    public static let enabled = "settings.notifications.enabled"
    public static let soundsEnabled = "settings.notifications.playSounds"
    public static let finishedSound = "settings.notifications.finishedSound"
    public static let questionSound = "settings.notifications.questionSound"
    public static let volume = "settings.notifications.volume"
}

/// One of the macOS system sounds in `/System/Library/Sounds`, offerable as
/// a per-alert-kind notification sound, plus "Off" to silence a kind
/// without disabling notification sounds altogether. `rawValue` is both the
/// persisted `@AppStorage` string and the name `NSSound(named:)` expects.
public enum TaskAlertSound: String, CaseIterable, Identifiable, Sendable {
    case off = "None"
    case basso = "Basso"
    case glass = "Glass"
    case hero = "Hero"
    case ping = "Ping"
    case pop = "Pop"
    case submarine = "Submarine"
    case tink = "Tink"

    public var id: String { rawValue }

    public static let defaultFinished: TaskAlertSound = .glass
    public static let defaultQuestion: TaskAlertSound = .tink

    @MainActor
    public func play(volume: Double) {
        guard self != .off, let sound = NSSound(named: rawValue) else { return }
        sound.volume = Float(max(0, min(100, volume)) / 100)
        sound.play()
    }
}

/// Plays the configured sound for an alert kind, reading settings directly
/// from `UserDefaults` — the alert-handling path runs outside SwiftUI, so it
/// can't read `@AppStorage` bindings the way `SettingsView` does. Defaults
/// mirror the ones `SettingsView`'s `@AppStorage` declares, since a key
/// `@AppStorage` has never written yet reads back as absent, not as its
/// SwiftUI-side default.
public enum TaskAlertSoundPlayer {
    public static let defaultVolume: Double = 70

    /// Pure so it's directly testable: the sound a kind resolves to given
    /// whatever `@AppStorage` string (or `nil`, if never written) is stored
    /// for it.
    public static func resolvedSound(for kind: TaskAlertKind, storedName: String?) -> TaskAlertSound {
        let fallback = kind == .finished ? TaskAlertSound.defaultFinished : TaskAlertSound.defaultQuestion
        guard let storedName else { return fallback }
        return TaskAlertSound(rawValue: storedName) ?? fallback
    }

    /// Pure so it's directly testable: the volume to play at given whatever
    /// `@AppStorage` value (or `nil`, if never written) is stored.
    public static func resolvedVolume(stored: Double?) -> Double {
        stored ?? defaultVolume
    }

    @MainActor
    public static func play(kind: TaskAlertKind, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: TaskAlertSettingsKeys.soundsEnabled) as? Bool ?? true else { return }
        let key = kind == .finished ? TaskAlertSettingsKeys.finishedSound : TaskAlertSettingsKeys.questionSound
        let sound = resolvedSound(for: kind, storedName: defaults.string(forKey: key))
        let volume = resolvedVolume(stored: defaults.object(forKey: TaskAlertSettingsKeys.volume) as? Double)
        sound.play(volume: volume)
    }
}
