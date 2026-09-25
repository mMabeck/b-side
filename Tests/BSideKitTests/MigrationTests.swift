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
        ])
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            try #expect(db.tableExists("project"))
            try #expect(db.tableExists("task"))
            try #expect(db.tableExists("conversation"))
            try #expect(db.columns(in: "project").map(\.name).contains("lastUseWorktree"))
            try #expect(db.columns(in: "project").map(\.name).contains("lastTaskCreationMode"))
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
        #expect(appliedCount == 6)
    }

    @Test("v5 is idempotent when the project columns were already added under an old migration name")
    func v5IsIdempotentAgainstPreexistingColumns() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        // Migrate through v3 only, then simulate a dev DB that already added
        // the project columns under a different (now-dropped) migration name
        // before v4/v5 ran.
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
}

@Suite("Data directory migration")
struct DataDirectoryMigrationTests {
    @Test("Old directory only: moved into the new location")
    func oldOnlyIsMigrated() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let oldDir = root.appendingPathComponent("DashNative", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "marker".write(to: oldDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        _ = try AppDatabase.open(appName: "B-Side", legacyAppName: "DashNative", in: root)

        let newDir = root.appendingPathComponent("B-Side", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("marker.txt").path))
        #expect(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("db.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
    }

    @Test("New directory only: left untouched")
    func newOnlyIsUntouched() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        _ = try AppDatabase.open(appName: "B-Side", legacyAppName: "DashNative", in: root)

        let newDir = root.appendingPathComponent("B-Side", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("db.sqlite").path))
    }

    @Test("Both present: new location wins, old is left alone")
    func bothPresentPrefersNew() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let oldDir = root.appendingPathComponent("DashNative", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "old".write(to: oldDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        let newDir = root.appendingPathComponent("B-Side", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)

        _ = try AppDatabase.open(appName: "B-Side", legacyAppName: "DashNative", in: root)

        #expect(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("marker.txt").path))
        #expect(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("db.sqlite").path))
    }

    @Test("Move fails: the app stays on the legacy data rather than opening an empty database")
    func failedMigrationKeepsLegacyData() throws {
        let root = try TestRepo.makeTempDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            TestRepo.removeTempDirectory(root)
        }

        let oldDir = root.appendingPathComponent("DashNative", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try "old".write(to: oldDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        // read-only parent: the rename cannot happen, but the legacy directory is still writable
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        _ = try AppDatabase.open(appName: "B-Side", legacyAppName: "DashNative", in: root)

        #expect(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("marker.txt").path))
        #expect(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("db.sqlite").path))
        // no empty new directory, so the next launch retries the migration
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("B-Side").path))
    }

    @Test("Neither present: new directory is created fresh")
    func neitherPresentCreatesFresh() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        _ = try AppDatabase.open(appName: "B-Side", legacyAppName: "DashNative", in: root)

        let newDir = root.appendingPathComponent("B-Side", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: newDir.path))
        let oldDir = root.appendingPathComponent("DashNative", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
    }
}

@Suite("Project config directory migration")
struct ProjectConfigDirectoryMigrationTests {
    @Test("Old .dash/ only: moved into .bside/")
    func oldOnlyIsMigrated() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let oldDir = root.appendingPathComponent(".dash", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectConfig(setupCommand: "echo old")).write(
            to: oldDir.appendingPathComponent("config.json"))

        let config = ProjectConfig.load(forProjectAt: root)

        #expect(config.setupCommand == "echo old")
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".bside/config.json").path))
    }

    @Test("New .bside/ only: left untouched")
    func newOnlyIsUntouched() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let newDir = root.appendingPathComponent(".bside", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectConfig(setupCommand: "echo new")).write(
            to: newDir.appendingPathComponent("config.json"))

        let config = ProjectConfig.load(forProjectAt: root)

        #expect(config.setupCommand == "echo new")
    }

    @Test("Both present: .bside/ wins, .dash/ is left alone")
    func bothPresentPrefersNew() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let oldDir = root.appendingPathComponent(".dash", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectConfig(setupCommand: "echo old")).write(
            to: oldDir.appendingPathComponent("config.json"))

        let newDir = root.appendingPathComponent(".bside", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProjectConfig(setupCommand: "echo new")).write(
            to: newDir.appendingPathComponent("config.json"))

        let config = ProjectConfig.load(forProjectAt: root)

        #expect(config.setupCommand == "echo new")
        #expect(FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("config.json").path))
    }

    @Test("Neither present: falls back to defaults, no directory created")
    func neitherPresentFallsBackToDefaults() throws {
        let root = try TestRepo.makeTempDirectory()
        defer { TestRepo.removeTempDirectory(root) }

        let config = ProjectConfig.load(forProjectAt: root)

        #expect(config == ProjectConfig())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".bside").path))
    }
}
