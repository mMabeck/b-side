import Foundation
import OSLog

/// Read from disk on demand: source-controlled project state, not cached in the database.
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

    public var setupCommand: String?
    public var teardownCommand: String?
    public var taskDefaults: TaskDefaults

    public init(setupCommand: String? = nil, teardownCommand: String? = nil, taskDefaults: TaskDefaults = TaskDefaults()) {
        self.setupCommand = setupCommand
        self.teardownCommand = teardownCommand
        self.taskDefaults = taskDefaults
    }

    private static let logger = Logger(subsystem: "dev.mabeck.bside", category: "project-config")

    public static func configFileURL(forProjectAt projectPath: URL) -> URL {
        projectPath.appendingPathComponent(".bside/config.json")
    }

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
