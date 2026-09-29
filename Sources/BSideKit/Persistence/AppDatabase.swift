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
        let directory = appSupport.appendingPathComponent(appName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("db.sqlite")
        logger.info("Opening database at \(dbURL.path, privacy: .public)")

        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        return try AppDatabase(dbQueue: dbQueue)
    }

    /// Opens an in-memory database, for tests and previews.
    public static func openInMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        return try AppDatabase(dbQueue: dbQueue)
    }
}
