import Foundation
import GRDB
import Testing

@testable import BSideKit

@Suite("Record round-trips")
struct RecordRoundTripTests {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.openInMemory()
    }

    @Test("Task inserts and fetches back equal")
    func taskRoundTrip() throws {
        let database = try makeDatabase()
        var project = Project(path: "/tmp/repo", displayName: "repo", baseRef: "main")
        try database.dbQueue.write { db in try project.insert(db) }

        var task = TaskRecord(
            projectId: project.id!,
            name: "Fix bug",
            branchName: "task/fix-bug",
            branchCreatedByApp: true,
            worktreePath: "/tmp/repo-worktrees/fix-bug",
            harness: "claude",
            permissionLevel: "default",
            contextPrompt: "Be careful",
            setupCommand: "npm install",
            teardownCommand: nil,
            archived: false,
            sortPosition: 0
        )
        try database.dbQueue.write { db in
            try task.insert(db)
        }
        #expect(task.id != nil)

        let fetched = try database.dbQueue.read { db in
            try TaskRecord.fetchOne(db, id: task.id!)
        }
        #expect(fetched == task)
    }
}
