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

        // Added to remember a project's last-used task-creation choices (New
        // Task sheet: worktree toggle, new-branch/existing-branch mode) so
        // reopening the sheet preselects them instead of always resetting to
        // the project config defaults.
        migrator.registerMigration("v4_project_last_task_creation_choices") { db in            try db.alter(table: "project") { t in
                t.add(column: "lastUseWorktree", .boolean)
                t.add(column: "lastTaskCreationMode", .text)
            }
        }

        // Added so `GitCLI.isMerged` can tell a branch that has gained no
        // commits since the task started from one genuinely merged into its
        // base (see `GitCLI+Sync.swift`).
        migrator.registerMigration("v5_task_start_commit") { db in
            try db.alter(table: "task") { t in
                t.add(column: "startCommit", .text)
            }
        }
    }
}
