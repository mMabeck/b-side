import Foundation
import GRDB

/// Plain, versioned SQL migrations. No ORM ceremony.
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

        // The pi session id, known before the transcript file exists and stable even if `transcriptPath` is later re-resolved.
        migrator.registerMigration("v2_conversation_session_id") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "sessionId", .text).notNull().defaults(to: "")
            }
        }

        // Whether a blank-named task is still waiting for `TaskAutoRenameService`'s rename.
        migrator.registerMigration("v3_task_awaiting_auto_rename") { db in
            try db.alter(table: "task") { t in
                t.add(column: "awaitingAutoRename", .boolean).notNull().defaults(to: false)
            }
        }

        // The branch's tip commit right after task creation, so `GitCLI.isMerged`
        // can tell a fresh branch apart from one that gained and merged its
        // own commits. `nil` for legacy rows; `syncStatus` falls back to the reflog creation entry.
        migrator.registerMigration("v4_task_base_commit") { db in
            try db.alter(table: "task") { t in
                t.add(column: "baseCommit", .text)
            }
        }

        // Remembers the New Task sheet's last choices so reopening it
        // preselects them. Column adds are guarded: a dev DB may have applied
        // this migration under a prior name ("v4_project_last_task_creation_choices").
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

        // So tasks with recent activity (`ProjectsStore.bumpTaskActivity`) sort
        // to the top instead of staying pinned by creation order. `nil` falls last in a `DESC` ordering.
        migrator.registerMigration("v6_task_last_activity_at") { db in
            try db.alter(table: "task") { t in
                t.add(column: "lastActivityAt", .datetime)
            }
        }

        // Enables drag-reorder (`ProjectsStore.moveProjects`). Backfilled from
        // each project's current `id` so existing installs keep their present
        // order instead of the backfill reshuffling them.
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
