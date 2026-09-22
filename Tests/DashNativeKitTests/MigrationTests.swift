import Foundation
import GRDB
import Testing

@testable import DashNativeKit

@Suite("Migrations")
struct MigrationTests {
    @Test("Migrator has one registered migration and it applies cleanly")
    func migratesCleanly() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)

        #expect(migrator.migrations == ["v1_initial_schema"])
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            try #expect(db.tableExists("project"))
            try #expect(db.tableExists("task"))
            try #expect(db.tableExists("conversation"))
        }
    }

    @Test("Migrating twice is a no-op")
    func migratingTwiceIsNoOp() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)

        try migrator.migrate(dbQueue)
        try migrator.migrate(dbQueue)

        let appliedCount = try dbQueue.read { db in
            try migrator.appliedMigrations(db).count
        }
        #expect(appliedCount == 1)
    }
}
