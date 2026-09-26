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

        // Added for pi session resume (native-rewrite.md §6): the pi session
        // id a conversation was launched under, known before the transcript
        // file exists on disk and stable even if `transcriptPath` is later
        // re-resolved.
        migrator.registerMigration("v2_conversation_session_id") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "sessionId", .text).notNull().defaults(to: "")
            }
        }

        // Added for automatic task renaming from a task's first pi prompt
        // (see `TaskAutoRenameService`): whether a task, created with a
        // blank name, is still waiting for that rename.
        migrator.registerMigration("v3_task_awaiting_auto_rename") { db in
            try db.alter(table: "task") { t in
                t.add(column: "awaitingAutoRename", .boolean).notNull().defaults(to: false)
            }
        }

        // Added so merged status can tell a fresh (or merely behind) branch
        // apart from one that actually gained and merged commits of its own
        // (see `GitCLI.isMerged`): the branch's tip commit right after the
        // task was created. `nil` for rows from before this column existed;
        // `TaskWorktreeService.syncStatus` falls back to the branch's reflog
        // creation entry for those.
        migrator.registerMigration("v4_task_base_commit") { db in
            try db.alter(table: "task") { t in
                t.add(column: "baseCommit", .text)
            }
        }

        // Added to remember a project's last-used task-creation choices (New
        // Task sheet: worktree toggle, new-branch/existing-branch mode) so
        // reopening the sheet preselects them instead of always resetting to
        // the project config defaults. Renamed from this branch's original
        // "v4_project_last_task_creation_choices" to land after main's
        // "v4_task_base_commit"; column adds are guarded because a dev DB may
        // already have applied the old v4 (or the since-dropped
        // "v5_task_start_commit") migration under its previous name.
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

        // Added so tasks with recent activity (a sent prompt, a genuine
        // busy→idle transition, or an accepted question alert — see
        // `ProjectsStore.bumpTaskActivity`) sort to the top of their
        // project's task list instead of staying pinned by creation order.
        // `nil` for a task that has never had qualifying activity; SQLite
        // sorts `NULL` last in a `DESC` ordering, so such tasks fall below
        // any that have.
        migrator.registerMigration("v6_task_last_activity_at") { db in
            try db.alter(table: "task") { t in
                t.add(column: "lastActivityAt", .datetime)
            }
        }

        // Added so the user can drag-reorder projects in the sidebar
        // (`ProjectsStore.moveProjects`) instead of always seeing them in
        // insertion (rowid) order. Backfilled from each project's current
        // `id` so existing installs keep their present displayed order
        // (`Project.fetchAll` had no explicit `ORDER BY`, i.e. rowid/id
        // order) instead of the backfill silently reshuffling them. A new
        // project not yet given an explicit position defaults to `0` here;
        // `ProjectsStore.addProject` overrides that with max+1 before insert.
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
