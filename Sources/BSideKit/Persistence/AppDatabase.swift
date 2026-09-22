import Foundation
import GRDB
import OSLog

/// Owns the app's SQLite database: connection, migrations, and queries.
///
/// The database file lives under the app's Application Support directory.
public final class AppDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    private static let logger = Logger(subsystem: "ai.syv.bside", category: "database")

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(dbQueue)
    }

    /// Opens (creating if needed) the database at the standard Application Support location.
    public static func openStandard(appName: String = "B-Side") throws -> AppDatabase {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try open(appName: appName, legacyAppName: "DashNative", in: appSupport)
    }

    /// Opens the database under `appName` inside `baseDirectory`, migrating data from
    /// `legacyAppName` (if present) the first time the new directory doesn't exist yet.
    static func open(appName: String, legacyAppName: String, in baseDirectory: URL) throws -> AppDatabase {
        let fileManager = FileManager.default
        let directory = baseDirectory.appendingPathComponent(appName, isDirectory: true)
        migrateLegacyDirectoryIfNeeded(
            fileManager: fileManager,
            from: baseDirectory.appendingPathComponent(legacyAppName, isDirectory: true),
            to: directory
        )
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
    static func migrateLegacyDirectoryIfNeeded(fileManager: FileManager, from oldURL: URL, to newURL: URL) {
        guard !fileManager.fileExists(atPath: newURL.path) else { return }
        guard fileManager.fileExists(atPath: oldURL.path) else { return }
        do {
            try fileManager.moveItem(at: oldURL, to: newURL)
            logger.info("Migrated data directory from \(oldURL.path, privacy: .public) to \(newURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to migrate data directory from \(oldURL.path, privacy: .public): \(error, privacy: .public)")
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
