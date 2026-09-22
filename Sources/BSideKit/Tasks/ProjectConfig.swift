import Foundation
import OSLog

/// Per-project configuration: a small file in the repo (`.bside/config.json`)
/// holding setup/teardown commands and task defaults. Read from disk on demand —
/// it is source-controlled project state, not app state, so it isn't cached in
/// the database.
public struct ProjectConfig: Codable, Equatable, Sendable {
    public struct TaskDefaults: Codable, Equatable, Sendable {
        public var baseRef: String
        public var permissionMode: String
        public var useWorktree: Bool

        public init(baseRef: String = "main", permissionMode: String = "default", useWorktree: Bool = true) {
            self.baseRef = baseRef
            self.permissionMode = permissionMode
            self.useWorktree = useWorktree
        }
    }

    /// Runs once in a fresh worktree before the agent starts, e.g. dependency install.
    public var setupCommand: String?
    /// Runs once before a worktree is removed, e.g. tearing down containers it started.
    public var teardownCommand: String?
    public var taskDefaults: TaskDefaults

    public init(setupCommand: String? = nil, teardownCommand: String? = nil, taskDefaults: TaskDefaults = TaskDefaults()) {
        self.setupCommand = setupCommand
        self.teardownCommand = teardownCommand
        self.taskDefaults = taskDefaults
    }

    private static let logger = Logger(subsystem: "ai.syv.bside", category: "project-config")

    /// The path this config would live at for a project rooted at `projectPath`.
    public static func configFileURL(forProjectAt projectPath: URL) -> URL {
        projectPath.appendingPathComponent(".bside/config.json")
    }

    /// Loads `.bside/config.json` from the project, falling back to defaults if the
    /// file is missing or malformed. Migrates a legacy `.dash/` directory in place first.
    public static func load(forProjectAt projectPath: URL) -> ProjectConfig {
        migrateLegacyConfigDirectoryIfNeeded(forProjectAt: projectPath)
        let url = configFileURL(forProjectAt: projectPath)
        guard let data = try? Data(contentsOf: url) else {
            return ProjectConfig()
        }
        do {
            return try JSONDecoder().decode(ProjectConfig.self, from: data)
        } catch {
            logger.error("Failed to parse \(url.path, privacy: .public): \(error, privacy: .public)")
            return ProjectConfig()
        }
    }

    /// One-time move of a legacy `.dash/` directory into `.bside/`. No-ops if `.bside/`
    /// already exists or `.dash/` doesn't; failures are logged, not thrown, so a
    /// migration hiccup never crashes the app or loses the old config.
    static func migrateLegacyConfigDirectoryIfNeeded(forProjectAt projectPath: URL) {
        let fileManager = FileManager.default
        let newDir = projectPath.appendingPathComponent(".bside", isDirectory: true)
        let oldDir = projectPath.appendingPathComponent(".dash", isDirectory: true)
        guard !fileManager.fileExists(atPath: newDir.path) else { return }
        guard fileManager.fileExists(atPath: oldDir.path) else { return }
        do {
            try fileManager.moveItem(at: oldDir, to: newDir)
            logger.info("Migrated project config directory from \(oldDir.path, privacy: .public) to \(newDir.path, privacy: .public)")
        } catch {
            logger.error("Failed to migrate project config directory from \(oldDir.path, privacy: .public): \(error, privacy: .public)")
        }
    }
}
