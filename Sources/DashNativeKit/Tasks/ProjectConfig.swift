import Foundation
import OSLog

/// Per-project configuration: a small file in the repo (`.dash/config.json`)
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

    private static let logger = Logger(subsystem: "ai.syv.dash-native", category: "project-config")

    /// The path this config would live at for a project rooted at `projectPath`.
    public static func configFileURL(forProjectAt projectPath: URL) -> URL {
        projectPath.appendingPathComponent(".dash/config.json")
    }

    /// Loads `.dash/config.json` from the project, falling back to defaults if the
    /// file is missing or malformed.
    public static func load(forProjectAt projectPath: URL) -> ProjectConfig {
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
}
