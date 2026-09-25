import Foundation
import Testing
@testable import BSideKit

struct LegacyDefaultsMigrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "legacy-defaults-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("copies legacy settings without overwriting ones already set, once")
    func importsOnceWithoutOverwriting() {
        let defaults = makeDefaults()
        defaults.set(40.0, forKey: "settings.notifications.volume")

        LegacyDefaultsMigration.importIfNeeded(
            into: defaults,
            legacy: ["settings.notifications.volume": 100.0, "settings.notifications.finishedSound": "Basso"]
        )
        #expect(defaults.double(forKey: "settings.notifications.volume") == 40)
        #expect(defaults.string(forKey: "settings.notifications.finishedSound") == "Basso")

        defaults.removeObject(forKey: "settings.notifications.finishedSound")
        LegacyDefaultsMigration.importIfNeeded(into: defaults, legacy: ["settings.notifications.finishedSound": "Basso"])
        #expect(defaults.string(forKey: "settings.notifications.finishedSound") == nil)
    }

    @Test("a missing legacy domain is retried on a later launch")
    func missingLegacyDomainIsRetried() {
        let defaults = makeDefaults()
        LegacyDefaultsMigration.importIfNeeded(into: defaults, legacy: nil)
        LegacyDefaultsMigration.importIfNeeded(into: defaults, legacy: ["theme": "paper"])
        #expect(defaults.string(forKey: "theme") == "paper")
    }
}
