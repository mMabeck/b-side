import Foundation
import GRDB
import Testing

@testable import BSideKit

@Suite("Migrations")
struct MigrationTests {
    @Test("Migrator has one registered migration and it applies cleanly")
    func migratesCleanly() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)

        #expect(migrator.migrations == [
            "v1_initial_schema",
            "v2_conversation_session_id",
            "v3_task_awaiting_auto_rename",
            "v4_task_base_commit",
            "v5_project_last_task_creation_choices",
            "v6_task_last_activity_at",
            "v7_project_sort_order",
        ])
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            try #expect(db.tableExists("project"))
            try #expect(db.tableExists("task"))
            try #expect(db.tableExists("conversation"))
            try #expect(db.columns(in: "project").map(\.name).contains("lastUseWorktree"))
            try #expect(db.columns(in: "project").map(\.name).contains("lastTaskCreationMode"))
            try #expect(db.columns(in: "project").map(\.name).contains("sortOrder"))
            try #expect(db.columns(in: "task").map(\.name).contains("baseCommit"))
            try #expect(db.columns(in: "task").map(\.name).contains("lastActivityAt"))
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
        #expect(appliedCount == 7)
    }

    @Test("v5 is idempotent when the project columns were already added under an old migration name")
    func v5IsIdempotentAgainstPreexistingColumns() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        // Migrate through v3, then simulate a dev DB that already added the project columns under a dropped migration name.
        try migrator.migrate(dbQueue, upTo: "v3_task_awaiting_auto_rename")
        try dbQueue.write { db in
            try db.alter(table: "project") { t in
                t.add(column: "lastUseWorktree", .boolean)
                t.add(column: "lastTaskCreationMode", .text)
            }
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            try #expect(db.columns(in: "project").map(\.name).contains("lastUseWorktree"))
            try #expect(db.columns(in: "project").map(\.name).contains("lastTaskCreationMode"))
        }
    }

    @Test("v7 backfills sortOrder to match each project's pre-existing (rowid) order")
    func v7BackfillsSortOrderInExistingRowidOrder() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        try migrator.migrate(dbQueue, upTo: "v6_task_last_activity_at")

        var ids: [Int64] = []
        try dbQueue.write { db in
            for path in ["/a", "/b", "/c"] {
                try db.execute(
                    sql: "INSERT INTO project (path, displayName, baseRef) VALUES (?, ?, 'main')",
                    arguments: [path, path]
                )
                ids.append(db.lastInsertedRowID)
            }
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            for (index, id) in ids.enumerated() {
                let sortOrder = try Int.fetchOne(db, sql: "SELECT sortOrder FROM project WHERE id = ?", arguments: [id])
                #expect(sortOrder == index)
            }
        }
    }
}
