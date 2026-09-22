import Foundation
import GRDB
import Testing

@testable import DashNativeKit

@Suite("Cascading deletes")
struct CascadingDeleteTests {
    @Test("Deleting a project deletes its tasks and their conversations")
    func projectDeleteCascades() throws {
        let database = try AppDatabase.openInMemory()

        var project = Project(path: "/tmp/repo", displayName: "repo", baseRef: "main")
        try database.dbQueue.write { db in try project.insert(db) }

        var task = TaskRecord(
            projectId: project.id!,
            name: "Fix bug",
            branchName: "task/fix-bug",
            worktreePath: "/tmp/repo-worktrees/fix-bug",
            harness: "claude",
            permissionLevel: "default"
        )
        try database.dbQueue.write { db in try task.insert(db) }

        var conversation = Conversation(taskId: task.id!, transcriptPath: "/tmp/t.jsonl")
        try database.dbQueue.write { db in try conversation.insert(db) }

        try database.dbQueue.write { db in
            _ = try Project.deleteOne(db, id: project.id!)
        }

        let (taskCount, conversationCount) = try database.dbQueue.read { db in
            (try TaskRecord.fetchCount(db), try Conversation.fetchCount(db))
        }
        #expect(taskCount == 0)
        #expect(conversationCount == 0)
    }

    @Test("Deleting a task deletes its conversations but not the project")
    func taskDeleteCascadesToConversationsOnly() throws {
        let database = try AppDatabase.openInMemory()

        var project = Project(path: "/tmp/repo", displayName: "repo", baseRef: "main")
        try database.dbQueue.write { db in try project.insert(db) }

        var task = TaskRecord(
            projectId: project.id!,
            name: "Fix bug",
            branchName: "task/fix-bug",
            worktreePath: "/tmp/repo-worktrees/fix-bug",
            harness: "claude",
            permissionLevel: "default"
        )
        try database.dbQueue.write { db in try task.insert(db) }

        var conversation = Conversation(taskId: task.id!, transcriptPath: "/tmp/t.jsonl")
        try database.dbQueue.write { db in try conversation.insert(db) }

        try database.dbQueue.write { db in
            _ = try TaskRecord.deleteOne(db, id: task.id!)
        }

        let (projectCount, conversationCount) = try database.dbQueue.read { db in
            (try Project.fetchCount(db), try Conversation.fetchCount(db))
        }
        #expect(projectCount == 1)
        #expect(conversationCount == 0)
    }
}
