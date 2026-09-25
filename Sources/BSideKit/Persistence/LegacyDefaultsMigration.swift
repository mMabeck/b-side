import Foundation

/// Carries settings over from B-Side's previous bundle identifier,
/// `ai.syv.bside`, to the current one. `UserDefaults` is keyed by bundle
/// identifier, so without this the rename would silently reset every
/// preference (theme, sounds, volume, window state).
///
/// Keys already present under the new identifier win, and the legacy domain
/// is never modified or removed. The import is marked done only once a
/// legacy domain was actually found, so a failed or empty read is retried on
/// the next launch rather than suppressing it for good.
public enum LegacyDefaultsMigration {
    public static let legacyDomain = "ai.syv.bside"
    static let doneKey = "migration.legacyDefaultsImported"

    /// Call once at launch, before anything reads `UserDefaults`.
    public static func importIfNeeded(
        into defaults: UserDefaults = .standard,
        legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: legacyDomain)
    ) {
        guard !defaults.bool(forKey: doneKey), let legacy, !legacy.isEmpty else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
