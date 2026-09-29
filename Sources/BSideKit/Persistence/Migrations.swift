import Foundation
import GRDB

enum Migrations {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("displayName", .text).notNull()
                t.column("remote", .text)
                t.column("baseRef", .text).notNull().defaults(to: "main")
            }

            try db.create(table: "task") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("branchName", .text).notNull()
                t.column("branchCreatedByApp", .boolean).notNull().defaults(to: true)
                t.column("worktreePath", .text).notNull()
                t.column("harness", .text).notNull()
                t.column("permissionLevel", .text).notNull()
                t.column("contextPrompt", .text)
                t.column("setupCommand", .text)
                t.column("teardownCommand", .text)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("sortPosition", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "conversation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("task", onDelete: .cascade).notNull()
                t.column("transcriptPath", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v2_conversation_session_id") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "sessionId", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v3_task_awaiting_auto_rename") { db in
            try db.alter(table: "task") { t in
                t.add(column: "awaitingAutoRename", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v4_task_base_commit") { db in
            try db.alter(table: "task") { t in
                t.add(column: "baseCommit", .text)
            }
        }

        // Guarded: a dev DB may have applied this as "v4_project_last_task_creation_choices".
        migrator.registerMigration("v5_project_last_task_creation_choices") { db in
            let existingColumns = Set(try db.columns(in: "project").map(\.name))
            try db.alter(table: "project") { t in
                if !existingColumns.contains("lastUseWorktree") {
                    t.add(column: "lastUseWorktree", .boolean)
                }
                if !existingColumns.contains("lastTaskCreationMode") {
                    t.add(column: "lastTaskCreationMode", .text)
                }
            }
        }

        migrator.registerMigration("v6_task_last_activity_at") { db in
            try db.alter(table: "task") { t in
                t.add(column: "lastActivityAt", .datetime)
            }
        }

        // Backfilled from `id` so existing installs keep their current order.
        migrator.registerMigration("v7_project_sort_order") { db in
            try db.alter(table: "project") { t in
                t.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
            }
            for (index, row) in try Row.fetchAll(db, sql: "SELECT id FROM project ORDER BY id").enumerated() {
                let id: Int64 = row["id"]
                try db.execute(sql: "UPDATE project SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }
}
