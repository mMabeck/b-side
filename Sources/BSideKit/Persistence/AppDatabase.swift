import Foundation
import GRDB
import OSLog

/// Owns the app's SQLite database: connection, migrations, and queries.
///
/// The database file lives under the app's Application Support directory.
public final class AppDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "database")

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(dbQueue)
    }

    public static let defaultAppSupportName = "B-Side"

    /// Application Support folder for this bundle; side-by-side copies set `BSideAppSupportName` so they share no state.
    public static let appSupportName: String =
        Bundle.main.object(forInfoDictionaryKey: "BSideAppSupportName") as? String ?? defaultAppSupportName

    /// Opens (creating if needed) the database at the standard Application Support location.
    public static func openStandard(appName: String = appSupportName) throws -> AppDatabase {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Only the real app inherits DashNative data; a side-by-side copy must never move it.
        let legacyAppName = appName == defaultAppSupportName ? "DashNative" : appName
        return try open(appName: appName, legacyAppName: legacyAppName, in: appSupport)
    }

    /// Opens the database under `appName` inside `baseDirectory`, migrating data from
    /// `legacyAppName` (if present) the first time the new directory doesn't exist yet.
    static func open(appName: String, legacyAppName: String, in baseDirectory: URL) throws -> AppDatabase {
        let fileManager = FileManager.default
        let newDirectory = baseDirectory.appendingPathComponent(appName, isDirectory: true)
        let legacyDirectory = baseDirectory.appendingPathComponent(legacyAppName, isDirectory: true)
        // If the move fails we keep running out of the legacy directory rather than
        // creating an empty one, which would orphan the old data and, because the new
        // directory would then exist, stop the migration ever being retried.
        let migrated = migrateLegacyDirectoryIfNeeded(
            fileManager: fileManager,
            from: legacyDirectory,
            to: newDirectory
        )
        let directory = migrated ? newDirectory : legacyDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("db.sqlite")
        logger.info("Opening database at \(dbURL.path, privacy: .public)")

        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        return try AppDatabase(dbQueue: dbQueue)
    }

    /// One-time move of a legacy data directory into the new location. No-ops if the new
    /// location already exists or the legacy one doesn't; failures are logged, not thrown,
    /// so a migration hiccup never crashes the app or loses the old data.
    ///
    /// Returns `false` only when a move was attempted and failed — the caller then stays
    /// on the legacy directory so the next launch can try again.
    @discardableResult
    static func migrateLegacyDirectoryIfNeeded(fileManager: FileManager, from oldURL: URL, to newURL: URL) -> Bool {
        guard !fileManager.fileExists(atPath: newURL.path) else { return true }
        guard fileManager.fileExists(atPath: oldURL.path) else { return true }
        do {
            try fileManager.moveItem(at: oldURL, to: newURL)
            logger.info("Migrated data directory from \(oldURL.path, privacy: .public) to \(newURL.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to migrate data directory from \(oldURL.path, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    /// Opens an in-memory database, for tests and previews.
    public static func openInMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        return try AppDatabase(dbQueue: dbQueue)
    }
}
